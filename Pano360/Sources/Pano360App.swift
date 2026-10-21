import SwiftUI

@main
struct Pano360App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Color.panoAccent)
                // Камера и панорамы смотрятся лучше на тёмном фоне
                .preferredColorScheme(.dark)
        }
    }
}
