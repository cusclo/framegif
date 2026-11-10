import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

private let maxSeconds = 30
private let frameInterval = 0.1
private let maxSide = 960.0

enum GIFError: LocalizedError {
    case noFrames, cannotEncode, missingDisplay
    var errorDescription: String? {
        switch self {
        case .noFrames: return "没有录到画面。请重新框选区域，等画面开始后再停止。"
        case .cannotEncode: return "生成 GIF 失败，请重试。"
        case .missingDisplay: return "找不到刚才框选的显示器，请重新框选。"
        }
    }
}

struct GIFFrame {
    let jpeg: Data
    let time: TimeInterval

    init?(_ image: CGImage, time: TimeInterval) {
        let bytes = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        jpeg = bytes as Data
        self.time = time
    }
}

struct GIFRecording {
    let frames: [GIFFrame]
    let endTime: TimeInterval

    func save(to url: URL) throws {
        guard !frames.isEmpty else { throw GIFError.noFrames }
        let bytes = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw GIFError.cannotEncode }
        CGImageDestinationSetProperties(dst, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for (index, frame) in frames.enumerated() {
            let nextTime = index + 1 < frames.count ? frames[index + 1].time : endTime
            let delay = max(frameInterval, (100 * (nextTime - frame.time)).rounded() / 100)
            let properties = [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]] as CFDictionary
            let decoded: CGImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            guard let decoded else { throw GIFError.cannotEncode }
            CGImageDestinationAddImage(dst, decoded, properties)
        }
        guard CGImageDestinationFinalize(dst) else { throw GIFError.cannotEncode }
        try (bytes as Data).write(to: url, options: .atomic)
    }
}

// ScreenCaptureKit calls this on a serial queue. Compress each frame immediately
// so a long recording doesn't hold hundreds of raw screen buffers in memory.
final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "windowgif.capture", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var frames: [GIFFrame] = []
    private var closed = false

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !closed, type == .screen, sampleBuffer.isValid,
              let buffer = sampleBuffer.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let first = frames.first, now - first.time >= Double(maxSeconds) { return }
        if let last = frames.last, now - last.time < 0.075 { return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            if let pixels = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace),
               let frame = GIFFrame(pixels, time: now) {
                frames.append(frame)
            }
        }
    }

    func finish(at endTime: TimeInterval) async -> GIFRecording {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closed = true
                let recording = GIFRecording(frames: self.frames, endTime: endTime)
                self.frames.removeAll()
                continuation.resume(returning: recording)
            }
        }
    }
}

@MainActor
final class Recorder: NSObject, ObservableObject, SCStreamDelegate {
    enum Phase { case idle, selecting, starting, recording, stopping, saving, exporting }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var seconds = 0
    @Published private(set) var lastFile: URL?
    @Published var showCursor = true
    @Published var problem: String?
    @Published private(set) var note = "拖动鼠标框出要录的区域，松开即开始。"

    @Published private(set) var needsPermission = false
    private var stream: SCStream?
    private var sink: FrameSink?
    private var clock: Task<Void, Never>?
    private var stopItem: NSStatusItem?
    private var captureStart: TimeInterval = 0
    private var selectionPanels: [SelectionPanel] = []
    private var recordingHighlight: NSPanel?
    private var normalWindow: (frame: CGRect, behavior: NSWindow.CollectionBehavior)?
    weak var window: NSWindow?

    func choose() {
        guard phase == .idle, !NSScreen.screens.isEmpty else { return }
        phase = .selecting
        window?.orderOut(nil)
        let mouseLocation = NSEvent.mouseLocation
        NSApp.activate(ignoringOtherApps: true)

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let displayID = number.uint32Value
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false, screen: screen)
            panel.title = "框选录制区域"
            panel.setFrame(screen.frame, display: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false

            let overlay = AreaSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            overlay.completed = { [weak self] rect in self?.didSelect(rect, displayID: displayID) }
            panel.contentView = overlay
            panel.initialFirstResponder = overlay
            selectionPanels.append(panel)
            panel.orderFrontRegardless()
        }

