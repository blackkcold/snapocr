import Testing

@Suite("Window lifecycle state")
struct WindowLifecycleStateTests {
    @Test("Close then reopen creates a fresh presentation")
    func closeThenReopen() {
        var state = WindowLifecycleState()

        let first = state.beginPresentation(id: "history")
        state.registerWindow(id: "history")
        state.completePresentation(id: "history")
        state.unregisterWindow(id: "history")

        #expect(first.isNew)
        #expect(state.shouldUseAccessoryPolicy)

        let second = state.beginPresentation(id: "history")
        #expect(second.isNew)
        #expect(second.generation > first.generation)
        #expect(!state.shouldUseAccessoryPolicy)
    }

    @Test("Repeated presentation calls are idempotent while pending")
    func repeatedPresentationIsIdempotent() {
        var state = WindowLifecycleState()

        let first = state.beginPresentation(id: "history")
        let repeated = state.beginPresentation(id: "history")

        #expect(first.isNew)
        #expect(!repeated.isNew)
        #expect(repeated.generation == first.generation)
        #expect(state.pendingPresentations.count == 1)
    }

    @Test("Registered windows alone cannot block accessory policy")
    func registeredWindowsDoNotBlockAccessoryPolicy() {
        var state = WindowLifecycleState()

        state.registerWindow(id: "history")
        state.registerWindow(id: "preferences")

        #expect(state.shouldUseAccessoryPolicy)
    }

    @Test("A pending presentation prevents accessory downgrade until it completes")
    func pendingPresentationPreventsAccessoryDowngrade() {
        var state = WindowLifecycleState()

        state.registerWindow(id: "history")
        _ = state.beginPresentation(id: "preferences")
        state.unregisterWindow(id: "history")

        #expect(!state.shouldUseAccessoryPolicy)

        state.registerWindow(id: "preferences")
        state.completePresentation(id: "preferences")
        #expect(state.shouldUseAccessoryPolicy)
    }

    @Test("A stale timeout cannot clear a newer presentation")
    func staleGenerationCannotCompleteNewPresentation() {
        var state = WindowLifecycleState()

        let first = state.beginPresentation(id: "editor")
        state.completePresentation(id: "editor")
        let second = state.beginPresentation(id: "editor")
        state.completePresentation(id: "editor", generation: first.generation)

        #expect(state.isCurrentPresentation(id: "editor", generation: second.generation))
    }

    @Test("Different windows keep independent pending state")
    func windowsDoNotCancelEachOther() {
        var state = WindowLifecycleState()

        let history = state.beginPresentation(id: "history")
        let preferences = state.beginPresentation(id: "preferences")
        state.completePresentation(id: "history", generation: history.generation)

        #expect(!state.isPresentationPending(id: "history"))
        #expect(state.isCurrentPresentation(id: "preferences", generation: preferences.generation))
        #expect(!state.shouldUseAccessoryPolicy)
    }
}
