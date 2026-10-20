import SwiftUI

private enum Flow: Equatable {
    case idle
    case capturing
    case stitching(URL)
    case gallery
}

struct ContentView: View {
    @State private var flow: Flow = .idle

    var body: some View {
        VStack(spacing: 16) {
            Text("Pano360")
                .font(.largeTitle.bold())
            Text("Сними панораму 360°, следуя за точками на экране.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button {
                flow = .capturing
            } label: {
                Text("Начать съёмку")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .padding(.top, 8)

            Button {
                flow = .gallery
            } label: {
                Text("Мои панорамы")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 40)
        }
        .padding()
        .fullScreenCover(isPresented: Binding(
            get: { flow == .capturing },
            set: { isPresented in if !isPresented { flow = .idle } }
        )) {
            CaptureView { directory in
                flow = .stitching(directory)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: {
                if case .stitching = flow { return true }
                return false
            },
            set: { isPresented in if !isPresented { flow = .idle } }
        )) {
            if case .stitching(let directory) = flow {
                StitchView(sessionDirectory: directory) {
                    flow = .idle
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { flow == .gallery },
            set: { isPresented in if !isPresented { flow = .idle } }
        )) {
            GalleryView(
                onClose: { flow = .idle },
                onOpen: { directory in flow = .stitching(directory) }
            )
        }
    }
}
