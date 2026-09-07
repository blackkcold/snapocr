import SharedKit
import SwiftUI

struct TextEntryPreferencesView: View {
  @AppStorage(PreferenceKeys.editorEnterInsertsNewline)
  private var enterInsertsNewline = PreferenceDefaults.editorEnterInsertsNewline

  var body: some View {
    Toggle("Enter inserts a newline in text annotations", isOn: $enterInsertsNewline)
    PreferencesCardCaption(
      text: enterInsertsNewline
        ? "Enter: new line. Shift+Enter: submit. Escape: cancel."
        : "Enter: submit. Shift+Enter: new line. Escape: cancel.")
  }
}
