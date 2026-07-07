import SwiftUI

struct WindowsView: View {
    var body: some View {
        TabView {
            PreferencesView()
                .tabItem { Label("Preferences", systemImage: "gear") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
        }
    }
}
