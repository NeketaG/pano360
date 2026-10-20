import SwiftUI

struct ContentView: View {
    @State private var showCapture = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Pano360")
                .font(.largeTitle.bold())
            Text("Сними панораму 360°, следуя за точками на экране.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button {
                showCapture = true
            } label: {
                Text("Начать съёмку")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
        }
        .padding()
        .fullScreenCover(isPresented: $showCapture) {
            CaptureView()
        }
    }
}
