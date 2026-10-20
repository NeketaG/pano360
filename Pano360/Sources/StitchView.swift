import Photos
import SwiftUI

struct StitchView: View {
    let sessionDirectory: URL
    let onClose: () -> Void

    @State private var progress: Double = 0
    @State private var resultImage: UIImage?
    @State private var errorText: String?
    @State private var saveState: SaveState = .idle

    private enum SaveState {
        case idle, saving, saved, failed
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
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: resultImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 1000)
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
                let frames = try PanoramaStitcher.loadManifest(sessionDirectory: directory)
                guard !frames.isEmpty else {
                    DispatchQueue.main.async { errorText = "В этой съёмке нет кадров." }
                    return
                }
                let cgImage = PanoramaStitcher.stitch(
                    frames: frames,
                    outputSize: CGSize(width: 2048, height: 1024)
                ) { value in
                    DispatchQueue.main.async { progress = value }
                }
                guard let cgImage else {
                    DispatchQueue.main.async { errorText = "Не получилось собрать панораму." }
                    return
                }
                let uiImage = UIImage(cgImage: cgImage)
                DispatchQueue.main.async { resultImage = uiImage }
            } catch {
                DispatchQueue.main.async { errorText = "Ошибка: \(error.localizedDescription)" }
            }
        }
    }

    private func save(_ image: UIImage) {
        saveState = .saving
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { saveState = .failed }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, _ in
                DispatchQueue.main.async { saveState = success ? .saved : .failed }
            }
        }
    }
}