        guard let firstPanel = selectionPanels.first else {
            reset()
            showWindow()
            problem = GIFError.missingDisplay.localizedDescription
            return
        }
        let focusedPanel = selectionPanels.first { $0.frame.contains(mouseLocation) } ?? firstPanel
        focusedPanel.makeKeyAndOrderFront(nil)
        focusedPanel.makeFirstResponder(focusedPanel.contentView)
    }

    private func didSelect(_ rect: CGRect?, displayID: CGDirectDisplayID) {
        guard phase == .selecting else { return }
        selectionPanels.forEach { $0.orderOut(nil) }
        selectionPanels.removeAll()
        guard let rect else {
            phase = .idle
            showWindow()
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            needsPermission = true
            note = "已框选 \(Int(rect.width)) × \(Int(rect.height))。首次录制需要授权，开启后退出重开，再框选一次。"
            phase = .idle
            showWindow()
            return
        }

        needsPermission = false
        note = "拖动鼠标框出要录的区域，松开即开始。"
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else {
            reset()
            showWindow()
            problem = GIFError.missingDisplay.localizedDescription
            return
        }
        phase = .starting
        seconds = 0
        showRecordingControls(on: screen, region: rect)
        Task {
            await start(displayID: displayID, region: rect)
        }
    }

    private func showRecordingControls(on screen: NSScreen, region: CGRect) {
        let highlight = NSPanel(contentRect: screen.frame, styleMask: .borderless,
                                backing: .buffered, defer: false, screen: screen)
        highlight.title = "录制区域高亮"
        highlight.setFrame(screen.frame, display: false)
        highlight.backgroundColor = .clear
        highlight.isOpaque = false
        highlight.hasShadow = false
        highlight.ignoresMouseEvents = true
        highlight.hidesOnDeactivate = false
        highlight.level = .floating
        highlight.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        highlight.contentView = RecordingHighlightView(
            frame: CGRect(origin: .zero, size: screen.frame.size), region: region
        )
        recordingHighlight = highlight
        highlight.orderFrontRegardless()

        guard let window else { return }
        normalWindow = (window.frame, window.collectionBehavior)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.setContentSize(NSSize(width: 270, height: 88))

        // ScreenCaptureKit uses a top-left origin within the display. AppKit uses
        // a bottom-left origin in desktop coordinates for window placement.
        let area = CGRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY,
                          width: region.width, height: region.height)
        window.setFrameOrigin(controlOrigin(size: window.frame.size, outside: area, on: screen))
        window.orderFrontRegardless()
    }

    private func controlOrigin(size: CGSize, outside area: CGRect, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        let gap: CGFloat = 12
        let nearby = [
            CGPoint(x: area.maxX + gap, y: area.maxY - size.height),
            CGPoint(x: area.minX - size.width - gap, y: area.maxY - size.height),
            CGPoint(x: area.minX, y: area.maxY + gap),
            CGPoint(x: area.minX, y: area.minY - size.height - gap)
        ].map { point in
            CGPoint(x: max(visible.minX, min(point.x, visible.maxX - size.width)),
                    y: max(visible.minY, min(point.y, visible.maxY - size.height)))
        }
        if let outside = nearby.first(where: { !CGRect(origin: $0, size: size).intersects(area) }) {
            return outside
        }
        if let other = NSScreen.screens.first(where: { $0 != screen && !$0.frame.intersects(screen.frame) }) {
            let safe = other.visibleFrame
            return CGPoint(x: safe.maxX - size.width - 10, y: safe.maxY - size.height - 10)
        }
        return CGPoint(x: visible.maxX - size.width, y: visible.maxY - size.height)
    }

    private func restoreRecordingControls() {
        recordingHighlight?.orderOut(nil)
        recordingHighlight = nil
        if let normalWindow, let window {
            window.level = .normal
            window.collectionBehavior = normalWindow.behavior
            window.setFrame(normalWindow.frame, display: true)
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
        }
        normalWindow = nil
    }

    func requestPermission() {
        if CGRequestScreenCaptureAccess() {
            needsPermission = false
            note = "屏幕录制已授权。请再框选一次。"
        }
    }

    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream, self.phase == .recording else { return }
            await self.stop(alreadyStopped: true)
        }
    }

    private func start(displayID: CGDirectDisplayID, region: CGRect) async {
        let filter: SCContentFilter
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw GIFError.missingDisplay
            }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        } catch {
            reset()
            showWindow()
            problem = "无法读取所选显示器。\(error.localizedDescription)"
            return
        }

        let scale = CGFloat(filter.pointPixelScale)
        let size = region.size
        let longest = max(size.width, size.height)
        guard longest > 0 else {
            reset()
            problem = GIFError.noFrames.localizedDescription
            return
        }
        let ratio = min(scale, maxSide / longest)
        let config = SCStreamConfiguration()
        config.width = max(2, Int((size.width * ratio).rounded()))
        config.height = max(2, Int((size.height * ratio).rounded()))
        config.sourceRect = region
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = showCursor
        config.shouldBeOpaque = true
        config.capturesAudio = false
        let newSink = FrameSink()
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        sink = newSink
        stream = newStream
        do {
            try newStream.addStreamOutput(newSink, type: .screen, sampleHandlerQueue: newSink.queue)
            try await newStream.startCapture()
        } catch {
            reset()
            showWindow()
            problem = "无法开始录制。\(error.localizedDescription)"
            return
        }

        captureStart = ProcessInfo.processInfo.systemUptime
        phase = .recording
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "■ 停止 GIF"
        item.button?.toolTip = "停止录制并存储 GIF"
        item.button?.target = self
        item.button?.action = #selector(stopFromMenu)
        stopItem = item
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled, self.phase == .recording else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - self.captureStart
                self.seconds = Int(elapsed)
                if elapsed >= Double(maxSeconds) {
                    await self.stop()
                    return
                }
            }
        }
    }

    @objc private func stopFromMenu() { Task { await stop() } }

    func stop(alreadyStopped: Bool = false) async {
        guard phase == .recording, let stream, let sink else { return }
        phase = .stopping
        let endTime = min(ProcessInfo.processInfo.systemUptime, captureStart + Double(maxSeconds))
        removeStopItem()
        if !alreadyStopped { try? await stream.stopCapture() }
        let recording = await sink.finish(at: endTime)
        self.stream = nil
        self.sink = nil
        restoreRecordingControls()
        showWindow()
        guard !recording.frames.isEmpty else {
            reset()
            problem = GIFError.noFrames.localizedDescription
            return
        }

        phase = .saving
        let panel = NSSavePanel()
        panel.title = "存储框选 GIF"
        panel.prompt = "存储 GIF"
        panel.allowedContentTypes = [.gif]
        panel.canCreateDirectories = true
        panel.directoryURL = lastFile?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: Date())
        panel.nameFieldStringValue = "框选录制-\(stamp).gif"
        guard let window else { reset(); return }
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url else {
            note = "已取消存储。可以重新框选录制。"
            reset()
            return
        }
        phase = .exporting
        do {
            try await Task.detached(priority: .userInitiated) { try recording.save(to: url) }.value
            lastFile = url
            note = "已存储 GIF。可以在访达中找到文件。"
        } catch {
            problem = "未能存储 GIF。\(error.localizedDescription)"
        }
        reset()
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func removeStopItem() {
        if let stopItem {
            NSStatusBar.system.removeStatusItem(stopItem)
            self.stopItem = nil
        }
    }

    private func reset() {
        clock?.cancel()
        clock = nil
        removeStopItem()
        restoreRecordingControls()
        sink = nil
        stream = nil
        phase = .idle
    }
}

