import CoreGraphics

/// Screen-recording access decided immediately before the writer starts.
///
/// The source picker already probes access, but that probe can be a minute old by
/// the time the countdown ends, and a revoked grant must fail before any file is
/// created. This gate is the last check: it never starts capture on a denial, so
/// the session cannot sit in "waiting for the first frame" with no access.
///
/// The two system calls are injected so a test — or the agent channel — can prove
/// the denied path without changing the machine's TCC state.
struct ScreenCapturePermissionGate: Sendable {
    /// What the gate decided for one start attempt.
    enum Decision: Equatable, Sendable {
        /// Access is granted; capture may start.
        case granted
        /// Access was refused. The caller must fail immediately with the
        /// System Settings guidance instead of arming the first-frame deadline.
        case denied
    }

    /// Synchronous preflight, usually `CGPreflightScreenCaptureAccess`.
    private let preflight: @Sendable () -> Bool
    /// One-shot request, usually `CGRequestScreenCaptureAccess`.
    private let request: @Sendable () -> Bool

    /// Creates a gate from its two system calls.
    ///
    /// - Parameters:
    ///   - preflight: Whether access is already granted.
    ///   - request: The one request call made when the preflight is false.
    init(preflight: @escaping @Sendable () -> Bool, request: @escaping @Sendable () -> Bool) {
        self.preflight = preflight
        self.request = request
    }

    /// The real system gate.
    static let system = ScreenCapturePermissionGate(
        preflight: { CGPreflightScreenCaptureAccess() },
        request: { CGRequestScreenCaptureAccess() }
    )

    /// A gate that always grants, for tests that exercise other writer paths.
    static let granted = ScreenCapturePermissionGate(preflight: { true }, request: { true })

    /// A gate that always denies, mirroring a machine where screen recording is off.
    static let denied = ScreenCapturePermissionGate(preflight: { false }, request: { false })

    /// Decides access for one start attempt.
    ///
    /// When the preflight is false the gate asks once and still fails this
    /// attempt: the system prompt is asynchronous, so continuing would start a
    /// writer with no frames and hide the real cause behind a first-frame timeout.
    ///
    /// - Returns: The decision for this attempt.
    func decide() -> Decision {
        if preflight() { return .granted }
        _ = request()
        return .denied
    }
}

/// User-facing copy for the screen-permission denial.
///
/// Kept next to the gate so the failure path and the settings guidance cannot
/// drift apart. The key is resolved with `AppLocalization` by the caller, which
/// keeps this file free of app-only dependencies and unit-testable.
enum ScreenCapturePermissionCopy {
    /// The one sentence shown when screen recording is off.
    static let deniedKey = "Screen recording access is off. Enable SnapGlass in System Settings → Privacy & Security → Screen Recording, then try again."  // swiftlint:disable:this line_length
}
