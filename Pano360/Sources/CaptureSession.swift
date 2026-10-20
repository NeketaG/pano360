import ARKit
import simd
import UIKit

struct GridPoint: Identifiable {
    let id = UUID()
    let yaw: Float   // радианы, 0 = направление в момент старта
    let pitch: Float // радианы, 0 = горизонт
    var captured = false
}

func angularDifference(_ a: Float, _ b: Float) -> Float {
    atan2(sin(a - b), cos(a - b))
}

final class CaptureSession: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published var gridPoints: [GridPoint]
    @Published var currentYaw: Float = 0
    @Published var currentPitch: Float = 0
    @Published var alignedPointID: GridPoint.ID?
    @Published var isFinished = false
    @Published var statusText = "Наведи камеру и поворачивайся по кругу"

    private let captureToleranceDeg: Float = 6
    private let stabilizeSeconds: TimeInterval = 0.4
    private var alignedSince: Date?
    private var isSaving = false
    private var frameIndex = 0

    private let outputDirectory: URL
    private var manifestEntries: [[String: Any]] = []
    private let ciContext = CIContext()

    override init() {
        let pitchesDeg: [Float] = [-30, 0, 30]
        let yawStepsDeg = stride(from: Float(0), to: 360, by: 45).map { $0 }
        gridPoints = pitchesDeg.flatMap { pitchDeg in
            yawStepsDeg.map { yawDeg in
                GridPoint(yaw: yawDeg * .pi / 180, pitch: pitchDeg * .pi / 180)
            }
        }

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
            !point.captured &&
            abs(angularDifference(yaw, point.yaw)) < toleranceRad &&
            abs(pitch - point.pitch) < toleranceRad
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
