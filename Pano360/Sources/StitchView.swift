import Photos
import SwiftUI

struct StitchView: View {
    let sessionDirectory: URL
    let onClose: () -> Void

    @State private var progress: Double = 0
    @State private var resultImage: UIImage?
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var errorText: String?
    @State private var saveState: SaveState = .idle
    @State private var viewMode: ViewMode = .sphere

    private enum SaveState {
        case idle, saving, saved, failed
    }

    private enum ViewMode: String, CaseIterable {
        case sphere = "Сфера"
        case flat = "Плоско"
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
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
                    save(resultImage)
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
        .onAppear { runStitch() }
    }

    private var saveButtonTitle: String {
        switch saveState {
        case .idle: return "Сохранить в Фото"
        case .saving: return "Сохраняю…"
        case .saved: return "Сохранено в Фото"
        case .failed: return "Не получилось. Повторить"
        }
    }

    private func runStitch() {
        let directory = sessionDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let manifest = try PanoramaStitcher.loadManifest(sessionDirectory: directory)
                guard !manifest.frames.isEmpty else {
                    DispatchQueue.main.async { errorText = "В этой съёмке нет кадров." }
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
                    DispatchQueue.main.async { errorText = "Не получилось собрать панораму." }
                    return
                }
                let uiImage = UIImage(cgImage: cgImage)
                DispatchQueue.main.async {
                    resultImage = uiImage
                    latitude = manifest.latitude
                    longitude = manifest.longitude
                }
            } catch {
                DispatchQueue.main.async { errorText = "Ошибка: \(error.localizedDescription)" }
            }
        }
    }

    private func save(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        saveState = .saving

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try PanoramaStitcher.writeEquirectangularJPEG(cgImage, to: tempURL, latitude: latitude, longitude: longitude)
        } catch {
            saveState = .failed
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { saveState = .failed }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: tempURL, options: nil)
            }) { success, _ in
                try? FileManager.default.removeItem(at: tempURL)
                DispatchQueue.main.async { saveState = success ? .saved : .failed }
            }
        }
    }
}
