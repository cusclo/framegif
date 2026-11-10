# 框选 GIF · FrameGIF

macOS 上的区域录制工具。像截图一样用鼠标拖出一个框，松手开始录制，停止后保存为循环 GIF。

## 下载和使用

适用于 **Apple 芯片 Mac，macOS 14 或更新版本**。

1. 从 [GitHub Releases](https://github.com/cusclo/framegif/releases/latest) 下载 `FrameGIF-…-macos-arm64.zip`，解压并将「框选 GIF.app」移到「应用程序」。
2. 打开 App，点「框选区域并录制…」。拖动鼠标框选，松手开始录制。首次使用时，在 macOS 的「隐私与安全 → 录屏与系统录音」中授权，随后重新打开 App。
3. 录制时可以操作框内的内容。点悬浮计时条或菜单栏的停止按钮，选择 GIF 的保存位置。

录制最长 30 秒，每秒 10 帧，GIF 长边最多 960 像素。可以选择是否录制鼠标指针。GIF 无声，处理和保存都在本机完成。

## 从源码构建

需要 Apple 芯片 Mac 和带 macOS SDK 的 Xcode 或 Command Line Tools。项目没有第三方运行依赖。

```sh
./scripts/build.sh
```

生成的 App 和 ZIP 位于 `build.noindex/`。图标由 `scripts/AppIcon.swift` 绘制，程序使用 Swift、AppKit、SwiftUI 和 ScreenCaptureKit。

公开 ZIP 使用临时签名（ad hoc），没有 Apple 公证。如果 macOS 阻止下载的版本运行，可以在本机构建。临时签名的应用升级后，macOS 可能需要重新授予录屏权限。已有签名证书时，可以通过 `CODESIGN_IDENTITY` 指定签名身份。

## 许可

[MIT](LICENSE)
