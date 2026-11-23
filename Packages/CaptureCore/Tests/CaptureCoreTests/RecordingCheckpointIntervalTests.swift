import Testing

@testable import CaptureCore

struct RecordingCheckpointIntervalTests {
    @Test func checkpointIntervalIsShortEnoughForRecovery() {
        // Recovery can only lose the audio since the newest checkpoint; 10 s keeps
        // an interrupted session's loss small. 15 s is the hard upper bound.
        #expect(RecordingSessionPipeline.checkpointIntervalSeconds <= 15)
        #expect(RecordingSessionPipeline.checkpointIntervalSeconds == 10)
    }

    @Test func segmentPolicyKeepsItsOwnCheckpointAge() {
        // The pipeline interval must stay decoupled from the seal target.
        #expect(RecordingSegmentPolicy.maximumCheckpointAge == 300)
    }
}
