import Foundation
import KeyboardShortcuts

// MARK: - Shortcut Definitions

extension KeyboardShortcuts.Name {
    /// Shortcut for area capture (Default: ⌘⇧1)
    public static let captureArea = Self("captureArea", default: .init(.one, modifiers: [.command, .shift]))
    
    /// Shortcut for window capture (Default: ⌘⇧2)
    public static let captureWindow = Self("captureWindow", default: .init(.two, modifiers: [.command, .shift]))
    
    /// Shortcut for fullscreen capture (Default: ⌘⇧3)
    public static let captureFullscreen = Self("captureFullscreen", default: .init(.three, modifiers: [.command, .shift]))
    
    /// Shortcut for OCR from clipboard (Default: ⌘⇧O)
    public static let ocrFromClipboard = Self("ocrFromClipboard", default: .init(.o, modifiers: [.command, .shift]))
}

// MARK: - HotKeyManager

/// Manager for global keyboard shortcuts
@MainActor
public final class HotKeyManager: ObservableObject {
    /// Shared instance
    public static let shared = HotKeyManager()
    
    // MARK: - Actions
    
    /// Action triggered when area capture shortcut is pressed
    public var onCaptureArea: (() -> Void)?
    
    /// Action triggered when window capture shortcut is pressed
    public var onCaptureWindow: (() -> Void)?
    
    /// Action triggered when fullscreen capture shortcut is pressed
    public var onCaptureFullscreen: (() -> Void)?
    
    /// Action triggered when OCR from clipboard shortcut is pressed
    public var onOCRFromClipboard: (() -> Void)?
    
    // MARK: - Initialization
    
    private init() {
        setupShortcuts()
    }
    
    // MARK: - Setup
    
    private func setupShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .captureArea) { [weak self] in
            self?.onCaptureArea?()
        }
        
        KeyboardShortcuts.onKeyUp(for: .captureWindow) { [weak self] in
            self?.onCaptureWindow?()
        }
        
        KeyboardShortcuts.onKeyUp(for: .captureFullscreen) { [weak self] in
            self?.onCaptureFullscreen?()
        }
        
        KeyboardShortcuts.onKeyUp(for: .ocrFromClipboard) { [weak self] in
            self?.onOCRFromClipboard?()
        }
    }
}
