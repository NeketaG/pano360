import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Pano360 работает!")
                .font(.title)
            Text("Если ты видишь этот экран — сборка без Мака получилась.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
