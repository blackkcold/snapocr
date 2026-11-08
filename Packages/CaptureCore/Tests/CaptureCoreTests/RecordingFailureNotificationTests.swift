import Foundation
import Testing

@testable import CaptureCore

struct RecordingFailureNotificationTests {
    @Test func forwardsOnlyTheFirstWriterOrStreamFailure() {
        let observer = FailureObserver()
        var relay = RecordingFailureRelay { message in
            observer.receive(message)
        }

        relay.record("The media writer rejected a video sample.")
        relay.record("The capture stream stopped unexpectedly.")

        #expect(relay.message == "The media writer rejected a video sample.")
        #expect(observer.messages == ["The media writer rejected a video sample."])
    }
}

private final class FailureObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMessages: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMessages
    }

    func receive(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedMessages.append(message)
    }
}
