import CoreGraphics
import Foundation
import ImageIO
import simd
import Vision

/// Уточняет ориентацию кадров по их реальному содержимому (общие детали на фото),
/// а не только по данным ARKit. ARKit даёт хорошее грубое приближение, но для близких
/// предметов этого недостаточно — остаётся видимый сдвиг на стыках (параллакс).
///
/// Подход: кольцо на горизонте выравнивается по цепочке — каждый следующий кадр
/// подгоняется под уже уточнённого соседа. Остальные кадры (выше/ниже горизонта,
/// зенит/надир) подгоняются под ближайший уточнённый кадр с горизонта.
/// Если для пары не нашлось надёжного совпадения — кадр остаётся с исходной
/// ориентацией ARKit, это безопаснее, чем применить плохую коррекцию.
enum AlignmentRefiner {
    static func refine(frames: [FrameRecord], progress: ((Double) -> Void)? = nil) -> [FrameRecord] {
        guard !frames.isEmpty else { return frames }
        var corrected = frames
        var done = 0
        let total = frames.count

        let horizonIndices = frames.indices
            .filter { abs(frames[$0].pitch) < 0.2 }
            .sorted { frames[$0].yaw < frames[$1].yaw }

        if horizonIndices.count >= 2 {
            for i in 1..<horizonIndices.count {
                let anchorIdx = horizonIndices[i - 1]
                let targetIdx = horizonIndices[i]
                if let fixed = alignedRecord(target: corrected[targetIdx], anchor: corrected[anchorIdx]) {
                    corrected[targetIdx] = fixed
                }
                done += 1
                progress?(Double(done) / Double(total))
            }
        }

        for idx in frames.indices where !horizonIndices.contains(idx) {
            if let anchorIdx = horizonIndices.min(by: {
                abs(angularDifference(frames[$0].yaw, frames[idx].yaw)) < abs(angularDifference(frames[$1].yaw, frames[idx].yaw))
            }) {
                if let fixed = alignedRecord(target: corrected[idx], anchor: corrected[anchorIdx]) {
                    corrected[idx] = fixed
                }
            }
            done += 1
            progress?(Double(done) / Double(total))
        }

        return corrected
    }

    private static func alignedRecord(target: FrameRecord, anchor: FrameRecord) -> FrameRecord? {
        guard
            let anchorSource = CGImageSourceCreateWithURL(anchor.fileURL as CFURL, nil),
            let anchorImage = CGImageSourceCreateImageAtIndex(anchorSource, 0, nil),
            let targetSource = CGImageSourceCreateWithURL(target.fileURL as CFURL, nil),
            let targetImage = CGImageSourceCreateImageAtIndex(targetSource, 0, nil)
        else { return nil }

        let request = VNHomographicImageRegistrationRequest(targetedCGImage: targetImage, options: [:])
        let handler = VNImageRequestHandler(cgImage: anchorImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageHomographicAlignmentObservation else {
            return nil
        }

        let hPixel = pixelHomography(
            fromNormalized: observation.warpTransform,
            floatingSize: (targetImage.width, targetImage.height),
            referenceSize: (anchorImage.width, anchorImage.height)
        )

        let kAnchorInv = intrinsicsInverse(fx: anchor.fx, fy: anchor.fy, cx: anchor.cx, cy: anchor.cy)
        let kTarget = intrinsicsMatrix(fx: target.fx, fy: target.fy, cx: target.cx, cy: target.cy)
        let r = orthonormalized(kAnchorInv * hPixel * kTarget)

        let angle = rotationAngle(r)
        guard angle.isFinite, angle < (20 * Float.pi / 180) else { return nil }

        let mAnchor = matrix3(rows: anchor.right, anchor.up, -anchor.forward)
        let mTargetCorrected = r.transpose * mAnchor

        let newRight = SIMD3<Float>(mTargetCorrected.columns.0.x, mTargetCorrected.columns.1.x, mTargetCorrected.columns.2.x)
        let newUp = SIMD3<Float>(mTargetCorrected.columns.0.y, mTargetCorrected.columns.1.y, mTargetCorrected.columns.2.y)
        let newForward = -SIMD3<Float>(mTargetCorrected.columns.0.z, mTargetCorrected.columns.1.z, mTargetCorrected.columns.2.z)

        var result = target
        result.right = normalize(newRight)
        result.up = normalize(newUp)
        result.forward = normalize(newForward)
        return result
    }

    /// Vision отдаёт преобразование в нормализованных координатах [0,1] с началом снизу-слева —
    /// переводим в обычные пиксельные координаты (начало сверху-слева), чтобы можно было
    /// использовать вместе с матрицей камеры (fx/fy/cx/cy заданы в пикселях).
    private static func pixelHomography(fromNormalized hNorm: simd_float3x3, floatingSize: (Int, Int), referenceSize: (Int, Int)) -> simd_float3x3 {
        let floatW = Float(floatingSize.0), floatH = Float(floatingSize.1)
        let refW = Float(referenceSize.0), refH = Float(referenceSize.1)

        let sFloat = matrix3(rows: SIMD3(1 / floatW, 0, 0), SIMD3(0, -1 / floatH, 1), SIMD3(0, 0, 1))
        let sRefInv = matrix3(rows: SIMD3(refW, 0, 0), SIMD3(0, -refH, refH), SIMD3(0, 0, 1))

        return sRefInv * hNorm * sFloat
    }

    private static func intrinsicsMatrix(fx: Float, fy: Float, cx: Float, cy: Float) -> simd_float3x3 {
        matrix3(rows: SIMD3(fx, 0, cx), SIMD3(0, fy, cy), SIMD3(0, 0, 1))
    }

    private static func intrinsicsInverse(fx: Float, fy: Float, cx: Float, cy: Float) -> simd_float3x3 {
        matrix3(rows: SIMD3(1 / fx, 0, -cx / fx), SIMD3(0, 1 / fy, -cy / fy), SIMD3(0, 0, 1))
    }

    private static func matrix3(rows r0: SIMD3<Float>, _ r1: SIMD3<Float>, _ r2: SIMD3<Float>) -> simd_float3x3 {
        // simd_float3x3(columns:) ожидает столбцы, поэтому собираем матрицу из строк вручную,
        // чтобы дальше можно было думать в привычной записи "строка на вектор".
        simd_float3x3(columns: (
            SIMD3<Float>(r0.x, r1.x, r2.x),
            SIMD3<Float>(r0.y, r1.y, r2.y),
            SIMD3<Float>(r0.z, r1.z, r2.z)
        ))
    }

    private static func orthonormalized(_ m: simd_float3x3) -> simd_float3x3 {
        var r0 = SIMD3<Float>(m.columns.0.x, m.columns.1.x, m.columns.2.x)
        var r1 = SIMD3<Float>(m.columns.0.y, m.columns.1.y, m.columns.2.y)
        r0 = normalize(r0)
        r1 = normalize(r1 - dot(r1, r0) * r0)
        let r2 = cross(r0, r1)
        return matrix3(rows: r0, r1, r2)
    }

    private static func rotationAngle(_ r: simd_float3x3) -> Float {
        let trace = r.columns.0.x + r.columns.1.y + r.columns.2.z
        let cosAngle = max(-1, min(1, (trace - 1) / 2))
        return acos(cosAngle)
    }
}
