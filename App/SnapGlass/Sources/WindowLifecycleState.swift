struct WindowLifecycleState: Equatable {
    struct PresentationStart: Equatable {
        let generation: Int
        let isNew: Bool
    }

    private(set) var registeredWindowIDs: Set<String> = []
    private(set) var pendingPresentations: [String: Int] = [:]
    private var nextGeneration = 0

    var shouldUseAccessoryPolicy: Bool {
        registeredWindowIDs.isEmpty && pendingPresentations.isEmpty
    }

    mutating func beginPresentation(id: String) -> PresentationStart {
        if let generation = pendingPresentations[id] {
            return PresentationStart(generation: generation, isNew: false)
        }

        nextGeneration += 1
        pendingPresentations[id] = nextGeneration
        return PresentationStart(generation: nextGeneration, isNew: true)
    }

    mutating func registerWindow(id: String) {
        registeredWindowIDs.insert(id)
    }

    mutating func unregisterWindow(id: String) {
        registeredWindowIDs.remove(id)
    }

    mutating func completePresentation(id: String) {
        pendingPresentations[id] = nil
    }

    mutating func completePresentation(id: String, generation: Int) {
        guard pendingPresentations[id] == generation else { return }
        pendingPresentations[id] = nil
    }

    func isPresentationPending(id: String) -> Bool {
        pendingPresentations[id] != nil
    }

    func isCurrentPresentation(id: String, generation: Int) -> Bool {
        pendingPresentations[id] == generation
    }
}
