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

/// Снятый кадр для показа "на сфере" во время съёмки: уменьшенная копия в исходной
/// ориентации сенсора + точная поза камеры в момент снимка и её угол обзора.
struct CapturedPanel {
    let image: UIImage
    let cameraTransform: simd_float4x4
    let halfTanX: Float
    let halfTanY: Float
}

private struct CaptureHistoryEntry {
    let pointID: GridPoint.ID
    let fileName: String
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
    @Published var canUndo = false
    @Published var capturedPanels: [GridPoint.ID: CapturedPanel] = [:]
    @Published var isTorchOn = false

    private let captureToleranceDeg: Float = 6
    private let stabilizeSeconds: TimeInterval = 0.4
    private var alignedSince: Date?
    private var isSaving = false
    private var frameIndex = 0
    private var useHighResolution = true

    let outputDirectory: URL
    private var manifestEntries: [[String: Any]] = []
    private var captureHistory: [CaptureHistoryEntry] = []
    private let ciContext = CIContext()
    private let haptics = UIImpactFeedbackGenerator(style: .medium)

    override init() {
        var points: [GridPoint] = []

        // Горизонт — 11 точек, как в Google Camera Photo Sphere
        for i in 0..<11 {
            let yawDeg = Float(i) * 360 / 11
            points.append(GridPoint(yaw: yawDeg * .pi / 180, pitch: 0))
        }

        // Ряды выше и ниже горизонта — по 9 точек
        for pitchDeg: Float in [-45, 45] {
            for i in 0..<9 {
                let yawDeg = Float(i) * 360 / 9
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
        let config = ARWorldTrackingConfiguration()
        if let format = Self.preferredVideoFormat() {
            config.videoFormat = format
        }
        session.run(config)

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    /// Формат 4:3 (16:9 даёт слишком вытянутые кадры), по возможности тот,
    /// что поддерживает снимки в полном разрешении сенсора.
    private static func preferredVideoFormat() -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        func aspectError(_ format: ARConfiguration.VideoFormat) -> CGFloat {
            abs(format.imageResolution.width / format.imageResolution.height - 4.0 / 3.0)
        }
        let fourByThree = formats.filter { aspectError($0) < 0.05 }
        if let format = fourByThree.first(where: { $0.isRecommendedForHighResolutionFrameCapturing }) {
            return format
        }
        if let format = fourByThree.max(by: { $0.imageResolution.width < $1.imageResolution.width }) {
            return format
        }
        return formats.min(by: { aspectError($0) < aspectError($1) })
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
                    beginCapture(currentFrame: frame, for: target)
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

    /// Пытаемся снять полноразмерное фото с сенсора (у видеопотока ARKit всего ~2 Мп).
    /// Если устройство/формат этого не умеет — переходим на обычные кадры видеопотока.
    private func beginCapture(currentFrame: ARFrame, for point: GridPoint) {
        isSaving = true
        guard useHighResolution else {
            process(frame: currentFrame, for: point)
            return
        }
        session.captureHighResolutionFrame(completion: { [weak self] highResFrame, _ in
            guard let self else { return }
            if let highResFrame {
                self.process(frame: highResFrame, for: point)
            } else {
                self.useHighResolution = false
                self.isSaving = false
            }
        })
    }

    private func process(frame: ARFrame, for point: GridPoint) {
        frameIndex += 1
        let index = frameIndex
        DispatchQueue.main.async {
            self.haptics.impactOccurred()
        }

        // Рендерим картинку сразу: буфер кадра ARKit переиспользуется и после
        // возврата из колбэка может быть перезаписан. Сохраняем БЕЗ поворота —
        // параметры камеры заданы именно для исходной ориентации сенсора.
        let rawCIImage = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let rawCGImage = ciContext.createCGImage(rawCIImage, from: rawCIImage.extent) else {
            isSaving = false
            return
        }

        // Параметры камеры заданы относительно camera.imageResolution; если реальный
        // снимок другого размера (фото в полном разрешении) — пересчитываем их.
        let intrinsics = frame.camera.intrinsics
        let resolutionScale = Float(rawCGImage.width) / Float(frame.camera.imageResolution.width)
        let fx = intrinsics.columns.0.x * resolutionScale
        let fy = intrinsics.columns.1.y * resolutionScale
        let cx = intrinsics.columns.2.x * resolutionScale
        let cy = intrinsics.columns.2.y * resolutionScale

        let cameraTransform = frame.camera.transform
        let right = SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z)
        let up = SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z)
        let forward = -SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        let yaw = atan2(forward.x, -forward.z)
        let pitch = asin(max(-1, min(1, forward.y)))
        let halfTanX = Float(rawCGImage.width) / (2 * fx)
        let halfTanY = Float(rawCGImage.height) / (2 * fy)

        DispatchQueue.global(qos: .userInitiated).async {
            let fileName = String(format: "frame_%03d.jpg", index)
            let fileURL = self.outputDirectory.appendingPathComponent(fileName)
            let rawImage = UIImage(cgImage: rawCGImage)
            if let data = rawImage.jpegData(compressionQuality: 0.92) {
                try? data.write(to: fileURL)
            }
            let preview = self.makeThumbnail(rawImage, maxDimension: 640)
            let panel = CapturedPanel(image: preview, cameraTransform: cameraTransform, halfTanX: halfTanX, halfTanY: halfTanY)

            let entry: [String: Any] = [
                "file": fileName,
                "yawRad": Double(yaw),
                "pitchRad": Double(pitch),
                "width": rawCGImage.width,
                "height": rawCGImage.height,
                "fx": Double(fx),
                "fy": Double(fy),
                "cx": Double(cx),
                "cy": Double(cy),
                "rightX": Double(right.x), "rightY": Double(right.y), "rightZ": Double(right.z),
                "upX": Double(up.x), "upY": Double(up.y), "upZ": Double(up.z),
                "forwardX": Double(forward.x), "forwardY": Double(forward.y), "forwardZ": Double(forward.z)
            ]

            DispatchQueue.main.async {
                self.manifestEntries.append(entry)
                if let idx = self.gridPoints.firstIndex(where: { $0.id == point.id }) {
                    self.gridPoints[idx].captured = true
                }
                self.captureHistory.append(CaptureHistoryEntry(pointID: point.id, fileName: fileName))
                self.capturedPanels[point.id] = panel
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
        capturedPanels[last.pointID] = nil
        manifestEntries.removeAll { ($0["file"] as? String) == last.fileName }
        try? FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(last.fileName))
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
        capturedPanels.removeAll()
        manifestEntries.removeAll()
        frameIndex = 0
        for idx in gridPoints.indices {
            gridPoints[idx].captured = false
        }
        canUndo = false
        alignedSince = nil
        alignedPointID = nil
        statusText = "Наведи камеру и поворачивайся по кругу"
    }

    private func makeThumbnail(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = maxDimension / max(size.width, size.height)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // иначе на экране 3x получится картинка в 9 раз тяжелее
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
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
