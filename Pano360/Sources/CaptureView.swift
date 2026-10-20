import ARKit
import SceneKit
import SwiftUI

struct CaptureView: View {
    @StateObject private var capture = CaptureSession()
    @Environment(\.dismiss) private var dismiss

    private let guideHalfFOVDeg: Float = 30

    var body: some View {
        ZStack {
            ARViewRepresentable(session: capture.session)
                .ignoresSafeArea()

            GeometryReader { geo in
                ZStack {
                    ForEach(capture.gridPoints) { point in
                        if let offset = screenOffset(for: point, in: geo.size) {
                            MarkerView(captured: point.captured, isAligned: capture.alignedPointID == point.id)
                                .position(x: geo.size.width / 2 + offset.x, y: geo.size.height / 2 + offset.y)
                        }
                    }

                    if let arrow = nearestOffscreenDirection(in: geo.size) {
                        Image(systemName: "location.north.fill")
                            .font(.title)
                            .foregroundStyle(.yellow)
                            .rotationEffect(.radians(Double(arrow.angle)))
                            .position(x: geo.size.width / 2 + arrow.point.x, y: geo.size.height / 2 + arrow.point.y)
                    }

                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                }
                .padding()

                Spacer()

                Text(capture.statusText)
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 40)
            }
        }
        .onAppear { capture.start() }
        .onDisappear { capture.stop() }
        .onChange(of: capture.isFinished) { _, finished in
            if finished { dismiss() }
        }
    }

    private func screenOffset(for point: GridPoint, in size: CGSize) -> CGPoint? {
        let dYaw = angularDifference(point.yaw, capture.currentYaw)
        let dPitch = point.pitch - capture.currentPitch
        let halfFOV = guideHalfFOVDeg * .pi / 180
        guard abs(dYaw) < halfFOV, abs(dPitch) < halfFOV else { return nil }
        let x = CGFloat(dYaw / halfFOV) * (size.width / 2)
        let y = CGFloat(-dPitch / halfFOV) * (size.height / 2)
        return CGPoint(x: x, y: y)
    }

    private func nearestOffscreenDirection(in size: CGSize) -> (point: CGPoint, angle: Float)? {
        let remaining = capture.gridPoints.filter { !$0.captured }
        guard let target = remaining.min(by: {
            squaredDistance(from: $0) < squaredDistance(from: $1)
        }) else { return nil }

        let dYaw = angularDifference(target.yaw, capture.currentYaw)
        let dPitch = target.pitch - capture.currentPitch
        let halfFOV = guideHalfFOVDeg * .pi / 180
        if abs(dYaw) < halfFOV, abs(dPitch) < halfFOV { return nil }

        let angle = atan2(dYaw, dPitch)
        let radius = min(size.width, size.height) / 2 - 40
        let point = CGPoint(x: CGFloat(sin(angle)) * radius, y: CGFloat(-cos(angle)) * radius)
        return (point, angle)
    }

    private func squaredDistance(from point: GridPoint) -> Float {
        let dYaw = angularDifference(point.yaw, capture.currentYaw)
        let dPitch = point.pitch - capture.currentPitch
        return dYaw * dYaw + dPitch * dPitch
    }
}

private struct MarkerView: View {
    let captured: Bool
    let isAligned: Bool

    var body: some View {
        Circle()
            .strokeBorder(captured ? Color.green : (isAligned ? Color.yellow : Color.white), lineWidth: isAligned ? 4 : 2)
            .background(Circle().fill(captured ? Color.green.opacity(0.3) : Color.clear))
            .frame(width: isAligned ? 46 : 36, height: isAligned ? 46 : 36)
    }
}

private struct ARViewRepresentable: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
