import SwiftUI

struct WindowsView: View {
    @EnvironmentObject private var captureViewModel: CaptureViewModel

    var body: some View {
        TabView {
            PreferencesView()
                .tabItem { Label("Preferences", systemImage: "gear") }

            HistoryView()
                .environmentObject(captureViewModel)
                .tabItem { Label("History", systemImage: "clock") }
        }
    }
}