struct RecorderView: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        if recorder.phase == .starting || recorder.phase == .recording || recorder.phase == .stopping {
            recordingControls
        } else {
            idleControls
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(status).font(.callout.weight(.medium))
                Spacer()
            }
            HStack {
                Text(String(format: "00:%02d", recorder.seconds))
                    .font(.system(size: 25, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("已录制 \(recorder.seconds) 秒")
                Spacer()
                Button("停止并存储 GIF") { Task { await recorder.stop() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(recorder.phase != .recording)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 270, height: 88)
    }

    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 25, weight: .medium))
                    .frame(width: 51, height: 51)
                    .foregroundStyle(.white)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("框选 GIF").font(.system(size: 24, weight: .semibold))
                    Text("拖出一个框，存成循环动图").foregroundStyle(.secondary)
                }
            }

            Divider()

            Text(status).font(.body).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button("框选区域并录制…", action: recorder.choose)
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.phase != .idle)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Toggle("录制鼠标指针", isOn: $recorder.showCursor)
                    .toggleStyle(.checkbox)
                    .disabled(recorder.phase != .idle)
            }
            .controlSize(.large)

            if let last = recorder.lastFile {
                HStack {
                    Text(last.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("在访达显示") { NSWorkspace.shared.activateFileViewerSelecting([last]) }
                }
                .font(.callout)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            if recorder.needsPermission {
                HStack(spacing: 14) {
                    Button("授权屏幕录制…", action: recorder.requestPermission)
                    Button("打开录屏设置…", action: recorder.openPermissionSettings)
                        .buttonStyle(.link)
                }
                .controlSize(.regular)
            }

            Text("最长 \(maxSeconds) 秒  ·  10 帧/秒  ·  无声音")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 420, height: 295, alignment: .topLeading)
        .alert("框选 GIF", isPresented: Binding(
            get: { recorder.problem != nil },
            set: { if !$0 { recorder.problem = nil } }
        )) {
            Button("好", role: .cancel) { recorder.problem = nil }
        } message: {
            Text(recorder.problem ?? "")
        }
    }

    private var status: String {
        switch recorder.phase {
        case .idle: return recorder.note
        case .selecting: return "拖动鼠标框选区域，按 Esc 取消。"
        case .starting: return "正在开始录制…"
        case .recording: return "正在录制"
        case .stopping: return "正在停止录制…"
        case .saving: return "请选择 GIF 的存储位置。"
        case .exporting: return "正在生成 GIF…"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let recorder = Recorder()
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 295),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "框选 GIF"
        let content = NSHostingView(rootView: RecorderView(recorder: recorder))
        content.sizingOptions = []
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        recorder.window = window
        recorder.showWindow()

        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let submenu = NSMenu()
        submenu.addItem(withTitle: "退出框选 GIF", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = submenu
        NSApp.mainMenu = menu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        recorder.showWindow()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if recorder.phase == .idle { NSApp.terminate(nil) }
        else if recorder.phase == .recording { Task { await recorder.stop() } }
        return false
    }
}

@main
struct WindowGIFApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
