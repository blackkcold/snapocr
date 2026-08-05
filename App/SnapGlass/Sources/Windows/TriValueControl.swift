import SwiftUI

/// A three-way value control: preset chips + numeric text field + slider,
/// all bound to the same underlying integer value. Used for the history
/// retention count and days settings.
struct TriValueControl: View {
    let title: LocalizedStringKey
    let unit: String
    let presets: [Int]
    let range: ClosedRange<Int>
    let value: Int
    let onChanged: (Int) -> Void

    @State private var textFieldValue = ""
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(title) {
                Text("\(value.formatted()) \(unit)")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
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
                    .help("\(preset.formatted()) \(unit)")
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
                    }

                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { onChanged(Int($0)) }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1
                )
            }
        }
        .padding(14)
        .glassSurface(in: .rounded(14))
        .onAppear { textFieldValue = String(value) }
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
