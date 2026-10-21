import CoreGraphics
import Foundation
import simd

/// Подгонка поворотов кадров по их содержимому. ARKit ошибается в позе кадра в среднем
/// на 2.5°, и на стыках предметы двоятся. Проверено на реальных съёмках (прототип на ПК,
/// тот же алгоритм): ошибка совпадения точек 2.5° → 0.66° и 2.7° → 1.4°.
///
/// 1. Для каждой пары соседних кадров оба перепроецируются в общий вид, направленный
///    между ними. Позы ARKit почти верны, поэтому в этом виде кадры отличаются только
///    небольшим сдвигом.
/// 2. Сдвиг ищется для сетки блоков нормированной корреляцией (NCC) от грубого
///    масштаба к точному — получаются пары направлений "одна и та же точка сцены".
/// 3. Методом Гаусса–Ньютона подбирается небольшой поворот каждого кадра, при котором
///    эти пары совпадают, со слабой привязкой к исходным позам ARKit.
///
/// Если совпадение после подгонки не стало заметно лучше — возвращает исходные позы.
enum PoseRefiner {
    private static let viewSize = 384
    private static let viewHalfFOV: Float = 30 * .pi / 180
    private static let maxImageSide = 1024

    static func refine(frames: [FrameRecord]) -> [FrameRecord] {
        let n = frames.count
        guard n >= 2 else { return frames }

        let images: [GrayImage?] = frames.map { loadGray($0) }

        let cosLimit = cos(55 * Float.pi / 180)
        var pairs: [(Int, Int)] = []
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) where dot(frames[i].forward, frames[j].forward) > cosLimit {
                pairs.append((i, j))
            }
        }

        var matched = [[Correspondence]](repeating: [], count: pairs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pairs.count) { p in
            let (i, j) = pairs[p]
            guard let a = images[i], let b = images[j] else { return }
            let result = matchPair(a, b, i: i, j: j)
            lock.lock()
            matched[p] = result
            lock.unlock()
        }
        let correspondences = matched.flatMap { $0 }
        guard correspondences.count >= 30 else { return frames }

        guard let rotations = solveRotations(correspondences, frameCount: n) else { return frames }

        return frames.enumerated().map { k, record in
            var corrected = record
            corrected.right = normalize(rotations[k] * record.right)
            corrected.up = normalize(rotations[k] * record.up)
            corrected.forward = normalize(rotations[k] * record.forward)
            return corrected
        }
    }

    // MARK: - Изображения

    private struct GrayImage {
        let pixels: [Float]
        let width: Int
        let height: Int
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        let forward: SIMD3<Float>
    }

    private struct Correspondence {
        let i: Int
        let j: Int
        let dirA: SIMD3<Float>
        let dirB: SIMD3<Float>
    }

    private struct ViewBasis {
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        let forward: SIMD3<Float>
    }

    private static func loadGray(_ record: FrameRecord) -> GrayImage? {
        guard let small = PanoramaStitcher.downsampledImage(at: record.fileURL, maxPixelSize: maxImageSide) else { return nil }
        let image = small.image
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let s = small.scale
        return GrayImage(
            pixels: bytes.map { Float($0) }, width: width, height: height,
            fx: record.fx * s, fy: record.fy * s, cx: record.cx * s, cy: record.cy * s,
            right: record.right, up: record.up, forward: record.forward
        )
    }

    private static func viewBasis(_ m: SIMD3<Float>) -> ViewBasis {
        let helper = abs(m.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let right = normalize(cross(m, helper))
        let up = cross(right, m)
        return ViewBasis(right: right, up: up, forward: m)
    }

    private static func viewDirection(_ basis: ViewBasis, _ px: Float, _ py: Float) -> SIMD3<Float> {
        let c = Float(viewSize) / 2
        let f = c / tan(viewHalfFOV)
        let x = (px - c) / f
        let y = (c - py) / f
        return normalize(x * basis.right + y * basis.up + basis.forward)
    }

    /// Кадр в общем виде пары (то, что он видит в этих направлениях) + где данные есть.
    private static func render(_ image: GrayImage, _ basis: ViewBasis) -> (pixels: [Float], valid: [Bool]) {
        let size = viewSize
        var out = [Float](repeating: 0, count: size * size)
        var valid = [Bool](repeating: false, count: size * size)
        let maxX = Float(image.width - 2)
        let maxY = Float(image.height - 2)
        for py in 0..<size {
            for px in 0..<size {
                let d = viewDirection(basis, Float(px) + 0.5, Float(py) + 0.5)
                let depth = dot(d, image.forward)
                guard depth > 0.1 else { continue }
                let x = dot(d, image.right) / depth
                let y = dot(d, image.up) / depth
                let srcX = image.fx * x + image.cx
                let srcY = image.cy - image.fy * y
                guard srcX >= 1, srcX < maxX, srcY >= 1, srcY < maxY else { continue }
                let x0 = Int(srcX), y0 = Int(srcY)
                let tx = srcX - Float(x0), ty = srcY - Float(y0)
                let i = y0 * image.width + x0
                let top: Float = image.pixels[i] * (1 - tx) + image.pixels[i + 1] * tx
                let bottom: Float = image.pixels[i + image.width] * (1 - tx) + image.pixels[i + image.width + 1] * tx
                out[py * size + px] = top * (1 - ty) + bottom * ty
                valid[py * size + px] = true
            }
        }
        return (out, valid)
    }

    private static func downsample(_ src: [Float], size: Int) -> [Float] {
        let half = size / 2
        var out = [Float](repeating: 0, count: half * half)
        for y in 0..<half {
            for x in 0..<half {
                let i = (2 * y) * size + 2 * x
                out[y * half + x] = (src[i] + src[i + 1] + src[i + size] + src[i + size + 1]) / 4
            }
        }
        return out
    }

    // MARK: - Поиск сдвига

    private struct SearchResult {
        let dx: Int
        let dy: Int
        let score: Float
        let scores: [Float] // (2·radius+1)², строка за строкой, относительно guess
    }

    /// Лучший сдвиг блока A (центр cx, cy) в B в окне ±radius вокруг guess — по NCC.
    private static func search(
        _ a: [Float], _ b: [Float], size: Int, cx: Int, cy: Int,
        half: Int, guessX: Int, guessY: Int, radius: Int
    ) -> SearchResult? {
        guard cx - half >= 0, cy - half >= 0, cx + half < size, cy + half < size else { return nil }
        guard
            cx + guessX - radius - half >= 0, cy + guessY - radius - half >= 0,
            cx + guessX + radius + half + 1 <= size, cy + guessY + radius + half + 1 <= size
        else { return nil }

        let side = 2 * half + 1
        let count = Float(side * side)
        var meanA: Float = 0
        for y in (cy - half)...(cy + half) {
            for x in (cx - half)...(cx + half) { meanA += a[y * size + x] }
        }
        meanA /= count
        var varA: Float = 0
        for y in (cy - half)...(cy + half) {
            for x in (cx - half)...(cx + half) {
                let v = a[y * size + x] - meanA
                varA += v * v
            }
        }
        guard varA / count > 1e-6 else { return nil }

        let window = 2 * radius + 1
        var scores = [Float](repeating: -1, count: window * window)
        var best: Float = -2
        var bestDX = guessX
        var bestDY = guessY
        for oy in 0..<window {
            for ox in 0..<window {
                let dx = guessX - radius + ox
                let dy = guessY - radius + oy
                var sumB: Float = 0
                var sumBB: Float = 0
                var sumAB: Float = 0
                for y in -half...half {
                    let rowA = (cy + y) * size
                    let rowB = (cy + y + dy) * size
                    for x in -half...half {
                        let va = a[rowA + cx + x] - meanA
                        let vb = b[rowB + cx + x + dx]
                        sumB += vb
                        sumBB += vb * vb
                        sumAB += va * vb
                    }
                }
                // Σ(A−Ā)(B−B̄) = Σ(A−Ā)·B, так как Σ(A−Ā) = 0
                let varB = sumBB - sumB * sumB / count
                let score: Float = varB > 1e-6 ? sumAB / sqrt(varA * varB) : -1
                scores[oy * window + ox] = score
                if score > best {
                    best = score
                    bestDX = dx
                    bestDY = dy
                }
            }
        }
        return SearchResult(dx: bestDX, dy: bestDY, score: best, scores: scores)
    }

    private static func parabola(_ minus: Float, _ center: Float, _ plus: Float) -> Float {
        let den = minus - 2 * center + plus
        return abs(den) > 1e-9 ? 0.5 * (minus - plus) / den : 0
    }

    private static func matchPair(_ a: GrayImage, _ b: GrayImage, i: Int, j: Int) -> [Correspondence] {
        let size = viewSize
        let basis = viewBasis(normalize(a.forward + b.forward))
        let (a0, validA) = render(a, basis)
        let (b0, validB) = render(b, basis)
        var both = [Bool](repeating: false, count: size * size)
        var bothCount = 0
        for k in 0..<(size * size) where validA[k] && validB[k] {
            both[k] = true
            bothCount += 1
        }
        guard bothCount >= 2000 else { return [] }

        let a1 = downsample(a0, size: size), b1 = downsample(b0, size: size)
        let a2 = downsample(a1, size: size / 2), b2 = downsample(b1, size: size / 2)

        var shifts: [(x: Float, y: Float, sx: Float, sy: Float)] = []
        for gy in stride(from: 16, to: size - 16, by: 16) {
            for gx in stride(from: 16, to: size - 16, by: 16) {
                guard windowIsValid(both, size: size, cx: gx, cy: gy, radius: 20) else { continue }
                guard blockStd(a0, size: size, cx: gx, cy: gy, half: 12) >= 4 else { continue }

                guard let r2 = search(a2, b2, size: size / 4, cx: gx / 4, cy: gy / 4, half: 4,
                                      guessX: 0, guessY: 0, radius: 10) else { continue }
                guard let r1 = search(a1, b1, size: size / 2, cx: gx / 2, cy: gy / 2, half: 8,
                                      guessX: r2.dx * 2, guessY: r2.dy * 2, radius: 2) else { continue }
                guard let r0 = search(a0, b0, size: size, cx: gx, cy: gy, half: 12,
                                      guessX: r1.dx * 2, guessY: r1.dy * 2, radius: 2),
                      r0.score >= 0.7 else { continue }

                // Подпиксельное уточнение по соседним оценкам (если соседа нет в окне — без него)
                let window = 5
                let ox = r0.dx - (r1.dx * 2 - 2)
                let oy = r0.dy - (r1.dy * 2 - 2)
                func score(_ x: Int, _ y: Int) -> Float {
                    guard x >= 0, y >= 0, x < window, y < window else { return r0.score }
                    return r0.scores[y * window + x]
                }
                let sx = Float(r0.dx) + parabola(score(ox - 1, oy), r0.score, score(ox + 1, oy))
                let sy = Float(r0.dy) + parabola(score(ox, oy - 1), r0.score, score(ox, oy + 1))
                shifts.append((Float(gx) + 0.5, Float(gy) + 0.5, sx, sy))
            }
        }
        guard shifts.count >= 6 else { return [] }

        // В общем виде ошибка поворота — почти одинаковый сдвиг везде; блоки, которые с
        // ним не согласны (параллакс, повторяющийся узор), отбрасываем.
        let medianX = median(shifts.map { $0.sx })
        let medianY = median(shifts.map { $0.sy })
        let kept = shifts.filter { s in
            let ex = s.sx - medianX
            let ey = s.sy - medianY
            return ex * ex + ey * ey < 36
        }
        guard kept.count >= 6 else { return [] }

        return kept.map { s in
            Correspondence(
                i: i, j: j,
                dirA: viewDirection(basis, s.x, s.y),
                dirB: viewDirection(basis, s.x + s.sx, s.y + s.sy)
            )
        }
    }

    private static func windowIsValid(_ mask: [Bool], size: Int, cx: Int, cy: Int, radius: Int) -> Bool {
        for y in max(0, cy - radius)...min(size - 1, cy + radius) {
            for x in max(0, cx - radius)...min(size - 1, cx + radius) where !mask[y * size + x] {
                return false
            }
        }
        return true
    }

    private static func blockStd(_ img: [Float], size: Int, cx: Int, cy: Int, half: Int) -> Float {
        var sum: Float = 0
        var sumSq: Float = 0
        for y in (cy - half)...(cy + half) {
            for x in (cx - half)...(cx + half) {
                let v = img[y * size + x]
                sum += v
                sumSq += v * v
            }
        }
        let count = Float((2 * half + 1) * (2 * half + 1))
        let mean = sum / count
        return sqrt(max(0, sumSq / count - mean * mean))
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Подбор поворотов

    /// Повороты кадров (в мировой системе), при которых пары направлений совпадают.
    /// nil — если улучшения нет.
    private static func solveRotations(_ correspondences: [Correspondence], frameCount n: Int) -> [simd_float3x3]? {
        let size = 3 * n
        let prior: Double = 5 // привязка к позам ARKit "весом" как 5 соответствий
        var rotations = [simd_float3x3](repeating: matrix_identity_float3x3, count: n)
        var accumulated = [Double](repeating: 0, count: size)
        var useful = [Bool](repeating: true, count: correspondences.count)
        var initialMedian: Float = 0

        for iteration in 0..<6 {
            var h = [Double](repeating: 0, count: size * size)
            var g = [Double](repeating: 0, count: size)
            for k in 0..<size {
                h[k * size + k] = prior
                g[k] = prior * accumulated[k]
            }

            var residuals: [Float] = []
            residuals.reserveCapacity(correspondences.count)
            for (index, c) in correspondences.enumerated() {
                let a = rotations[c.i] * c.dirA
                let b = rotations[c.j] * c.dirB
                let e = a - b
                residuals.append(length(e))
                guard useful[index] else { continue }

                // e(w) ≈ e − [a]ₓ·w_i + [b]ₓ·w_j
                let ja = -skew(a)
                let jb = skew(b)
                addBlock(&h, size, c.i, c.i, ja.transpose * ja)
                addBlock(&h, size, c.j, c.j, jb.transpose * jb)
                addBlock(&h, size, c.i, c.j, ja.transpose * jb)
                addBlock(&h, size, c.j, c.i, jb.transpose * ja)
                let gi = ja.transpose * e
                let gj = jb.transpose * e
                for r in 0..<3 {
                    g[3 * c.i + r] += Double(gi[r])
                    g[3 * c.j + r] += Double(gj[r])
                }
            }
            let currentMedian = median(residuals)
            if iteration == 0 { initialMedian = currentMedian }

            let step = solveLinear(h, g.map { -$0 }, size: size)
            for k in 0..<n {
                let w = SIMD3<Float>(Float(step[3 * k]), Float(step[3 * k + 1]), Float(step[3 * k + 2]))
                for r in 0..<3 { accumulated[3 * k + r] += step[3 * k + r] }
                rotations[k] = exponential(w) * rotations[k]
            }

            let threshold = max(3 * currentMedian, 0.5 * Float.pi / 180)
            useful = correspondences.map { c in
                length(rotations[c.i] * c.dirA - rotations[c.j] * c.dirB) < threshold
            }
        }

        let finalMedian = median(correspondences.map { c in
            length(rotations[c.i] * c.dirA - rotations[c.j] * c.dirB)
        })
        guard finalMedian < 0.8 * initialMedian else { return nil }
        return rotations
    }

    private static func skew(_ v: SIMD3<Float>) -> simd_float3x3 {
        // столбцы матрицы [v]ₓ (так, что [v]ₓ·u = v × u)
        simd_float3x3(columns: (
            SIMD3<Float>(0, v.z, -v.y),
            SIMD3<Float>(-v.z, 0, v.x),
            SIMD3<Float>(v.y, -v.x, 0)
        ))
    }

    private static func exponential(_ w: SIMD3<Float>) -> simd_float3x3 {
        let angle = length(w)
        guard angle > 1e-9 else { return matrix_identity_float3x3 }
        let k = skew(w / angle)
        return matrix_identity_float3x3 + sin(angle) * k + (1 - cos(angle)) * (k * k)
    }

    private static func addBlock(_ h: inout [Double], _ size: Int, _ bi: Int, _ bj: Int, _ m: simd_float3x3) {
        for r in 0..<3 {
            for c in 0..<3 {
                // m[c][r] — элемент строки r, столбца c
                h[(3 * bi + r) * size + (3 * bj + c)] += Double(m[c][r])
            }
        }
    }

    /// Метод Гаусса с выбором ведущего элемента.
    private static func solveLinear(_ matrix: [Double], _ rhs: [Double], size n: Int) -> [Double] {
        var a = matrix
        var b = rhs
        for col in 0..<n {
            var pivot = col
            for row in (col + 1)..<max(col + 1, n) where abs(a[row * n + col]) > abs(a[pivot * n + col]) {
                pivot = row
            }
            if pivot != col {
                for k in 0..<n { a.swapAt(col * n + k, pivot * n + k) }
                b.swapAt(col, pivot)
            }
            let p = a[col * n + col]
            guard abs(p) > 1e-12 else { continue }
            for row in (col + 1)..<max(col + 1, n) {
                let factor = a[row * n + col] / p
                guard factor != 0 else { continue }
                for k in col..<n { a[row * n + k] -= factor * a[col * n + k] }
                b[row] -= factor * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<max(row + 1, n) { sum -= a[row * n + k] * x[k] }
            let p = a[row * n + row]
            x[row] = abs(p) > 1e-12 ? sum / p : 0
        }
        return x
    }
}
