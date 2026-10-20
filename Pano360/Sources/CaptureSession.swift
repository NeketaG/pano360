import ARKit
import simd
import UIKit

struct GridPoint: Identifiable {
    let id = UUID()
    let yaw: Float   // радианы, 0 = направление в момент старта
    let pitch: Float // радианы, 0 = горизонт
    var ignoresYaw = false // зенит/надир: азимут не важен, важен только угол вверх/вниз
    var captured = false
}

func angularDifference(_ a: Float, _ b: Float) -> Float {
    atan2(sin(a - b), cos(a - b))
}

private struct CaptureHistoryEntry {
    let pointID: GridPoint.ID
    let fileName: String
    let thumbnail: UIImage
}

final class CaptureSession: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published var gridPoints: [GridPoint]
    @Published var currentYaw: Float = 0
    @Published var currentPitch: Float = 0
    @Published var alignedPointID: GridPoint.ID?
    @Published var isFinished = false
    @Published var statusText = "Наведи камеру и поворачивайся по кругу"
    @Published var lastCapturedImage: UIImage?
    @Published var canUndo = false

    private let captureToleranceDeg: Float = 6
    private let stabilizeSeconds: TimeInterval = 0.4
    private var alignedSince: Date?
    private var isSaving = false
    private var frameIndex = 0

    private let outputDirectory: URL
    private var manifestEntries: [[String: Any]] = []
    private var captureHistory: [CaptureHistoryEntry] = []
    private let ciContext = CIContext()

    override init() {
        var points: [GridPoint] = []

        // Основные кольца: шаг по азимуту 30° (12 точек в кольце)
        let mainPitchesDeg: [Float] = [-60, -30, 0, 30, 60]
        let mainYawStepsDeg = stride(from: Float(0), to: 360, by: 30).map { $0 }
        for pitchDeg in mainPitchesDeg {
            for yawDeg in mainYawStepsDeg {
                points.append(GridPoint(yaw: yawDeg * .pi / 180, pitch: pitchDeg * .pi / 180))
            }
        }

        // Кольца ближе к полюсам: точек меньше, окружность там короче
        let polarPitchesDeg: [Float] = [-80, 80]
        let polarYawStepsDeg = stride(from: Float(0), to: 360, by: 90).map { $0 }
        for pitchDeg in polarPitchesDeg {
            for yawDeg in polarYawStepsDeg {
                points.append(GridPoint(yaw: yawDeg * .pi / 180, pitch: pitchDeg * .pi / 180))
            }
        }

        // Зенит и надир — прямо вверх и прямо вниз, азимут там не определён
        points.append(GridPoint(yaw: 0, pitch: 90 * .pi / 180, ignoresYaw: true))
        points.append(GridPoint(yaw: 0, pitch: -90 * .pi / 180, ignoresYaw: true))

        gridPoints = points

        let sessionName = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        outputDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures")
            .appendingPathComponent(sessionName)

        super.init()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    func start() {
        session.delegate = self
        let config = AROrientationTrackingConfiguration()
        session.run(config)
    }

    func stop() {
        session.pause()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let forward = forwardVector(from: frame.camera.transform)
        let yaw = atan2(forward.x, -forward.z)
        let pitch = asin(max(-1, min(1, forward.y)))

        DispatchQueue.main.async {
            self.currentYaw = yaw
            self.currentPitch = pitch
        }

        guard !isSaving, !isFinished else { return }

        if let target = nearestUncapturedPoint(toYaw: yaw, pitch: pitch) {
            DispatchQueue.main.async { self.alignedPointID = target.id }
            if let since = alignedSince {
                if Date().timeIntervalSince(since) >= stabilizeSeconds {
                    alignedSince = nil
                    capture(frame: frame, for: target)
                }
            } else {
                alignedSince = Date()
            }
        } else {
            alignedSince = nil
            DispatchQueue.main.async { self.alignedPointID = nil }
        }
    }

    private func forwardVector(from transform: simd_float4x4) -> SIMD3<Float> {
        let zAxis = SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        return -normalize(zAxis)
    }

    private func nearestUncapturedPoint(toYaw yaw: Float, pitch: Float) -> GridPoint? {
        let toleranceRad = captureToleranceDeg * .pi / 180
        return gridPoints.first { point in
            guard !point.captured else { return false }
            let pitchTolerance = point.ignoresYaw ? toleranceRad * 1.5 : toleranceRad
            guard abs(pitch - point.pitch) < pitchTolerance else { return false }
            return point.ignoresYaw || abs(angularDifference(yaw, point.yaw)) < toleranceRad
        }
    }

    private func capture(frame: ARFrame, for point: GridPoint) {
        isSaving = true
        frameIndex += 1
        let index = frameIndex

        // Рендерим картинку сразу здесь, в колбэке ARKit: буфер кадра переиспользуется
        // и становится недействительным сразу после возврата из didUpdate.
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            isSaving = false
            return
        }
        let intrinsics = frame.camera.intrinsics

        DispatchQueue.global(qos: .userInitiated).async {
            let fileName = String(format: "frame_%03d.jpg", index)
            let fileURL = self.outputDirectory.appendingPathComponent(fileName)
            let uiImage = UIImage(cgImage: cgImage)
            if let data = uiImage.jpegData(compressionQuality: 0.9) {
                try? data.write(to: fileURL)
            }
            let thumbnail = self.makeThumbnail(uiImage, maxDimension: 160)

            let entry: [String: Any] = [
                "file": fileName,
                "yawRad": Double(point.yaw),
                "pitchRad": Double(point.pitch),
                "width": cgImage.width,
                "height": cgImage.height,
                "fx": Double(intrinsics.columns.0.x),
                "fy": Double(intrinsics.columns.1.y),
                "cx": Double(intrinsics.columns.2.x),
                "cy": Double(intrinsics.columns.2.y)
            ]

            DispatchQueue.main.async {
                self.manifestEntries.append(entry)
                if let idx = self.gridPoints.firstIndex(where: { $0.id == point.id }) {
                    self.gridPoints[idx].captured = true
                }
                self.captureHistory.append(CaptureHistoryEntry(pointID: point.id, fileName: fileName, thumbnail: thumbnail))
                self.lastCapturedImage = thumbnail
                self.canUndo = true
                self.alignedPointID = nil
                self.isSaving = false
                let done = self.gridPoints.filter { $0.captured }.count
                self.statusText = "Снято \(done) из \(self.gridPoints.count)"

                if done == self.gridPoints.count {
                    self.finish()
                }
            }
        }
    }

    func undoLastCapture() {
        guard !isSaving, let last = captureHistory.popLast() else { return }
        if let idx = gridPoints.firstIndex(where: { $0.id == last.pointID }) {
            gridPoints[idx].captured = false
        }
        manifestEntries.removeAll { ($0["file"] as? String) == last.fileName }
        try? FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(last.fileName))
        lastCapturedImage = captureHistory.last?.thumbnail
        canUndo = !captureHistory.isEmpty
        let done = gridPoints.filter { $0.captured }.count
        statusText = "Кадр отменён. Снято \(done) из \(gridPoints.count)"
    }

    private func makeThumbnail(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = maxDimension / max(size.width, size.height)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func finish() {
        isFinished = true
        statusText = "Готово! Снято \(gridPoints.count) кадров"
        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        if let data = try? JSONSerialization.data(withJSONObject: manifestEntries, options: [.prettyPrinted]) {
            try? data.write(to: manifestURL)
        }
        stop()
    }
}
