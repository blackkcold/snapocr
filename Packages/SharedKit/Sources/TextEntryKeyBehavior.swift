import Foundation

/// Keyboard policy shared by the canvas editor and its preference tests.
public enum TextEntryKeyBehavior {
  /// Shift reverses the configured Return action. Marked text belongs to the IME.
  public static func shouldSubmit(enterInsertsNewline: Bool, shift: Bool, hasMarkedText: Bool) -> Bool {
    !hasMarkedText && (enterInsertsNewline == shift)
  }
}
