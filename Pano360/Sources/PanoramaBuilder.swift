import CoreGraphics
import Foundation
import UIKit

enum PanoramaBuilderError: LocalizedError {
    case noFrames
    case stitchFailed

    var errorDescription: String? {
        switch self {
        case .noFrames: return "В этой съёмке нет кадров."
        case .stitchFailed: return "Не получилось собрать панораму."
        }
    }
}

/// Полный путь от папки съёмки до готовой панорамы: подгонка поз → склейка → JPEG
/// с метаданными 360°. Готовый результат кэшируется в panorama.jpg рядом с кадрами.
enum PanoramaBuilder {
    struct Result {
        let image: UIImage
        let fileURL: URL
    }

    static let outputSize = CGSize(width: 8192, height: 4096)

    /// Тяжёлая синхронная работа — вызывать не из главного потока.
    static func build(sessionDirectory: URL, forceRecompute: Bool, progress: @escaping (Double) -> Void) throws -> Result {
        let cache = sessionDirectory.appendingPathComponent("panorama.jpg")
        if !forceRecompute,
           FileManager.default.fileExists(atPath: cache.path),
           let cached = UIImage(contentsOfFile: cache.path) {
            return Result(image: cached, fileURL: cache)
        }

        let manifest = try PanoramaStitcher.loadManifest(sessionDirectory: sessionDirectory)
        guard !manifest.frames.isEmpty else { throw PanoramaBuilderError.noFrames }

        let refined = PoseRefiner.refine(frames: manifest.frames)
        guard let cgImage = PanoramaStitcher.stitch(frames: refined, outputSize: outputSize, progress: progress) else {
            throw PanoramaBuilderError.stitchFailed
        }
        try PanoramaStitcher.writeEquirectangularJPEG(
            cgImage, to: cache, latitude: manifest.latitude, longitude: manifest.longitude
        )
        return Result(image: UIImage(cgImage: cgImage), fileURL: cache)
    }
}
