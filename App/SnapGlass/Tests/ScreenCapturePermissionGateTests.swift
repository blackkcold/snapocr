import Foundation
import Testing

/// Tests for the gate that decides screen access immediately before the writer.
///
/// The system calls are injected, so these never read or change the machine's TCC
/// state; they only prove the decision and the request count.
@Suite("Screen capture permission gate")
struct ScreenCapturePermissionGateTests {
    @Test("A granted preflight never asks again")
    func grantedPreflightDoesNotRequest() {
        let requests = CallCounter()
        let gate = ScreenCapturePermissionGate(
            preflight: { true },
            request: {
                requests.increment()
                return false
            }
        )

        #expect(gate.decide() == .granted)
        #expect(requests.value == 0)
    }

    @Test("A denied preflight asks exactly once and still fails this attempt")
    func deniedPreflightRequestsOnce() {
        let requests = CallCounter()
        let gate = ScreenCapturePermissionGate(
            preflight: { false },
            request: {
                requests.increment()
                // Even a granted answer must not continue this attempt: the system
                // prompt is asynchronous and the writer would start with no frames.
                return true
            }
        )

        #expect(gate.decide() == .denied)
        #expect(requests.value == 1)

        // A retry is a new attempt, so it asks once more.
        #expect(gate.decide() == .denied)
        #expect(requests.value == 2)
    }

    @Test("The denial copy names the System Settings pane")
    func denialCopyNamesSettingsPane() {
        let copy = ScreenCapturePermissionCopy.deniedKey

        // The test host may resolve a different app language, so accept every
        // translation while still requiring the exact pane.
        let namesSettings = ["System Settings", "系统设置", "システム設定", "시스템 설정"]
            .contains { copy.contains($0) }
        #expect(namesSettings)
        #expect(copy.contains("→"))
    }
}

/// Thread-safe call counter for the injected permission callbacks.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
