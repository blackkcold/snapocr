import SwiftUI

/// A three-way value control: preset chips + numeric text field + slider,
/// all bound to the same underlying integer value. Used for the history
/// retention count and days settings.
struct TriValueControl: View {
    let title: LocalizedStringKey
    let unit: LocalizedStringKey
    let presets: [Int]
    let range: ClosedRange<Int>
    let value: Int
    let onChanged: (Int) -> Void

    @State private var textFieldValue = ""
    @State private var isEditing = false
    /// Slider position while the user is still dragging. Committed to
    /// `onChanged` only on release so a single gesture produces one change
    /// instead of one per intermediate step.
    @State private var sliderValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(title) {
                HStack(spacing: 4) {
                    Text(value.formatted())
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(unit)
                }
            }

            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { preset in
                    let isSelected = preset == value
                    Button {
                        onChanged(preset)
                    } label: {
                        Text(presetText(preset))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(minWidth: 40)
                            .background(
                                isSelected
                                    ? Color.accentColor.opacity(0.15)
                                    : Color(nsColor: .controlBackgroundColor),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().strokeBorder(
                                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                    lineWidth: isSelected ? 1.5 : 1
                                )
                            }
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(Text(preset.formatted()) + Text(" ") + Text(unit))
                }
            }

            HStack(spacing: 10) {
                TextField(placeholder, text: $textFieldValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { commitText() }
                    .onChange(of: value) { newValue in
                        guard !isEditing else { return }
                        textFieldValue = String(newValue)
                        guard Int(sliderValue.rounded()) != newValue else { return }
                        sliderValue = Double(newValue)
                    }

                Slider(
                    value: Binding(
                        get: { sliderValue },
                        set: { sliderValue = $0 }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1,
                    onEditingChanged: { isDragging in
                        guard !isDragging else { return }
                        let committed = Int(sliderValue.rounded())
                        guard committed != value else { return }
                        onChanged(committed)
                    }
                )
            }
        }
        .padding(14)
        .glassSurface(in: .rounded(14))
        .onAppear {
            textFieldValue = String(value)
            sliderValue = Double(value)
        }
    }

    private var placeholder: String {
        "\(range.lowerBound)–\(range.upperBound)"
    }

    private func presetText(_ preset: Int) -> String {
        preset.formatted()
    }

    private func commitText() {
        let parsed = Int(textFieldValue.trimmingCharacters(in: .whitespaces))
        let clamped = min(max(parsed ?? value, range.lowerBound), range.upperBound)
        textFieldValue = String(clamped)
        onChanged(clamped)
    }
}
