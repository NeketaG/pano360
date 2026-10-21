import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

struct FrameRecord {
    let fileURL: URL
    let yaw: Float
    let pitch: Float
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var forward: SIMD3<Float>
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
}

struct PanoramaManifest {
    let frames: [FrameRecord]
    let latitude: Double?
    let longitude: Double?
}

enum PanoramaStitcher {
    static func loadManifest(sessionDirectory: URL) throws -> PanoramaManifest {
        let manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["frames"] as? [[String: Any]]
        else {
            throw NSError(domain: "PanoramaStitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Повреждён manifest.json"])
        }
        let frames: [FrameRecord] = entries.compactMap { entry in
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
        return PanoramaManifest(frames: frames, latitude: root["latitude"] as? Double, longitude: root["longitude"] as? Double)
    }

    /// Сохраняет готовую панораму как JPEG с метаданными Google Photo Sphere (XMP GPano),
    /// чтобы просмотрщики вроде Google Фото распознавали её как интерактивную панораму,
    /// и с GPS-координатами съёмки, если они известны.
    static func writeEquirectangularJPEG(_ cgImage: CGImage, to url: URL, latitude: Double?, longitude: Double?) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "PanoramaStitcher", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать файл"])
        }

        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ]
        if let latitude, let longitude {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSVersion: "2.2.0.0",
                kCGImagePropertyGPSLatitude: abs(latitude),
                kCGImagePropertyGPSLatitudeRef: latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(longitude),
                kCGImagePropertyGPSLongitudeRef: longitude >= 0 ? "E" : "W"
            ] as [CFString: Any]
        }

        let metadata = CGImageMetadataCreateMutable()
        let gpanoNamespace = "http://ns.google.com/photos/1.0/panorama/" as CFString
        CGImageMetadataRegisterNamespaceForPrefix(metadata, gpanoNamespace, "GPano" as CFString, nil)

        func setGPano(_ name: String, _ value: String) {
            guard let tag = CGImageMetadataTagCreate(gpanoNamespace, "GPano" as CFString, name as CFString, .default, value as CFTypeRef) else { return }
            CGImageMetadataSetTagWithPath(metadata, nil, "GPano:\(name)" as CFString, tag)
        }

        setGPano("UsePanoramaViewer", "True")
        setGPano("ProjectionType", "equirectangular")
        setGPano("FullPanoWidthPixels", "\(cgImage.width)")
        setGPano("FullPanoHeightPixels", "\(cgImage.height)")
        setGPano("CroppedAreaImageWidthPixels", "\(cgImage.width)")
        setGPano("CroppedAreaImageHeightPixels", "\(cgImage.height)")
        setGPano("CroppedAreaLeftPixels", "0")
        setGPano("CroppedAreaTopPixels", "0")

        CGImageDestinationAddImageAndMetadata(destination, cgImage, metadata, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PanoramaStitcher", code: 4, userInfo: [NSLocalizedDescriptionKey: "Не удалось сохранить файл"])
        }
    }

    /// Уменьшенная копия снимка без полного декодирования + во сколько раз она меньше оригинала.
    static func downsampledImage(at url: URL, maxPixelSize: Int) -> (image: CGImage, scale: Float)? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let fullWidth = properties[kCGImagePropertyPixelWidth] as? Int, fullWidth > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (thumbnail, Float(thumbnail.width) / Float(fullWidth))
    }

    /// Склейка по ориентации кадров. Каждый пиксель итоговой панорамы берётся из
    /// самого "центрального" для него кадра, смешиваются только узкие полосы на
    /// границах между соседями. Яркость кадров выравнивается перед смешиванием.
    ///
    /// Буферы компактные (цвет — 4 байта, "центральность" — 1 байт), чтобы панорама
    /// 8192×4096 помещалась в память телефона, а строки считаются параллельно.
    static func stitch(frames: [FrameRecord], outputSize: CGSize, progress: ((Double) -> Void)? = nil) -> CGImage? {
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        guard width > 0, height > 0, !frames.isEmpty else { return nil }

        // Яркость меряем по уменьшенным копиям — быстро и без лишней памяти.
        let luminances: [Float] = frames.map { record in
            guard let small = downsampledImage(at: record.fileURL, maxPixelSize: 256)?.image else { return 0 }
            return withPixelBytes(of: small) { pixels, w, h in
                averageLuminance(pixels, pixelCount: w * h)
            } ?? 0
        }
        let measured = luminances.filter { $0 > 1 }
        let targetLuminance = measured.isEmpty ? 128 : measured.reduce(0, +) / Float(measured.count)

        let canvas = Canvas(width: width, height: height)

        for (index, record) in frames.enumerated() {
            autoreleasepool {
                guard
                    let source = CGImageSourceCreateWithURL(record.fileURL as CFURL, nil),
                    let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { return }
                let luminance = luminances[index]
                let exposureScale = luminance > 1 ? min(max(targetLuminance / luminance, 0.5), 2.0) : 1
                _ = withPixelBytes(of: cgImage) { pixels, w, h in
                    rasterize(record: record, pixels: pixels, srcWidth: w, srcHeight: h, exposureScale: exposureScale, canvas: canvas)
                }
            }
            progress?(Double(index + 1) / Double(frames.count))
        }

        canvas.blendSeams()
        canvas.fillGaps()

        let data = Data(bytes: canvas.bestColor, count: width * height * 4)
        return makeCGImage(from: data, width: width, height: height)
    }

    private static func rasterize(
        record: FrameRecord, pixels: UnsafePointer<UInt8>, srcWidth: Int, srcHeight: Int,
        exposureScale: Float, canvas: Canvas
    ) {
        let tanHalfX = Float(srcWidth) / (2 * record.fx)
        let tanHalfY = Float(srcHeight) / (2 * record.fy)
        let forward = record.forward
        let right = record.right
        let up = record.up

        // Кадр — это "пятно" на сфере вокруг направления съёмки радиусом до угла кадра
        // (половина диагонали). Пятно у полюса захватывает все долготы, у горизонта —
        // узкую полосу. Раньше область считалась без этого и края кадров у полюсов обрезались.
        let centerYaw = atan2(forward.x, -forward.z)
        let centerPitch = asin(max(-1, min(1, forward.y)))
        let radius = min(atan(sqrt(tanHalfX * tanHalfX + tanHalfY * tanHalfY)) * 1.02, .pi / 2)
        let pitchTop = centerPitch + radius
        let pitchBottom = centerPitch - radius

        let width = canvas.width
        let height = canvas.height
        let vMin = max(0, Int((0.5 - min(pitchTop, .pi / 2) / .pi) * Float(height)))
        let vMax = min(height - 1, Int(((0.5 - max(pitchBottom, -.pi / 2) / .pi) * Float(height)).rounded(.up)))
        guard vMin <= vMax else { return }

        var uMin = 0
        var uMax = width - 1
        if pitchTop < .pi / 2, pitchBottom > -.pi / 2 {
            let yawHalf = asin(min(1, sin(radius) / cos(centerPitch))) * 1.02
            let lo = Int((((centerYaw - yawHalf) / (2 * .pi)) + 0.5) * Float(width)) - 1
            let hi = Int((((centerYaw + yawHalf) / (2 * .pi)) + 0.5) * Float(width)) + 1
            if hi - lo < width {
                uMin = lo
                uMax = hi
            }
        }

        let maxX = Float(srcWidth - 1)
        let maxY = Float(srcHeight - 1)

        DispatchQueue.concurrentPerform(iterations: vMax - vMin + 1) { row in
            let v = vMin + row
            let cosPhi = canvas.cosPhi[v]
            let sinPhi = canvas.sinPhi[v]
            let rowBase = v * width

            for uRaw in uMin...uMax {
                var u = uRaw % width
                if u < 0 { u += width }

                let dx = cosPhi * canvas.sinTheta[u]
                let dy = sinPhi
                let dz = -cosPhi * canvas.cosTheta[u]

                let depth = dx * forward.x + dy * forward.y + dz * forward.z
                if depth <= 1e-4 { continue }

                let ndcX = (dx * right.x + dy * right.y + dz * right.z) / depth
                let ndcY = (dx * up.x + dy * up.y + dz * up.z) / depth
                let edge = min(1 - abs(ndcX) / tanHalfX, 1 - abs(ndcY) / tanHalfY)
                if edge <= 0 { continue }

                let srcX = record.fx * ndcX + record.cx
                let srcY = record.cy - record.fy * ndcY
                if srcX < 0 || srcX >= maxX || srcY < 0 || srcY >= maxY { continue }

                let rank = UInt8(max(1, min(255, Int(edge * 255))))
                let index = rowBase + u
                if rank <= canvas.secondRank[index] { continue }

                let color = sample(pixels, width: srcWidth, x: srcX, y: srcY, scale: exposureScale)
                if rank > canvas.bestRank[index] {
                    canvas.secondRank[index] = canvas.bestRank[index]
                    canvas.secondColor[index] = canvas.bestColor[index]
                    canvas.bestRank[index] = rank
                    canvas.bestColor[index] = color
                } else {
                    canvas.secondRank[index] = rank
                    canvas.secondColor[index] = color
                }
            }
        }
    }

    /// Билинейная выборка из RGBA-буфера с поправкой яркости, результат упакован в RGBA (UInt32).
    @inline(__always)
    private static func sample(_ pixels: UnsafePointer<UInt8>, width: Int, x: Float, y: Float, scale: Float) -> UInt32 {
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Float(x0), fy = y - Float(y0)
        let i00 = (y0 * width + x0) * 4
        let i10 = i00 + 4
        let i01 = i00 + width * 4
        let i11 = i01 + 4

        let w00 = (1 - fx) * (1 - fy)
        let w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy
        let w11 = fx * fy

        func channel(_ c: Int) -> UInt32 {
            let value = (Float(pixels[i00 + c]) * w00 + Float(pixels[i10 + c]) * w10
                + Float(pixels[i01 + c]) * w01 + Float(pixels[i11 + c]) * w11) * scale
            return UInt32(max(0, min(255, value)))
        }

        return channel(0) | (channel(1) << 8) | (channel(2) << 16) | (255 << 24)
    }

    /// Отрисовывает картинку в RGBA-буфер и даёт к нему доступ на время `body`.
    private static func withPixelBytes<T>(of cgImage: CGImage, _ body: (UnsafePointer<UInt8>, Int, Int) -> T) -> T? {
        let width = cgImage.width
        let height = cgImage.height
        let byteCount = width * height * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: byteCount)

        guard let context = CGContext(
            data: buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return body(UnsafePointer(buffer), width, height)
    }

    private static func averageLuminance(_ pixels: UnsafePointer<UInt8>, pixelCount: Int) -> Float {
        guard pixelCount > 0 else { return 128 }
        var sum: Float = 0
        for p in 0..<pixelCount {
            let i = p * 4
            sum += 0.299 * Float(pixels[i]) + 0.587 * Float(pixels[i + 1]) + 0.114 * Float(pixels[i + 2])
        }
        return sum / Float(pixelCount)
    }

    private static func makeCGImage(from data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Рабочие буферы итоговой панорамы. Для каждого пикселя храним два лучших
/// кандидата (цвет + насколько близко пиксель к центру своего кадра, 0 = не покрыт).
private final class Canvas {
    let width: Int
    let height: Int
    let bestColor: UnsafeMutablePointer<UInt32>
    let secondColor: UnsafeMutablePointer<UInt32>
    let bestRank: UnsafeMutablePointer<UInt8>
    let secondRank: UnsafeMutablePointer<UInt8>
    let sinTheta: UnsafeMutablePointer<Float>
    let cosTheta: UnsafeMutablePointer<Float>
    let sinPhi: UnsafeMutablePointer<Float>
    let cosPhi: UnsafeMutablePointer<Float>

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let count = width * height

        bestColor = .allocate(capacity: count)
        bestColor.initialize(repeating: 0xFF00_0000, count: count)
        secondColor = .allocate(capacity: count)
        secondColor.initialize(repeating: 0xFF00_0000, count: count)
        bestRank = .allocate(capacity: count)
        bestRank.initialize(repeating: 0, count: count)
        secondRank = .allocate(capacity: count)
        secondRank.initialize(repeating: 0, count: count)

        // Тригонометрия по столбцам/строкам одна на все кадры.
        sinTheta = .allocate(capacity: width)
        cosTheta = .allocate(capacity: width)
        for u in 0..<width {
            let theta = (Float(u) / Float(width) - 0.5) * 2 * .pi
            (sinTheta + u).initialize(to: sin(theta))
            (cosTheta + u).initialize(to: cos(theta))
        }
        sinPhi = .allocate(capacity: height)
        cosPhi = .allocate(capacity: height)
        for v in 0..<height {
            let phi = (0.5 - Float(v) / Float(height)) * .pi
            (sinPhi + v).initialize(to: sin(phi))
            (cosPhi + v).initialize(to: cos(phi))
        }
    }

    deinit {
        bestColor.deallocate()
        secondColor.deallocate()
        bestRank.deallocate()
        secondRank.deallocate()
        sinTheta.deallocate()
        cosTheta.deallocate()
        sinPhi.deallocate()
        cosPhi.deallocate()
    }

    /// Там, где два кадра почти одинаково "центральны", плавно смешиваем их,
    /// чтобы на стыке не было резкого перехода.
    func blendSeams() {
        let blendMargin = 64 // ≈ четверть шкалы 0…255
        DispatchQueue.concurrentPerform(iterations: height) { v in
            let rowBase = v * width
            for i in rowBase..<(rowBase + width) {
                let best = Int(bestRank[i])
                let second = Int(secondRank[i])
                guard best > 0, second > 0 else { continue }
                let diff = best - second
                guard diff < blendMargin else { continue }
                let alpha = 0.5 * (1 - Float(diff) / Float(blendMargin))
                bestColor[i] = Self.mix(bestColor[i], secondColor[i], alpha)
            }
        }
    }

    /// Пиксели, куда не дотянулся ни один кадр, затягиваем цветом соседей.
    func fillGaps() {
        for _ in 0..<12 {
            var changed = false
            for y in 0..<height {
                let rowBase = y * width
                for x in 0..<width {
                    let i = rowBase + x
                    guard bestRank[i] == 0 else { continue }
                    let left = rowBase + (x == 0 ? width - 1 : x - 1)
                    let right = rowBase + (x == width - 1 ? 0 : x + 1)
                    var donor = -1
                    if bestRank[left] > 0 { donor = left }
                    else if bestRank[right] > 0 { donor = right }
                    else if y > 0, bestRank[i - width] > 0 { donor = i - width }
                    else if y < height - 1, bestRank[i + width] > 0 { donor = i + width }
                    if donor >= 0 {
                        bestColor[i] = bestColor[donor]
                        bestRank[i] = 1
                        changed = true
                    }
                }
            }
            if !changed { break }
        }
    }

    private static func mix(_ a: UInt32, _ b: UInt32, _ t: Float) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let ca = Float((a >> shift) & 0xFF)
            let cb = Float((b >> shift) & 0xFF)
            return UInt32(ca * (1 - t) + cb * t) << shift
        }
        return channel(0) | channel(8) | channel(16) | (255 << 24)
    }
}
