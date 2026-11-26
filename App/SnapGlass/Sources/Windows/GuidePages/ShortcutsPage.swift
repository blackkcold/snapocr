import AppKit
import KeyboardShortcuts
import SharedKit
import SwiftUI

/// Page 2: hot keys, editable without leaving the guide.
///
/// The recorder writes through `KeyboardShortcuts` as everywhere else, but the
/// guide also shows whether the assignment can actually fire. Without that badge a
/// user can "successfully" record a combination another app already owns and get
/// no response when they press it — the failure is otherwise completely silent.
struct ShortcutsPage: View {
    /// Conflict per slot, refreshed after each recording.
    @State private var conflicts: [String: ShortcutConflict] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s16) {
            GuidePageHeader(
                title: "Pick your shortcuts.",
                subtitle: "These work from any app. You can change them later in Preferences."
            )

            VStack(spacing: DS.Space.s10) {
                ForEach(ShortcutConflictProbe.slots, id: \.name.rawValue) { slot in
                    GuideShortcutRow(
                        title: slot.actionKey,
                        symbol: Self.symbol(for: slot.name),
                        name: slot.name,
                        conflict: conflicts[slot.name.rawValue],
                        onRecorded: { refresh(slot) }
                    )
                }
            }

            Spacer(minLength: 0)

            Label {
                Text("If another app already uses a combination, the shortcut may not reach SnapGlass.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            for slot in ShortcutConflictProbe.slots {
                refresh(slot)
            }
        }
    }

    /// Re-probes one slot after its recorder changed.
    ///
    /// - Parameter slot: The slot that changed.
    private func refresh(_ slot: ShortcutConflictProbe.Slot) {
        let shortcut = KeyboardShortcuts.getShortcut(for: slot.name)
        let result = ShortcutConflictProbe.probe(shortcut, for: slot.name)
        if let result {
            conflicts[slot.name.rawValue] = result
        } else {
            conflicts[slot.name.rawValue] = nil
        }
    }

    private static func symbol(for name: KeyboardShortcuts.Name) -> String {
        switch name.rawValue {
        case KeyboardShortcuts.Name.captureArea.rawValue: "viewfinder"
        case KeyboardShortcuts.Name.captureWindow.rawValue: "macwindow"
        default: "record.circle"
        }
    }
}

/// One label-and-recorder row, with a conflict badge.
struct GuideShortcutRow: View {
    /// Localization key for the row title.
    let title: String
    /// SF Symbol shown before the title.
    let symbol: String
    /// The shortcut slot to edit.
    let name: KeyboardShortcuts.Name
    /// Conflict found for the current assignment, if any.
    let conflict: ShortcutConflict?
    /// Called after the recorder writes a new value.
    let onRecorded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            HStack(spacing: DS.Space.s12) {
                Label {
                    Text(LocalizedStringKey(title))
                        .font(DS.Typography.body)
                } icon: {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let badge = badge(for: conflict) {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(badge.tint)
                        .accessibilityLabel(Text(LocalizedStringKey(badge.labelKey)))
                }

                KeyboardShortcuts.Recorder(for: name, onChange: { _ in onRecorded() })
                    .fixedSize()
            }

            if let message = message(for: conflict) {
                HStack(spacing: DS.Space.s4) {
                    Text(message.text)
                        .font(DS.Typography.caption)
                        .foregroundStyle(message.tint)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.vertical, DS.Space.s10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: DS.Corner.c10))
    }

    /// The small status icon shown beside the recorder.
    ///
    /// A struct rather than a tuple: three members in a tuple trips the linter, and
    /// named fields read better at the call site.
    private struct ConflictBadge {
        let symbol: String
        let tint: Color
        let labelKey: String
    }

    private func badge(for conflict: ShortcutConflict?) -> ConflictBadge? {
        // Unwrap before switching: `ShortcutConflict.none` and `Optional.none`
        // share a name, and in a switch over an optional the compiler resolves
        // `.none` to the optional case, which silently makes the conflict case
        // unreachable.
        guard let conflict else { return nil }
        switch conflict {
        case .none, .unknown:
            return nil
        case .duplicateInApp:
            return ConflictBadge(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                labelKey: "Duplicate shortcut"
            )
        case .systemReserved:
            return ConflictBadge(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                labelKey: "Reserved by macOS"
            )
        case .takenByAnotherApp:
            return ConflictBadge(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                labelKey: "Used by another app"
            )
        }
    }

    /// Explanation under the row, with what the user can do about it.
    private func message(for conflict: ShortcutConflict?) -> (text: String, tint: Color)? {
        guard let conflict else { return nil }
        switch conflict {
        case .duplicateInApp(let action):
            // The action name is a localization key, so it has to be localized before
            // being substituted into the sentence.
            return (
                String(
                    format: AppLocalization.string("Already used by %@."),
                    AppLocalization.string(action)
                ),
                .orange
            )
        case .systemReserved:
            return (AppLocalization.string("macOS reserves this combination. Choose another one."), .orange)
        case .takenByAnotherApp:
            // "May not work" rather than "will not work": the other app may have
            // quit and left the registration behind, so forbidding it outright
            // would trap the user for no reason.
            return (
                AppLocalization.string("Another app may already use this combination, so it may not work."),
                .orange
            )
        case .none, .unknown:
            return nil
        }
    }
}
