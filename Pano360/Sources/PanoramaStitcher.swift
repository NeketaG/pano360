import CoreGraphics
import Foundation
import ImageIO
import simd

struct FrameRecord {
    let fileURL: URL
    let yaw: Float
    let pitch: Float
    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let forward: SIMD3<Float>
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
                let cy = entry["cy"] as? Double,
                let rightX = entry["rightX"] as? Double, let rightY = entry["rightY"] as? Double, let rightZ = entry["rightZ"] as? Double,
                let upX = entry["upX"] as? Double, let upY = entry["upY"] as? Double, let upZ = entry["upZ"] as? Double,
                let forwardX = entry["forwardX"] as? Double, let forwardY = entry["forwardY"] as? Double, let forwardZ = entry["forwardZ"] as? Double
            else { return nil }
            return FrameRecord(
                fileURL: sessionDirectory.appendingPathComponent(file),
                yaw: Float(yaw), pitch: Float(pitch),
                right: SIMD3<Float>(Float(rightX), Float(rightY), Float(rightZ)),
                up: SIMD3<Float>(Float(upX), Float(upY), Float(upZ)),
                forward: SIMD3<Float>(Float(forwardX), Float(forwardY), Float(forwardZ)),
                fx: Float(fx), fy: Float(fy), cx: Float(cx), cy: Float(cy)
            )
        }
    }

    /// Склейка по данным ориентации. Каждый пиксель канваса принадлежит ровно
    /// одному, самому "центральному" для него кадру (меньше шансов на размытость
    /// от усреднения многих перекрывающихся кадров), а смешиваются только узкие
    /// полосы точно на границе между соседними кадрами. Яркость кадров выравнивается
    /// перед смешиванием, чтобы швы не были заметны из-за разной экспозиции.
    static func stitch(frames: [FrameRecord], outputSize: CGSize, progress: ((Double) -> Void)? = nil) -> CGImage? {
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        let pixelCount = width * height

        var bestColor = [SIMD3<Float>](repeating: .zero, count: pixelCount)
        var bestCentrality = [Float](repeating: -1, count: pixelCount)
        var secondColor = [SIMD3<Float>](repeating: .zero, count: pixelCount)
        var secondCentrality = [Float](repeating: -1, count: pixelCount)

        struct LoadedFrame {
            let record: FrameRecord
            let width: Int
            let height: Int
            let pixels: [UInt8]
            let luminance: Float
        }

        let loadedFrames: [LoadedFrame] = frames.compactMap { record in
            guard
                let source = CGImageSourceCreateWithURL(record.fileURL as CFURL, nil),
                let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let pixels = pixelBytes(of: cgImage)
            else { return nil }
            return LoadedFrame(
                record: record, width: cgImage.width, height: cgImage.height,
                pixels: pixels, luminance: averageLuminance(pixels)
            )
        }
        guard !loadedFrames.isEmpty else { return nil }

        let targetLuminance = loadedFrames.map(\.luminance).reduce(0, +) / Float(loadedFrames.count)

        for (index, frame) in loadedFrames.enumerated() {
            let exposureScale = frame.luminance > 1 ? min(max(targetLuminance / frame.luminance, 0.5), 2.0) : 1
            rasterize(
                record: frame.record, srcWidth: frame.width, srcHeight: frame.height,
                pixels: frame.pixels, exposureScale: exposureScale,
                bestColor: &bestColor, bestCentrality: &bestCentrality,
                secondColor: &secondColor, secondCentrality: &secondCentrality,
                canvasWidth: width, canvasHeight: height
            )
            progress?(Double(index + 1) / Double(loadedFrames.count))
        }

        let blendMargin: Float = 0.25
        var outputBytes = [UInt8](repeating: 0, count: pixelCount * 4)
        for i in 0..<pixelCount {
            let o = i * 4
            guard bestCentrality[i] >= 0 else {
                outputBytes[o + 3] = 255
                continue
            }
            var color = bestColor[i]
            if secondCentrality[i] >= 0 {
                let diff = bestCentrality[i] - secondCentrality[i]
                if diff < blendMargin {
                    let alpha = 0.5 * (1 - diff / blendMargin)
                    color = bestColor[i] * (1 - alpha) + secondColor[i] * alpha
                }
            }
            outputBytes[o]     = UInt8(clamping: Int(color.x))
            outputBytes[o + 1] = UInt8(clamping: Int(color.y))
            outputBytes[o + 2] = UInt8(clamping: Int(color.z))
            outputBytes[o + 3] = 255
        }

        return makeCGImage(from: outputBytes, width: width, height: height)
    }

    private static func rasterize(
        record: FrameRecord, srcWidth: Int, srcHeight: Int, pixels: [UInt8], exposureScale: Float,
        bestColor: inout [SIMD3<Float>], bestCentrality: inout [Float],
        secondColor: inout [SIMD3<Float>], secondCentrality: inout [Float],
        canvasWidth: Int, canvasHeight: Int
    ) {
        let halfFOVYaw = atan(Float(srcWidth) / (2 * record.fx))
        let halfFOVPitch = atan(Float(srcHeight) / (2 * record.fy))
        // запас 20%, чтобы не терять края кадра при неточной оценке границ
        let yawRange = min(halfFOVYaw * 1.2, .pi)
        let pitchRange = min(halfFOVPitch * 1.2, .pi / 2)

        let forward = record.forward
        let right = record.right
        let up = record.up

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
                let centrality = max(0, min(edgeX, edgeY))
                guard centrality > 0 else { continue }

                var color = bilinearSample(pixels, width: srcWidth, x: srcX, y: srcY) * exposureScale
                color = SIMD3<Float>(min(max(color.x, 0), 255), min(max(color.y, 0), 255), min(max(color.z, 0), 255))

                let index = v * canvasWidth + u
                if centrality > bestCentrality[index] {
                    secondCentrality[index] = bestCentrality[index]
                    secondColor[index] = bestColor[index]
                    bestCentrality[index] = centrality
                    bestColor[index] = color
                } else if centrality > secondCentrality[index] {
                    secondCentrality[index] = centrality
                    secondColor[index] = color
                }
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

    private static func averageLuminance(_ pixels: [UInt8]) -> Float {
        let totalPixels = pixels.count / 4
        guard totalPixels > 0 else { return 128 }
        let samplingStride = max(1, totalPixels / 20000)
        var sum: Float = 0
        var count = 0
        var p = 0
        while p < totalPixels {
            let i = p * 4
            sum += 0.299 * Float(pixels[i]) + 0.587 * Float(pixels[i + 1]) + 0.114 * Float(pixels[i + 2])
            count += 1
            p += samplingStride
        }
        return count > 0 ? sum / Float(count) : 128
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
