import Foundation
import KeyboardShortcuts

/// What an assigned shortcut collides with.
///
/// The order of cases matches the reliability order of the detection sources:
/// an in-app duplicate is certain, a system reservation is highly likely, and a
/// failed carbon registration is the only way to detect a third-party app.
public enum ShortcutConflict: Equatable, Sendable {
    /// Nothing found; the shortcut is free as far as this app can tell.
    case none
    /// Another SnapGlass action already uses this combination.
    case duplicateInApp(action: String)
    /// macOS itself reserves this combination.
    case systemReserved
    /// `RegisterEventHotKey` refused the combination: another app holds it.
    case takenByAnotherApp
    /// The probe could not run. Treated as "no conflict" but worth recording.
    case unknown
}

/// Shortcuts macOS reserves for itself.
///
/// `KeyboardShortcuts.Shortcut.isTakenBySystem` is `internal`, so the app cannot
/// read it. This is the substitute: a deliberate subset of macOS's own bindings,
/// covering the ones a user is most likely to try. It is a heuristic — being
/// absent from this list means "not known to be reserved", not "free".
public enum SystemShortcutCatalog {
    /// One reserved combination and why it is reserved.
    public struct Entry: Sendable {
        /// The reserved combination.
        public let shortcut: KeyboardShortcuts.Shortcut
        /// Human-readable reason shown in the conflict message.
        public let reason: String

        /// Creates an entry.
        ///
        /// - Parameters:
        ///   - shortcut: The reserved combination.
        ///   - reason: Human-readable reason.
        public init(shortcut: KeyboardShortcuts.Shortcut, reason: String) {
            self.shortcut = shortcut
            self.reason = reason
        }
    }

    /// Combinations macOS binds globally.
    ///
    /// Screenshot and system commands are the realistic collision cases; obscurer
    /// ones are omitted on purpose so the list stays verifiable.
    public static let entries: [Entry] = [
        Entry(shortcut: .init(.three, modifiers: [.command, .shift]), reason: "Screenshot selection"),
        Entry(shortcut: .init(.four, modifiers: [.command, .shift]), reason: "Screenshot window"),
        Entry(shortcut: .init(.five, modifiers: [.command, .shift]), reason: "Screenshot toolbar"),
        Entry(shortcut: .init(.q, modifiers: [.command, .control]), reason: "Lock Screen"),
        Entry(shortcut: .init(.q, modifiers: [.command, .shift]), reason: "Log Out"),
        Entry(shortcut: .init(.escape, modifiers: [.command, .option]), reason: "Force Quit"),
        Entry(shortcut: .init(.space, modifiers: [.command]), reason: "Spotlight"),
        Entry(shortcut: .init(.f, modifiers: [.command, .control]), reason: "Full Screen"),
        Entry(shortcut: .init(.period, modifiers: [.command, .shift]), reason: "Hidden Files"),
        Entry(shortcut: .init(.backslash, modifiers: [.command, .option]), reason: "Finder Search Scope"),
    ]

    /// Whether macOS reserves `shortcut`.
    ///
    /// - Parameter shortcut: The candidate.
    /// - Returns: `true` when the combination appears in ``entries``.
    public static func reserves(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        entries.contains { normalized($0.shortcut) == normalized(shortcut) }
    }

    /// Rebuilds a shortcut through the normalizing initializer.
    ///
    /// Caps Lock and the function flag arrive depending on which keyboard produced
    /// the event; comparing them would make the same combination match or not match
    /// at random.
    ///
    /// - Parameter shortcut: The shortcut to normalize.
    /// - Returns: An equivalent shortcut with normalized modifiers.
    public static func normalized(_ shortcut: KeyboardShortcuts.Shortcut) -> KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(
            carbonKeyCode: shortcut.carbonKeyCode,
            carbonModifiers: shortcut.carbonModifiers
        )
    }
}

/// An action and the shortcut slot it occupies.
public struct ShortcutAssignment: Equatable, Sendable {
    /// Localization key naming the action, shown in the conflict message.
    public let action: String
    /// The combination currently assigned.
    public let shortcut: KeyboardShortcuts.Shortcut

    /// Creates an assignment.
    ///
    /// - Parameters:
    ///   - action: Localization key naming the action.
    ///   - shortcut: The combination assigned to it.
    public init(action: String, shortcut: KeyboardShortcuts.Shortcut) {
        self.action = action
        self.shortcut = shortcut
    }
}

/// Detects conflicts in the sources that need no system call.
///
/// The third source — actually attempting to register the hot key — lives in the
/// app, because it touches Carbon. Keeping these two here makes them testable
/// without a running application.
public enum ShortcutConflictDetector {
    /// Whether two combinations are the same key with the same modifiers.
    ///
    /// Both sides are normalized first: `KeyboardShortcuts` normalizes modifiers on
    /// construction, but a value read back from another source may not be.
    ///
    /// - Parameters:
    ///   - lhs: One combination.
    ///   - rhs: The other combination.
    /// - Returns: `true` when both address the same key and modifiers.
    public static func isSame(
        _ lhs: KeyboardShortcuts.Shortcut,
        _ rhs: KeyboardShortcuts.Shortcut
    ) -> Bool {
        let left = SystemShortcutCatalog.normalized(lhs)
        let right = SystemShortcutCatalog.normalized(rhs)
        return left.carbonKeyCode == right.carbonKeyCode
            && left.carbonModifiers == right.carbonModifiers
    }

    /// Checks a candidate against the other assignments and against macOS.
    ///
    /// In-app duplication is reported before system reservation: a duplicate the
    /// user can fix inside the app is more actionable than a system rule they
    /// cannot change.
    ///
    /// - Parameters:
    ///   - candidate: The combination being assigned.
    ///   - assignments: Every other action's current assignment.
    /// - Returns: The first conflict found, or `.none`.
    public static func conflict(
        for candidate: KeyboardShortcuts.Shortcut,
        among assignments: [ShortcutAssignment]
    ) -> ShortcutConflict {
        if let duplicate = assignments.first(where: { isSame($0.shortcut, candidate) }) {
            return .duplicateInApp(action: duplicate.action)
        }
        if SystemShortcutCatalog.reserves(candidate) {
            return .systemReserved
        }
        return .none
    }
}
