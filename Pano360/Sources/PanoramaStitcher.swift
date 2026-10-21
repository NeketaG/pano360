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
    /// Для 12-Мп фото (captureHighResolutionFrame) ARKit сообщает фокусное расстояние
    /// примерно на 10% меньше реального — измерено на реальной съёмке по совпадениям
    /// точек между соседними кадрами (ошибка стыков падает с 3.8° до 2.7°, а вместе
    /// с подгонкой поворотов — до 0.8°). Для кадров видеопотока поправка не нужна.
    static let highResolutionFocalCorrection: Float = 1.10

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
            // Съёмки, сделанные до появления поправки, исправляем при загрузке
            // (12-Мп кадры узнаём по размеру).
            let alreadyCorrected = entry["intrinsicsCorrected"] as? Bool ?? false
            let width = entry["width"] as? Int ?? 0
            let focalScale: Float = (!alreadyCorrected && width >= 3000) ? highResolutionFocalCorrection : 1
            return FrameRecord(
                fileURL: sessionDirectory.appendingPathComponent(file),
                yaw: Float(yaw), pitch: Float(pitch),
                right: SIMD3<Float>(Float(rightX), Float(rightY), Float(rightZ)),
                up: SIMD3<Float>(Float(upX), Float(upY), Float(upZ)),
                forward: SIMD3<Float>(Float(forwardX), Float(forwardY), Float(forwardZ)),
                fx: Float(fx) * focalScale, fy: Float(fy) * focalScale, cx: Float(cx), cy: Float(cy)
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

        let gains = solveChannelGains(frames: frames)
        let canvas = Canvas(width: width, height: height)

        for (index, record) in frames.enumerated() {
            autoreleasepool {
                guard
                    let source = CGImageSourceCreateWithURL(record.fileURL as CFURL, nil),
                    let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { return }
                let gain = gains[index]
                _ = withPixelBytes(of: cgImage) { pixels, w, h in
                    rasterize(record: record, pixels: pixels, srcWidth: w, srcHeight: h, gain: gain, canvas: canvas)
                }
            }
            progress?(Double(index + 1) / Double(frames.count))
        }

        canvas.blendSeams()
        canvas.fillGaps()

        let data = Data(bytes: canvas.bestColor, count: width * height * 4)
        return makeCGImage(from: data, width: width, height: height)
    }

    /// Усиление каждого кадра по каналам R, G, B, подобранное так, чтобы одни и те же
    /// участки сцены на соседних кадрах совпадали по цвету и яркости. Экспозиция кадров
    /// у iPhone гуляет до 2.7 раза (небо против горизонта); нормализация по средней
    /// яркости кадра тут не помогает — она путает разную экспозицию с разным содержимым.
    /// На реальной съёмке такой подбор снижает разницу между соседями с ~17% до ~4%.
    private static func solveChannelGains(frames: [FrameRecord]) -> [SIMD3<Float>] {
        let n = frames.count
        let sampleCount = 20000

        // Равномерные направления по сфере (спираль Фибоначчи).
        let golden: Float = Float.pi * (3 - sqrt(5))
        var directions: [SIMD3<Float>] = []
        directions.reserveCapacity(sampleCount)
        for k in 0..<sampleCount {
            let y: Float = 1 - 2 * (Float(k) + 0.5) / Float(sampleCount)
            let r: Float = sqrt(max(0, 1 - y * y))
            let a: Float = golden * Float(k)
            directions.append(SIMD3<Float>(r * cos(a), y, r * sin(a)))
        }

        // Цвет каждого направления в каждом кадре (nil — кадр туда не смотрит или пиксель пересвечен).
        var samples: [[SIMD3<Float>?]] = []
        for record in frames {
            let empty = [SIMD3<Float>?](repeating: nil, count: sampleCount)
            guard let small = downsampledImage(at: record.fileURL, maxPixelSize: 512) else {
                samples.append(empty)
                continue
            }
            let s = small.scale
            let fx = record.fx * s, fy = record.fy * s, cx = record.cx * s, cy = record.cy * s
            let colors = withPixelBytes(of: small.image) { pixels, w, h -> [SIMD3<Float>?] in
                directions.map { d -> SIMD3<Float>? in
                    let depth = dot(d, record.forward)
                    guard depth > 0.2 else { return nil }
                    let px = fx * dot(d, record.right) / depth + cx
                    let py = cy - fy * dot(d, record.up) / depth
                    let x = Int(px), y = Int(py)
                    guard x >= 2, y >= 2, x < w - 2, y < h - 2 else { return nil }
                    var sum = SIMD3<Float>(0, 0, 0)
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let i = ((y + dy) * w + (x + dx)) * 4
                            sum += SIMD3<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                        }
                    }
                    let color = sum / 9
                    guard color.min() > 8, color.max() < 245 else { return nil }
                    return color
                }
            }
            samples.append(colors ?? empty)
        }

        // Мнк: для каждой пары соседей g_i − g_j = −log(яркость_i / яркость_j).
        // Плюс сумма g = 0 (общий уровень яркости не меняем) и слабая привязка к нулю,
        // чтобы кадр без соседей не "уплыл".
        var matrix = [[Float]](repeating: [Float](repeating: 1, count: n), count: n)
        for i in 0..<n { matrix[i][i] += 1e-3 }
        var rhs = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: n)

        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                var logR: [Float] = [], logG: [Float] = [], logB: [Float] = []
                for k in 0..<sampleCount {
                    guard let a = samples[i][k], let b = samples[j][k] else { continue }
                    logR.append(log(a.x / b.x))
                    logG.append(log(a.y / b.y))
                    logB.append(log(a.z / b.z))
                }
                guard logR.count >= 100 else { continue }
                let ratio = SIMD3<Float>(median(logR), median(logG), median(logB))
                matrix[i][i] += 1
                matrix[j][j] += 1
                matrix[i][j] -= 1
                matrix[j][i] -= 1
                rhs[i] -= ratio
                rhs[j] += ratio
            }
        }

        let logGains = solveLinear(matrix, rhs)
        return logGains.map { g in
            SIMD3<Float>(
                min(max(exp(g.x), 0.33), 3),
                min(max(exp(g.y), 0.33), 3),
                min(max(exp(g.z), 0.33), 3)
            )
        }
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Метод Гаусса для небольшой системы (по столбцу правой части на каждый канал).
    private static func solveLinear(_ a: [[Float]], _ b: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let n = b.count
        var m = a
        var r = b
        for col in 0..<n {
            var pivot = col
            for row in (col + 1)..<max(col + 1, n) where abs(m[row][col]) > abs(m[pivot][col]) {
                pivot = row
            }
            m.swapAt(col, pivot)
            r.swapAt(col, pivot)
            let p = m[col][col]
            guard abs(p) > 1e-9 else { continue }
            for row in 0..<n where row != col {
                let factor = m[row][col] / p
                guard factor != 0 else { continue }
                for k in col..<n {
                    m[row][k] -= factor * m[col][k]
                }
                r[row] -= factor * r[col]
            }
        }
        return (0..<n).map { i in abs(m[i][i]) > 1e-9 ? r[i] / m[i][i] : SIMD3<Float>(0, 0, 0) }
    }

    private static func rasterize(
        record: FrameRecord, pixels: UnsafePointer<UInt8>, srcWidth: Int, srcHeight: Int,
        gain: SIMD3<Float>, canvas: Canvas
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
        let halfDiagonal: Float = atan(sqrt(tanHalfX * tanHalfX + tanHalfY * tanHalfY))
        let radius: Float = min(halfDiagonal * 1.02, Float.pi / 2)
        let pitchTop = centerPitch + radius
        let pitchBottom = centerPitch - radius

        let width = canvas.width
        let height = canvas.height
        let halfPi = Float.pi / 2
        let topRow: Float = (0.5 - min(pitchTop, halfPi) / Float.pi) * Float(height)
        let bottomRow: Float = (0.5 - max(pitchBottom, -halfPi) / Float.pi) * Float(height)
        let vMin = max(0, Int(topRow))
        let vMax = min(height - 1, Int(bottomRow.rounded(.up)))
        guard vMin <= vMax else { return }

        var uMin = 0
        var uMax = width - 1
        if pitchTop < halfPi, pitchBottom > -halfPi {
            let ratio: Float = min(1, sin(radius) / cos(centerPitch))
            let yawHalf: Float = asin(ratio) * 1.02
            let twoPi = 2 * Float.pi
            let loColumn: Float = ((centerYaw - yawHalf) / twoPi + 0.5) * Float(width)
            let hiColumn: Float = ((centerYaw + yawHalf) / twoPi + 0.5) * Float(width)
            let lo = Int(loColumn) - 1
            let hi = Int(hiColumn) + 1
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

                let color = sample(pixels, width: srcWidth, x: srcX, y: srcY, gain: gain)
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
    private static func sample(_ pixels: UnsafePointer<UInt8>, width: Int, x: Float, y: Float, gain: SIMD3<Float>) -> UInt32 {
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

        func channel(_ c: Int, _ scale: Float) -> UInt32 {
            let top: Float = Float(pixels[i00 + c]) * w00 + Float(pixels[i10 + c]) * w10
            let bottom: Float = Float(pixels[i01 + c]) * w01 + Float(pixels[i11 + c]) * w11
            let value: Float = (top + bottom) * scale
            return UInt32(max(Float(0), min(Float(255), value)))
        }

        return channel(0, gain.x) | (channel(1, gain.y) << 8) | (channel(2, gain.z) << 16) | (255 << 24)
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
        // Узкая полоса: если соседние кадры совпали неидеально, широкое смешивание
        // даёт размытый "двойной" край, а узкое — почти незаметный стык.
        let blendMargin = 32
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
