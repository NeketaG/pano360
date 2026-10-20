import ARKit
import AVFoundation
import CoreLocation
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

final class CaptureSession: NSObject, ObservableObject, ARSessionDelegate, CLLocationManagerDelegate {
    let session = ARSession()
    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?

    @Published var gridPoints: [GridPoint]
    @Published var currentYaw: Float = 0
    @Published var currentPitch: Float = 0
    @Published var alignedPointID: GridPoint.ID?
    @Published var isFinished = false
    @Published var statusText = "Наведи камеру и поворачивайся по кругу"
    @Published var lastCapturedImage: UIImage?
    @Published var canUndo = false
    @Published var capturedThumbnails: [GridPoint.ID: UIImage] = [:]
    @Published var isTorchOn = false

    private let captureToleranceDeg: Float = 6
    private let stabilizeSeconds: TimeInterval = 0.4
    private var alignedSince: Date?
    private var isSaving = false
    private var frameIndex = 0

    let outputDirectory: URL
    private var manifestEntries: [[String: Any]] = []
    private var captureHistory: [CaptureHistoryEntry] = []
    private let ciContext = CIContext()

    override init() {
        var points: [GridPoint] = []

        // Горизонт — 11 точек, как в Google Camera Photo Sphere
        for i in 0..<11 {
            let yawDeg = Float(i) * 360 / 11
            points.append(GridPoint(yaw: yawDeg * .pi / 180, pitch: 0))
        }

        // Ряды выше и ниже горизонта — по 8 точек
        let midPitchesDeg: [Float] = [-45, 45]
        for pitchDeg in midPitchesDeg {
            for i in 0..<8 {
                let yawDeg = Float(i) * 45
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
        // По умолчанию ARKit может выбрать формат 16:9 — он даёт слишком вытянутые
        // кадры для панорамы, подбираем ближайший к привычному 4:3.
        if let format = AROrientationTrackingConfiguration.supportedVideoFormats.min(by: {
            abs($0.imageResolution.width / $0.imageResolution.height - 4.0 / 3.0) <
            abs($1.imageResolution.width / $1.imageResolution.height - 4.0 / 3.0)
        }) {
            config.videoFormat = format
        }
        session.run(config)

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func stop() {
        session.pause()
        locationManager.stopUpdatingLocation()
        if isTorchOn { setTorch(false) }
    }

    func toggleTorch() {
        setTorch(!isTorchOn)
    }

    private func setTorch(_ on: Bool) {
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            device.hasTorch
        else { return }
        do {
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: 1.0)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
            isTorchOn = on
        } catch {
            // не критично, если переключить вспышку не удалось
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
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
        // Сохраняем БЕЗ поворота: fx/fy/cx/cy от ARKit заданы именно для этой,
        // исходной ориентации сенсора — поворот для склейки не нужен и всё портит.
        let rawCIImage = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let rawCGImage = ciContext.createCGImage(rawCIImage, from: rawCIImage.extent) else {
            isSaving = false
            return
        }
        let intrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform
        let right = SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z)
        let up = SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z)
        let forward = -SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)

        DispatchQueue.global(qos: .userInitiated).async {
            let fileName = String(format: "frame_%03d.jpg", index)
            let fileURL = self.outputDirectory.appendingPathComponent(fileName)
            let rawImage = UIImage(cgImage: rawCGImage)
            if let data = rawImage.jpegData(compressionQuality: 0.9) {
                try? data.write(to: fileURL)
            }
            // Для миниатюры в интерфейсе поворот не влияет на файл — это просто метка отображения
            let displayImage = UIImage(cgImage: rawCGImage, scale: 1, orientation: .right)
            let thumbnail = self.makeThumbnail(displayImage, maxDimension: 160)

            let entry: [String: Any] = [
                "file": fileName,
                "yawRad": Double(point.yaw),
                "pitchRad": Double(point.pitch),
                "width": rawCGImage.width,
                "height": rawCGImage.height,
                "fx": Double(intrinsics.columns.0.x),
                "fy": Double(intrinsics.columns.1.y),
                "cx": Double(intrinsics.columns.2.x),
                "cy": Double(intrinsics.columns.2.y),
                "rightX": Double(right.x), "rightY": Double(right.y), "rightZ": Double(right.z),
                "upX": Double(up.x), "upY": Double(up.y), "upZ": Double(up.z),
                "forwardX": Double(forward.x), "forwardY": Double(forward.y), "forwardZ": Double(forward.z)
            ]

            DispatchQueue.main.async {
                self.manifestEntries.append(entry)
                if let idx = self.gridPoints.firstIndex(where: { $0.id == point.id }) {
                    self.gridPoints[idx].captured = true
                }
                self.captureHistory.append(CaptureHistoryEntry(pointID: point.id, fileName: fileName, thumbnail: thumbnail))
                self.capturedThumbnails[point.id] = thumbnail
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
        capturedThumbnails[last.pointID] = nil
        manifestEntries.removeAll { ($0["file"] as? String) == last.fileName }
        try? FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(last.fileName))
        lastCapturedImage = captureHistory.last?.thumbnail
        canUndo = !captureHistory.isEmpty
        let done = gridPoints.filter { $0.captured }.count
        statusText = "Кадр отменён. Снято \(done) из \(gridPoints.count)"
    }

    /// Сбрасывает всю съёмку: удаляет уже снятые кадры и начинает сетку точек заново.
    func resetAll() {
        guard !isSaving else { return }
        for entry in captureHistory {
            try? FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(entry.fileName))
        }
        captureHistory.removeAll()
        capturedThumbnails.removeAll()
        manifestEntries.removeAll()
        frameIndex = 0
        for idx in gridPoints.indices {
            gridPoints[idx].captured = false
        }
        lastCapturedImage = nil
        canUndo = false
        alignedSince = nil
        alignedPointID = nil
        statusText = "Наведи камеру и поворачивайся по кругу"
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

        var manifest: [String: Any] = ["frames": manifestEntries]
        if let coordinate = lastLocation?.coordinate {
            manifest["latitude"] = coordinate.latitude
            manifest["longitude"] = coordinate.longitude
        }

        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            try? data.write(to: manifestURL)
        }
        stop()
    }
}
