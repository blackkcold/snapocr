import Dispatch
import Foundation
import Testing

@testable import CaptureCore

struct AudioRingAtomicCursorTests {
    private final class SequencedBox: @unchecked Sendable {
        let gate: AudioOwnershipGate
        var value = 0

        init(gate: AudioOwnershipGate) {
            self.gate = gate
        }

        func writeFirstValue() {
            if gate.tryAcquire() {
                value = 41
                gate.release()
            }
        }

        func writeSecondValue() {
            if gate.tryAcquire() {
                value += 1
                gate.release()
            }
        }
    }

    @Test(arguments: [AudioAtomicBackendMode.automatic, AudioAtomicBackendMode.legacyForTesting])
    func counterReturnsOldValuesAndLoadsLatest(mode: AudioAtomicBackendMode) {
        let counter = AudioAtomicCounterFactory.make(mode: mode)

        #expect(counter.loadAcquire() == 0)
        #expect(counter.fetchAddRelease(5) == 0)
        #expect(counter.fetchAddAcqRel(7) == 5)
        #expect(counter.loadAcquire() == 12)
        #expect(counter.fetchAddRelease(-2) == 12)
        #expect(counter.loadAcquire() == 10)
    }

    @Test(arguments: [AudioAtomicBackendMode.automatic, AudioAtomicBackendMode.legacyForTesting])
    func ownershipGateRejectsOverlappingAcquisition(mode: AudioAtomicBackendMode) {
        let gate = AudioOwnershipGate(mode: mode)

        #expect(gate.isHeld == false)
        #expect(gate.tryAcquire())
        #expect(gate.isHeld)
        #expect(gate.tryAcquire() == false)
        #expect(gate.maxObservedDepth == 1)
        gate.release()
        #expect(gate.isHeld == false)
        #expect(gate.tryAcquire())
        gate.release()
        #expect(gate.isHeld == false)
    }

    @Test(arguments: [AudioAtomicBackendMode.automatic, AudioAtomicBackendMode.legacyForTesting])
    func ownershipHandoffPublishesPreviousOwnerPrivateState(mode: AudioAtomicBackendMode) throws {
        let gate = AudioOwnershipGate(mode: mode)
        let box = SequencedBox(gate: gate)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "audio.atomic.handoff", attributes: .concurrent)

        queue.async {
            box.writeFirstValue()
            firstFinished.signal()
        }
        firstFinished.wait()

        queue.async {
            box.writeSecondValue()
            secondFinished.signal()
        }
        secondFinished.wait()

        #expect(box.value == 42)
    }

    @Test func automaticBackendIsAvailableOnCurrentSystem() {
        let counter = AudioAtomicCounterFactory.make(mode: .automatic)

        counter.fetchAddAcqRel(1)
        #expect(counter.loadAcquire() == 1)
    }
}
