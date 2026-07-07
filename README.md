# SnapGlass

macOS 开源截图与高效 OCR 应用。

## 功能

- **截图**: 区域 / 窗口 / 全屏截图 (ScreenCaptureKit)
- **OCR**: Apple Vision 离线识别，Tesseract 降级支持
- **条码**: QR / Code128 / EAN / PDF417 识别
- **标注**: 箭头、矩形、文本、画笔、高亮、模糊、裁剪
- **快捷键**: ⌘⇧1 区域 / ⌘⇧2 窗口 / ⌘⇧3 全屏 / ⌘⇧O OCR
- **CLI**: `snapglass-cli ocr file <path>`
- **Shortcuts**: App Intents 集成
- **历史**: 加密存储，自动清理

## 系统要求

- macOS 13.0+
- Xcode 16+
- Swift 6.0

## 快速开始

```bash
brew install xcodegen swiftlint
xcodegen generate
./Scripts/build.sh
./Scripts/test.sh
```

## 许可证

[MIT License](LICENSE)

