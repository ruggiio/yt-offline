import SwiftUI
import AVFoundation

@main
struct YTOfflineApp: App {
    init() {
        // Audio anche col tasto silenzioso e a schermo bloccato.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @StateObject private var store = Store()

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Libreria", systemImage: "play.rectangle.fill") }
            PCView()
                .tabItem { Label("PC", systemImage: "desktopcomputer") }
        }
        .environmentObject(store)
    }
}
