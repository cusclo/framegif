import AppKit

private let selectionAccent = NSColor(srgbRed: 0.21, green: 0.91, blue: 0.59, alpha: 1)

private func drawSelection(in bounds: CGRect, region: CGRect, shade: CGFloat) {
    let mask = NSBezierPath(rect: bounds)
    if !region.isEmpty { mask.appendRect(region) }
    mask.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(shade).setFill()
    mask.fill()

    guard !region.isEmpty else { return }
    let border = NSBezierPath(rect: region)
    NSColor.black.withAlphaComponent(0.75).setStroke()
    border.lineWidth = 4
    border.stroke()
    selectionAccent.setStroke()
    border.lineWidth = 2
    border.stroke()

    selectionAccent.setFill()
    for x in [region.minX, region.maxX] {
        for y in [region.minY, region.maxY] {
            NSBezierPath(roundedRect: CGRect(x: x - 3, y: y - 3, width: 6, height: 6),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}

final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class RecordingHighlightView: NSView {
    override var isFlipped: Bool { true }
    private let region: CGRect

    init(frame: CGRect, region: CGRect) {
        self.region = region
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: CGRect) {
        drawSelection(in: bounds, region: region, shade: 0.22)
    }
}

final class AreaSelectionView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var completed: ((CGRect?) -> Void)?
    private var origin: CGPoint?
    private var selection: CGRect = .zero

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        origin = point(event)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        updateSelection(event)
    }

    override func mouseUp(with event: NSEvent) {
        updateSelection(event)
        origin = nil
        guard selection.width >= 8, selection.height >= 8 else {
            selection = .zero
            needsDisplay = true
            return
        }
        completed?(selection.integral.intersection(bounds))
    }

    override func rightMouseDown(with event: NSEvent) { completed?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completed?(nil) }
        else { super.keyDown(with: event) }
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, p.x), bounds.width),
                       y: min(max(0, p.y), bounds.height))
    }

    private func updateSelection(_ event: NSEvent) {
        guard let origin else { return }
        let p = point(event)
        selection = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                           width: abs(p.x - origin.x), height: abs(p.y - origin.y))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: CGRect) {
        drawSelection(in: bounds, region: selection, shade: 0.43)

        if selection.isEmpty {
            drawPill("拖动鼠标框选录制区域   ·   Esc 取消", centeredAt: bounds.midX, top: 54)
            return
        }

        drawPill("\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))  ·  松开即录制",
                 centeredAt: selection.midX, top: selection.minY > 42 ? selection.minY - 37 : selection.maxY + 9)
    }

    private func drawPill(_ text: String, centeredAt x: CGFloat, top y: CGFloat) {
        let label = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attrs)
        let width = size.width + 24
        let frame = CGRect(x: min(max(x - width / 2, 8), max(8, bounds.width - width - 8)),
                           y: min(max(y, 8), max(8, bounds.height - 38)),
                           width: width, height: 30)
        NSColor(white: 0.08, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
        label.draw(at: CGPoint(x: frame.minX + 12, y: frame.midY - size.height / 2), withAttributes: attrs)
    }
}
