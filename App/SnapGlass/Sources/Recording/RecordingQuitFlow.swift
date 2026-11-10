enum RecordingSessionTerminalOutcome: Equatable, Sendable {
    case saved
    case noActiveSession
    case failed

    var allowsApplicationQuit: Bool {
        switch self {
        case .saved, .noActiveSession:
            true
        case .failed:
            false
        }
    }
}

struct RecordingSessionOutcomeState {
    private(set) var terminalOutcome: RecordingSessionTerminalOutcome?
    private var recordingDidStart = false

    mutating func beginSession() {
        terminalOutcome = nil
        recordingDidStart = false
    }

    mutating func markRecordingStarted() {
        recordingDidStart = true
    }

    mutating func finishSession(wasSaved: Bool) {
        guard terminalOutcome == nil else { return }
        if wasSaved {
            terminalOutcome = .saved
        } else {
            terminalOutcome = recordingDidStart ? .failed : .noActiveSession
        }
        recordingDidStart = false
    }
}

struct RecordingQuitFlow {
    enum Request: Equatable {
        case terminateNow
        case terminateCancel
        case confirm
        case waitForRecording
    }

    private(set) var isHandlingRequest = false

    mutating func request(needsConfirmation: Bool, isSaving: Bool) -> Request {
        guard !isHandlingRequest else { return .terminateCancel }
        if isSaving {
            isHandlingRequest = true
            return .waitForRecording
        }
        guard needsConfirmation else { return .terminateNow }
        isHandlingRequest = true
        return .confirm
    }

    mutating func cancel() {
        isHandlingRequest = false
    }

    mutating func complete(with outcome: RecordingSessionTerminalOutcome?) -> Bool {
        guard isHandlingRequest else { return false }
        isHandlingRequest = false
        return outcome?.allowsApplicationQuit ?? false
    }
}
