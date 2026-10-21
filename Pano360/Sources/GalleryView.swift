import SwiftUI

struct GalleryView: View {
    @State private var captures: [SavedCapture] = []
    @State private var isLoaded = false
    @State private var pendingDeletion: SavedCapture?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(captures) { capture in
                    NavigationLink(value: Route.panorama(capture.id)) {
                        GalleryCard(capture: capture)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Удалить", systemImage: "trash", role: .destructive) {
                            pendingDeletion = capture
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .overlay {
            if isLoaded && captures.isEmpty {
                ContentUnavailableView(
                    "Пока нет панорам",
                    systemImage: "pano",
                    description: Text("Сними первую — кнопка на главном экране.")
                )
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Мои панорамы")
        .confirmationDialog(
            "Удалить панораму?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { capture in
            Button("Удалить", role: .destructive) { delete(capture) }
        } message: { _ in
            Text("Будут удалены все кадры этой съёмки.")
        }
        .task {
            captures = await Self.loadCaptures()
            isLoaded = true
        }
    }

    private func delete(_ capture: SavedCapture) {
        CaptureLibrary.delete(capture)
        withAnimation(.snappy) {
            captures.removeAll { $0.id == capture.id }
        }
    }

    private static func loadCaptures() async -> [SavedCapture] {
        await Task.detached(priority: .userInitiated) { CaptureLibrary.load() }.value
    }
}

private struct GalleryCard: View {
    let capture: SavedCapture

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .overlay {
                            Image(systemName: capture.hasPanorama ? "photo" : "pano")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(2, contentMode: .fit)
            .clipped()

            HStack(spacing: 8) {
                Text(capture.date, format: .dateTime.day().month(.wide).hour().minute())
                    .font(.subheadline.weight(.semibold))
                if !capture.hasPanorama {
                    Text("ещё не склеена")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassSurface(in: Capsule())
            .padding(12)
        }
        .clipShape(.rect(cornerRadius: 24))
        .contentShape(.rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
        .task(id: capture.id) {
            let capture = capture
            thumbnail = await Task.detached(priority: .utility) {
                CaptureLibrary.thumbnail(for: capture, maxPixelSize: 1400)
            }.value
        }
    }
}
