import CoreGraphics
import Foundation
import ImageIO
import simd

struct FrameRecord {
    let fileURL: URL
    let yaw: Float
    let pitch: Float
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
}

enum PanoramaStitcher {
    static func loadManifest(sessionDirectory: URL) throws -> [FrameRecord] {
        let manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "PanoramaStitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Повреждён manifest.json"])
        }
        return entries.compactMap { entry in
            guard
                let file = entry["file"] as? String,
                let yaw = entry["yawRad"] as? Double,
                let pitch = entry["pitchRad"] as? Double,
                let fx = entry["fx"] as? Double,
                let fy = entry["fy"] as? Double,
                let cx = entry["cx"] as? Double,
                let cy = entry["cy"] as? Double
            else { return nil }
            return FrameRecord(
                fileURL: sessionDirectory.appendingPathComponent(file),
                yaw: Float(yaw), pitch: Float(pitch),
                fx: Float(fx), fy: Float(fy), cx: Float(cx), cy: Float(cy)
            )
        }
    }

    /// Грубая склейка по данным ориентации: без выравнивания по общим точкам
    /// и без многополосного смешивания — это следующий шаг. Здесь только
    /// кладём каждый кадр в сферу согласно его yaw/pitch и мягко размываем края.
    static func stitch(frames: [FrameRecord], outputSize: CGSize, progress: ((Double) -> Void)? = nil) -> CGImage? {
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        var colorSum = [SIMD3<Float>](repeating: .zero, count: width * height)
        var weightSum = [Float](repeating: 0, count: width * height)

        for (index, record) in frames.enumerated() {
            if
                let source = CGImageSourceCreateWithURL(record.fileURL as CFURL, nil),
                let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let pixels = pixelBytes(of: cgImage)
            {
                rasterize(
                    record: record, srcWidth: cgImage.width, srcHeight: cgImage.height, pixels: pixels,
                    into: &colorSum, weightSum: &weightSum,
                    canvasWidth: width, canvasHeight: height
                )
            }
            progress?(Double(index + 1) / Double(frames.count))
        }

        var outputBytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let w = weightSum[i]
            let o = i * 4
            if w > 0 {
                outputBytes[o]     = UInt8(clamping: Int(colorSum[i].x / w))
                outputBytes[o + 1] = UInt8(clamping: Int(colorSum[i].y / w))
                outputBytes[o + 2] = UInt8(clamping: Int(colorSum[i].z / w))
            }
            outputBytes[o + 3] = 255
        }

        return makeCGImage(from: outputBytes, width: width, height: height)
    }

    private static func rasterize(
        record: FrameRecord, srcWidth: Int, srcHeight: Int, pixels: [UInt8],
        into colorSum: inout [SIMD3<Float>], weightSum: inout [Float],
        canvasWidth: Int, canvasHeight: Int
    ) {
        let halfFOVYaw = atan(Float(srcWidth) / (2 * record.fx))
        let halfFOVPitch = atan(Float(srcHeight) / (2 * record.fy))
        // запас 20%, чтобы не терять края кадра при неточной оценке границ
        let yawRange = min(halfFOVYaw * 1.2, .pi)
        let pitchRange = min(halfFOVPitch * 1.2, .pi / 2)

        let forward = forwardVector(yaw: record.yaw, pitch: record.pitch)
        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = cross(forward, worldUp)
        if length(right) < 1e-4 {
            right = SIMD3<Float>(1, 0, 0)
        }
        right = normalize(right)
        let up = cross(right, forward)

        let uMin = Int((((record.yaw - yawRange) / (2 * .pi)) + 0.5) * Float(canvasWidth))
        let uMax = Int((((record.yaw + yawRange) / (2 * .pi)) + 0.5) * Float(canvasWidth))
        let vMin = max(0, Int((0.5 - (record.pitch + pitchRange) / .pi) * Float(canvasHeight)))
        let vMax = min(canvasHeight - 1, Int((0.5 - (record.pitch - pitchRange) / .pi) * Float(canvasHeight)))

        guard vMin <= vMax, uMin <= uMax else { return }

        let tanHalfYaw = Float(srcWidth) / (2 * record.fx)
        let tanHalfPitch = Float(srcHeight) / (2 * record.fy)

        for v in vMin...vMax {
            let phi = (0.5 - Float(v) / Float(canvasHeight)) * .pi
            for uRaw in uMin...uMax {
                let u = ((uRaw % canvasWidth) + canvasWidth) % canvasWidth
                let theta = (Float(u) / Float(canvasWidth) - 0.5) * 2 * .pi

                let direction = SIMD3<Float>(
                    cos(phi) * sin(theta),
                    sin(phi),
                    -cos(phi) * cos(theta)
                )

                let rayX = dot(direction, right)
                let rayY = dot(direction, up)
                let rayZ = -dot(direction, forward)
                guard rayZ < -1e-4 else { continue }
                let depth = -rayZ

                let ndcX = rayX / depth
                let ndcY = rayY / depth

                let srcX = record.fx * ndcX + record.cx
                let srcY = record.cy - record.fy * ndcY
                guard srcX >= 0, srcX < Float(srcWidth - 1), srcY >= 0, srcY < Float(srcHeight - 1) else { continue }

                let edgeX = 1 - abs(ndcX) / tanHalfYaw
                let edgeY = 1 - abs(ndcY) / tanHalfPitch
                let weight = max(0, min(edgeX, edgeY))
                guard weight > 0 else { continue }

                let color = bilinearSample(pixels, width: srcWidth, x: srcX, y: srcY)
                let index = v * canvasWidth + u
                colorSum[index] += color * weight
                weightSum[index] += weight
            }
        }
    }

    private static func pixelBytes(of cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        let bufferSize = width * height * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: bufferSize)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: buffer, count: bufferSize))
    }

    private static func bilinearSample(_ pixels: [UInt8], width: Int, x: Float, y: Float) -> SIMD3<Float> {
        let x0 = Int(x), y0 = Int(y)
        let x1 = x0 + 1, y1 = y0 + 1
        let fracX = x - Float(x0), fracY = y - Float(y0)

        func at(_ px: Int, _ py: Int) -> SIMD3<Float> {
            let i = (py * width + px) * 4
            return SIMD3<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
        }

        let top = at(x0, y0) * (1 - fracX) + at(x1, y0) * fracX
        let bottom = at(x0, y1) * (1 - fracX) + at(x1, y1) * fracX
        return top * (1 - fracY) + bottom * fracY
    }

    private static func forwardVector(yaw: Float, pitch: Float) -> SIMD3<Float> {
        SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), -cos(pitch) * cos(yaw))
    }

    private static func makeCGImage(from bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
