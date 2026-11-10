import Foundation
import Testing

@testable import CaptureCore

struct RecordingWriterLifecycleTests {
    @Test func writerStartWithoutAcceptedVideoSampleDiscardsPartial() {
        let decision = RecordingWriterFinalizationDecision.beforeFinishing(
            hasAcceptedVideoSample: false,
            writerIsWriting: true,
            failureMessage: nil,
            writerError: nil
        )

        #expect(decision == .discardPartial(reason: "No video frame was captured."))
    }

    @Test func firstAppendRejectionDiscardsHeaderOnlyPartial() {
        let decision = RecordingWriterFinalizationDecision.beforeFinishing(
            hasAcceptedVideoSample: false,
            writerIsWriting: true,
            failureMessage: "The media writer rejected a video sample.",
            writerError: nil
        )

        #expect(decision == .discardPartial(reason: "The media writer rejected a video sample."))
    }

    @Test func acceptedVideoSampleFollowedByAppendFailureRetainsPartial() {
        let decision = RecordingWriterFinalizationDecision.afterFinishing(
            hasAcceptedVideoSample: true,
            writerCompleted: true,
            failureMessage: "The media writer rejected a later video sample.",
            writerError: nil
        )

        #expect(decision == .retainPartial(reason: "The media writer rejected a later video sample."))
    }

    @Test func streamFailureBeforeFirstAcceptedSampleDiscardsPartial() {
        let decision = RecordingWriterFinalizationDecision.beforeFinishing(
            hasAcceptedVideoSample: false,
            writerIsWriting: true,
            failureMessage: "The capture stream stopped unexpectedly.",
            writerError: nil
        )

        #expect(decision == .discardPartial(reason: "The capture stream stopped unexpectedly."))
    }

    @Test func writerFailureAfterAcceptedVideoSampleRetainsPartial() {
        let decision = RecordingWriterFinalizationDecision.beforeFinishing(
            hasAcceptedVideoSample: true,
            writerIsWriting: false,
            failureMessage: nil,
            writerError: "The media writer failed."
        )

        #expect(decision == .retainPartial(reason: "The media writer failed."))
    }

    @Test func acceptedVideoSampleWithWritingWriterFinishesBeforePublication() {
        let decision = RecordingWriterFinalizationDecision.beforeFinishing(
            hasAcceptedVideoSample: true,
            writerIsWriting: true,
            failureMessage: nil,
            writerError: nil
        )

        #expect(decision == .finishWriting)
    }

    @Test func incompleteWriterAfterAcceptedVideoSampleRetainsPartial() {
        let decision = RecordingWriterFinalizationDecision.afterFinishing(
            hasAcceptedVideoSample: true,
            writerCompleted: false,
            failureMessage: nil,
            writerError: "The media writer did not finish successfully."
        )

        #expect(decision == .retainPartial(reason: "The media writer did not finish successfully."))
    }

    @Test func priorFailureAfterWriterCompletionRetainsPartial() {
        let decision = RecordingWriterFinalizationDecision.afterFinishing(
            hasAcceptedVideoSample: true,
            writerCompleted: true,
            failureMessage: "The capture stream stopped unexpectedly.",
            writerError: nil
        )

        #expect(decision == .retainPartial(reason: "The capture stream stopped unexpectedly."))
    }

    @Test func stopErrorAfterAcceptedVideoSampleRetainsPartial() {
        let decision = RecordingWriterFinalizationDecision.afterFinishing(
            hasAcceptedVideoSample: true,
            writerCompleted: true,
            failureMessage: "The capture stream could not stop cleanly: device disconnected",
            writerError: nil
        )

        #expect(decision == .retainPartial(
            reason: "The capture stream could not stop cleanly: device disconnected"
        ))
    }

    @Test func completedWriterWithoutFailureRequestsPublication() {
        let decision = RecordingWriterFinalizationDecision.afterFinishing(
            hasAcceptedVideoSample: true,
            writerCompleted: true,
            failureMessage: nil,
            writerError: nil
        )

        #expect(decision == .publish)
    }
}
