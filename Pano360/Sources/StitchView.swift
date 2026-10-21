import Photos
import SwiftUI

/// Готовая панорама: просмотр сферой или плоско, сохранение в Фото, отправка, пересборка.
struct StitchView: View {
    let sessionDirectory: URL

    @State private var phase: Phase = .loading
    @State private var progress: Double = 0
    @State private var buildRequest = 0
    @State private var viewMode: ViewMode = .sphere
    @State private var saveState: SaveState = .idle

    private enum Phase {
        case loading
        case ready(UIImage, URL)
        case failed(String)
    }

    private enum ViewMode: String, CaseIterable, Identifiable {
        case sphere = "Сфера"
        case flat = "Плоско"
        var id: Self { self }
    }

    private enum SaveState {
        case idle, saving, saved, failed
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch phase {
            case .loading:
                BuildingCard(progress: progress)
            case .failed(let message):
                ContentUnavailableView(
                    "Не удалось собрать панораму",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .ready(let image, _):
                viewer(for: image)
                    .ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if case .ready = phase {
                Picker("Режим просмотра", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .padding(8)
                .glassSurface(in: Capsule())
                .padding(.bottom, 8)
            }
        }
        .navigationTitle("Панорама")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sensoryFeedback(.success, trigger: saveState) { _, new in new == .saved }
        .task(id: buildRequest) { await build(forceRecompute: buildRequest > 0) }
    }

    @ViewBuilder
    private func viewer(for image: UIImage) -> some View {
        switch viewMode {
        case .sphere:
            SphereViewer(image: image)
        case .flat:
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(2, contentMode: .fit)
                        .frame(height: geo.size.height)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if case .ready(_, let fileURL) = phase {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Пересобрать", systemImage: "arrow.clockwise") {
                    buildRequest += 1
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: fileURL)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(saveTitle, systemImage: saveIcon) {
                    Task { await save(fileURL) }
                }
                .disabled(saveState == .saving || saveState == .saved)
            }
        }
    }

    private var saveTitle: String {
        switch saveState {
        case .idle: return "Сохранить в Фото"
        case .saving: return "Сохраняю…"
        case .saved: return "Сохранено в Фото"
        case .failed: return "Повторить сохранение"
        }
    }

    private var saveIcon: String {
        switch saveState {
        case .idle, .saving: return "square.and.arrow.down"
        case .saved: return "checkmark"
        case .failed: return "exclamationmark.arrow.circlepath"
        }
    }

    private func build(forceRecompute: Bool) async {
        phase = .loading
        progress = 0
        saveState = .idle
        let directory = sessionDirectory
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try PanoramaBuilder.build(sessionDirectory: directory, forceRecompute: forceRecompute) { value in
                    Task { @MainActor in progress = value }
                }
            }.value
            phase = .ready(result.image, result.fileURL)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func save(_ fileURL: URL) async {
        saveState = .saving
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveState = .failed
            return
        }
        do {
            // Через addResource(fileURL:), а не через UIImage — иначе пропадут
            // метаданные 360° и геометка.
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: fileURL, options: nil)
            }
            saveState = .saved
        } catch {
            saveState = .failed
        }
    }
}

private struct BuildingCard: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pano")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.panoAccent)
                .symbolEffect(.pulse)
            Text("Склеиваю панораму")
                .font(.headline)
            ProgressView(value: progress)
                .tint(Color.panoAccent)
                .frame(width: 200)
        }
        .padding(32)
        .glassSurface(in: RoundedRectangle(cornerRadius: 28))
        .accessibilityElement(children: .combine)
    }
}
