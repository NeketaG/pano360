import SwiftUI

enum Route: Hashable {
    case gallery
    case panorama(URL)
}

struct ContentView: View {
    @State private var path: [Route] = []
    @State private var isCapturing = false

    var body: some View {
        NavigationStack(path: $path) {
            HomeView { isCapturing = true }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .gallery:
                        GalleryView()
                    case .panorama(let directory):
                        StitchView(sessionDirectory: directory)
                    }
                }
        }
        .fullScreenCover(isPresented: $isCapturing) {
            CaptureView { directory in
                isCapturing = false
                path.append(.panorama(directory))
            }
        }
    }
}

private struct HomeView: View {
    let onCapture: () -> Void

    @State private var backdrop: UIImage?

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 28) {
                Spacer()

                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "pano.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color.panoAccent)
                    Text("Pano360")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                    Text("Сферические панорамы 360°. Снимай по точкам — склейка прямо на телефоне.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }

                VStack(spacing: 12) {
                    Button(action: onCapture) {
                        Label("Снять панораму", systemImage: "camera.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .primaryActionStyle()

                    NavigationLink(value: Route.gallery) {
                        Label("Мои панорамы", systemImage: "square.stack.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .secondaryActionStyle()
                }
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .toolbar(.hidden, for: .navigationBar) // toolbarVisibility — только с iOS 18
        .task {
            let image = await Self.loadLatestPanorama()
            withAnimation(.easeInOut(duration: 0.8)) { backdrop = image }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let backdrop {
            PanoramaBackdrop(image: backdrop)
                .transition(.opacity)
        } else {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.12, blue: 0.22), .black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        // Затемнение снизу, чтобы текст и кнопки читались на любой панораме
        LinearGradient(
            colors: [.black.opacity(0.15), .black.opacity(0.35), .black.opacity(0.85)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private static func loadLatestPanorama() async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let latest = CaptureLibrary.load().first(where: { $0.hasPanorama }) else { return nil }
            return CaptureLibrary.thumbnail(for: latest, maxPixelSize: 3000)
        }.value
    }
}
