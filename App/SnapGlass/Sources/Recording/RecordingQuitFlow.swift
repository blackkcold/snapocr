import CaptureCore

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

enum RecordingAudioSessionState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case stopping
    case finalizing
    case finished
    case failedRecoverable
}

enum RecordingAudioSessionTransition: Equatable, Sendable {
    case begin
    case started
    case stopRequested
    case stopCompleted(saved: Bool)
    case failedRecoverable
}

struct RecordingAudioSessionStateMachine {
    private(set) var state: RecordingAudioSessionState

    init(state: RecordingAudioSessionState = .idle) {
        self.state = state
    }

    mutating func apply(_ transition: RecordingAudioSessionTransition) {
        switch transition {
        case .begin:
            guard state == .idle || state == .finished || state == .failedRecoverable else { return }
            state = .starting
        case .started:
            guard state == .starting else { return }
            state = .recording
        case .stopRequested:
            guard state == .starting || state == .recording else { return }
            state = .stopping
        case .stopCompleted(saved: true):
            guard state == .finalizing else { return }
            state = .finished
        case .stopCompleted(saved: false):
            guard state == .stopping || state == .finalizing else { return }
            state = .failedRecoverable
        case .failedRecoverable:
            guard state != .idle && state != .finished else { return }
            state = .failedRecoverable
        }
    }

    mutating func beginFinalization() {
        guard state == .stopping else { return }
        state = .finalizing
    }

    var legacyStatus: RecordingSessionStatus {
        switch state {
        case .starting: .starting
        case .recording: .recording
        case .stopping, .finalizing: .saving
        case .idle, .finished, .failedRecoverable: .idle
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
