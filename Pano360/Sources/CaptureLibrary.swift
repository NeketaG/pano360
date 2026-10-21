import Foundation
import UIKit

/// Сохранённая съёмка: папка с кадрами, manifest.json и (если уже склеена) panorama.jpg.
struct SavedCapture: Identifiable, Hashable {
    let id: URL
    let date: Date
    let hasPanorama: Bool

    var panoramaURL: URL { id.appendingPathComponent("panorama.jpg") }
}

enum CaptureLibrary {
    static var rootDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures")
    }

    /// Все завершённые съёмки, новые сверху. Папки без manifest.json — брошенные
    /// на середине съёмки — не показываем: склеить их нельзя.
    static func load() -> [SavedCapture] {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else { return [] }

        return directories.compactMap { dir -> SavedCapture? in
            let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true,
                  fileManager.fileExists(atPath: dir.appendingPathComponent("manifest.json").path)
            else { return nil }
            let hasPanorama = fileManager.fileExists(atPath: dir.appendingPathComponent("panorama.jpg").path)
            return SavedCapture(id: dir, date: values?.contentModificationDate ?? .distantPast, hasPanorama: hasPanorama)
        }
        .sorted { $0.date > $1.date }
    }

    static func delete(_ capture: SavedCapture) {
        try? FileManager.default.removeItem(at: capture.id)
    }

    /// Уменьшенная копия готовой панорамы (сама она 8192×4096 — целиком декодировать дорого).
    static func thumbnail(for capture: SavedCapture, maxPixelSize: Int) -> UIImage? {
        guard capture.hasPanorama else { return nil }
        return PanoramaStitcher.downsampledImage(at: capture.panoramaURL, maxPixelSize: maxPixelSize)
            .map { UIImage(cgImage: $0.image) }
    }
}
