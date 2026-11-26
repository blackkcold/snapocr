import Foundation

/// A small, app-wide hand-off from the recording HUD to the unified library.
///
/// The HUD cannot hold a reference to the library window's view model, and the
/// deep link must survive the window being created after the recording ends.
@MainActor
final class LibraryDeepLink: ObservableObject {
    enum Action: String, Sendable {
        case select
        case merge
    }

    struct Request: Equatable, Sendable, Identifiable {
        let id: UUID
        let sessionID: UUID?
        let action: Action

        init(id: UUID = UUID(), sessionID: UUID?, action: Action) {
            self.id = id
            self.sessionID = sessionID
            self.action = action
        }
    }

    static let shared = LibraryDeepLink()

    @Published private(set) var request: Request?

    private init() {}

    func send(sessionID: UUID?, action: Action) {
        request = Request(sessionID: sessionID, action: action)
    }

    func consume() -> Request? {
        defer { request = nil }
        return request
    }
}
