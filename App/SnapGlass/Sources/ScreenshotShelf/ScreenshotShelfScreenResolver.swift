import AppKit
import CoreGraphics

/// Display and window-list lookups used by the shelf's placement and full-screen suppression.
enum ScreenshotShelfScreenResolver {
    static func screen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { self.displayID(for: $0) == displayID }
    }

    static func screen(underMouse point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func frontmostAppCoversDisplay(targetDisplayID: CGDirectDisplayID?) -> Bool {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPID != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else { return false }

        let displayFrames: [CGRect]
        if let targetDisplayID {
            displayFrames = [CGDisplayBounds(targetDisplayID)]
        } else {
            displayFrames = NSScreen.screens.compactMap { screen -> CGRect? in
                guard let id = displayID(for: screen) else { return nil }
                return CGDisplayBounds(id)
            }
        }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontmostPID,
                  let windowFrame = windowFrame(from: window[kCGWindowBounds as String]) else { return false }
            return displayFrames.contains { windowFrame.insetBy(dx: -2, dy: -2).contains($0) }
        }
    }

    static func windowFrame(from value: Any?) -> CGRect? {
        guard let bounds = value as? [String: CGFloat] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}
