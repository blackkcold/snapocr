import Testing

@testable import SharedKit

struct TextEntryKeyBehaviorTests {
  @Test func returnAndShiftReturnAreOpposites() {
    for newline in [true, false] {
      #expect(
        TextEntryKeyBehavior.shouldSubmit(
          enterInsertsNewline: newline, shift: false, hasMarkedText: false) == !newline)
      #expect(
        TextEntryKeyBehavior.shouldSubmit(
          enterInsertsNewline: newline, shift: true, hasMarkedText: false) == newline)
      for shift in [true, false] {
        #expect(
          !TextEntryKeyBehavior.shouldSubmit(
            enterInsertsNewline: newline, shift: shift, hasMarkedText: true))
      }
    }
    #expect(!PreferenceDefaults.editorEnterInsertsNewline)
  }
}
