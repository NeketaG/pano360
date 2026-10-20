import Photos
import SwiftUI

struct StitchView: View {
    let sessionDirectory: URL
    let onClose: () -> Void

    @State private var progress: Double = 0
    @State private var resultImage: UIImage?
    @State private var cachedFileURL: URL?
    @State private var errorText: String?
    @State private var saveState: SaveState = .idle
    @State private var viewMode: ViewMode = .sphere
    @State private var isRecomputing = false

    private enum SaveState {
        case idle, saving, saved, failed
    }

    private enum ViewMode: String, CaseIterable {
        case sphere = "Сфера"
        case flat = "Плоско"
    }

    private var cacheURL: URL {
        sessionDirectory.appendingPathComponent("panorama.jpg")
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                if resultImage != nil {
                    Button {
                        runStitch(forceRecompute: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                    }
                    .disabled(isRecomputing)
                    .padding()
                }
                Spacer()
                Button("Готово") { onClose() }
                    .padding()
            }

            Spacer()

            if let resultImage {
                Picker("Режим просмотра", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 40)

                if viewMode == .sphere {
                    SphereViewer(image: resultImage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: resultImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 1000)
                    }
                }

                Button {
                    save()
                } label: {
                    Text(saveButtonTitle)
                }
                .buttonStyle(.borderedProminent)
                .disabled(saveState == .saving || saveState == .saved)
                .padding(.bottom, 24)
            } else if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .padding()
            } else {
                ProgressView(value: progress)
                    .padding(.horizontal, 40)
                Text("Склеиваю панораму…")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .onAppear { runStitch(forceRecompute: false) }
    }

    private var saveButtonTitle: String {
        switch saveState {
        case .idle: return "Сохранить в Фото"
        case .saving: return "Сохраняю…"
        case .saved: return "Сохранено в Фото"
        case .failed: return "Не получилось. Повторить"
        }
    }

    private func runStitch(forceRecompute: Bool) {
        let directory = sessionDirectory
        let cache = cacheURL

        if !forceRecompute, FileManager.default.fileExists(atPath: cache.path), let cached = UIImage(contentsOfFile: cache.path) {
            resultImage = cached
            cachedFileURL = cache
            return
        }

        isRecomputing = true
        errorText = nil
        resultImage = nil
        progress = 0

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let manifest = try PanoramaStitcher.loadManifest(sessionDirectory: directory)
                guard !manifest.frames.isEmpty else {
                    DispatchQueue.main.async { errorText = "В этой съёмке нет кадров."; isRecomputing = false }
                    return
                }
                let refinedFrames = AlignmentRefiner.refine(frames: manifest.frames) { value in
                    DispatchQueue.main.async { progress = value * 0.5 }
                }
                let cgImage = PanoramaStitcher.stitch(
                    frames: refinedFrames,
                    outputSize: CGSize(width: 2048, height: 1024)
                ) { value in
                    DispatchQueue.main.async { progress = 0.5 + value * 0.5 }
                }
                guard let cgImage else {
                    DispatchQueue.main.async { errorText = "Не получилось собрать панораму."; isRecomputing = false }
                    return
                }
                try? PanoramaStitcher.writeEquirectangularJPEG(cgImage, to: cache, latitude: manifest.latitude, longitude: manifest.longitude)
                let uiImage = UIImage(cgImage: cgImage)
                DispatchQueue.main.async {
                    resultImage = uiImage
                    cachedFileURL = cache
                    isRecomputing = false
                }
            } catch {
                DispatchQueue.main.async { errorText = "Ошибка: \(error.localizedDescription)"; isRecomputing = false }
            }
        }
    }

    private func save() {
        guard let cachedFileURL else { return }
        saveState = .saving

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { saveState = .failed }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: cachedFileURL, options: nil)
            }) { success, _ in
                DispatchQueue.main.async { saveState = success ? .saved : .failed }
            }
        }
    }
}
