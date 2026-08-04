import SwiftUI

/// Shares the selected Settings section with the app menu and opens windows.
@MainActor
final class PreferencesRouter: ObservableObject {
    @Published var selectedSection: PreferencesSection = .general

    /// Set during app lifecycle; mirrors `CaptureViewModel.openWindow`.
    var openWindow: ((String) -> Void)?

    func present(section: PreferencesSection) {
        selectedSection = section
        openWindow?("preferences")
    }

    /// Opens Preferences on the About tab.
    func presentAbout() {
        present(section: .about)
    }

    /// Opens Preferences on the Updates tab.
    func presentUpdates() {
        present(section: .updates)
    }

    /// Opens Preferences on the General tab.
    func presentSettings() {
        present(section: .general)
    }
}
