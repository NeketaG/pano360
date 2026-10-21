import ARKit
import SceneKit
import simd
import SwiftUI
import UIKit

struct CaptureView: View {
    let onFinished: (URL) -> Void

    @StateObject private var capture = CaptureSession()
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirm = false

    private let guideHalfFOVDeg: Float = 30

    var body: some View {
        ZStack {
            ARViewRepresentable(session: capture.session, panels: capture.capturedPanels)
            .ignoresSafeArea()

            GeometryReader { geo in
                ZStack {
                    ForEach(capture.gridPoints.filter { !$0.captured }) { point in
                        if let offset = screenOffset(for: point, in: geo.size) {
                            MarkerView(isAligned: capture.alignedPointID == point.id)
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
                Text(capture.statusText)
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 12)

                Spacer()

                HStack(spacing: 20) {
                    Button {
                        capture.undoLastCapture()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .opacity(capture.canUndo ? 1 : 0.3)
                    .disabled(!capture.canUndo)

                    Button {
                        showResetConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .opacity(capture.canUndo ? 1 : 0.3)
                    .disabled(!capture.canUndo)

                    Spacer()

                    Button {
                        capture.toggleTorch()
                    } label: {
                        Image(systemName: capture.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                            .font(.title2)
                            .foregroundStyle(capture.isTorchOn ? .yellow : .white)
                            .padding(14)
                            .background(.black.opacity(0.5), in: Circle())
                    }

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            capture.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            capture.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: capture.isFinished) { _, finished in
            if finished { onFinished(capture.outputDirectory) }
        }
        .alert("Начать съёмку заново?", isPresented: $showResetConfirm) {
            Button("Сбросить", role: .destructive) { capture.resetAll() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все снятые кадры в этой съёмке будут удалены.")
        }
    }

    private func yawDelta(to point: GridPoint) -> Float {
        point.ignoresYaw ? 0 : angularDifference(point.yaw, capture.currentYaw)
    }

    private func screenOffset(for point: GridPoint, in size: CGSize) -> CGPoint? {
        let dYaw = yawDelta(to: point)
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

        let dYaw = yawDelta(to: target)
        let dPitch = target.pitch - capture.currentPitch
        let halfFOV = guideHalfFOVDeg * .pi / 180
        if abs(dYaw) < halfFOV, abs(dPitch) < halfFOV { return nil }

        let angle = atan2(dYaw, dPitch)
        let radius = min(size.width, size.height) / 2 - 40
        let point = CGPoint(x: CGFloat(sin(angle)) * radius, y: CGFloat(-cos(angle)) * radius)
        return (point, angle)
    }

    private func squaredDistance(from point: GridPoint) -> Float {
        let dYaw = yawDelta(to: point)
        let dPitch = point.pitch - capture.currentPitch
        return dYaw * dYaw + dPitch * dPitch
    }
}

private struct MarkerView: View {
    let isAligned: Bool

    var body: some View {
        let size: CGFloat = isAligned ? 46 : 36
        Circle()
            .strokeBorder(isAligned ? Color.yellow : Color.white, lineWidth: isAligned ? 4 : 2)
            .frame(width: size, height: size)
    }
}

/// Показывает живую картинку камеры (через ARSCNView) и "приклеивает" миниатюры
/// снятых кадров прямо в 3D-пространство сессии ARKit — в тех направлениях, где
/// они были сняты. Поэтому при повороте телефона они естественно поворачиваются
/// и меняют перспективу вместе с камерой, как настоящие объекты в пространстве,
/// а не плоская накладка поверх экрана.
private struct ARViewRepresentable: UIViewRepresentable {
    let session: ARSession
    let panels: [GridPoint.ID: CapturedPanel]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        context.coordinator.scene = view.scene
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.sync(panels: panels)
    }

    final class Coordinator {
        weak var scene: SCNScene?
        private var nodes: [GridPoint.ID: SCNNode] = [:]

        func sync(panels: [GridPoint.ID: CapturedPanel]) {
            guard let scene else { return }

            for (id, panel) in panels where nodes[id] == nil {
                let node = Self.makePlaneNode(panel: panel)
                scene.rootNode.addChildNode(node)
                nodes[id] = node
            }

            for (id, node) in nodes where panels[id] == nil {
                node.removeFromParentNode()
                nodes[id] = nil
            }
        }

        /// Плоскость ставится ровно туда, где в момент снимка была "картинка" камеры:
        /// в её же системе координат, на расстоянии `distance` перед объективом,
        /// размером с реальный угол обзора. Оси плоскости совпадают с осями камеры,
        /// поэтому снимок не зеркалится и не поворачивается, а соседние кадры
        /// перекрываются так же, как перекрываются настоящие фото.
        private static func makePlaneNode(panel: CapturedPanel) -> SCNNode {
            let distance: Float = 2
            let plane = SCNPlane(
                width: CGFloat(2 * distance * panel.halfTanX),
                height: CGFloat(2 * distance * panel.halfTanY)
            )
            plane.firstMaterial?.diffuse.contents = panel.image
            plane.firstMaterial?.isDoubleSided = true
            plane.firstMaterial?.lightingModel = .constant

            var offset = matrix_identity_float4x4
            offset.columns.3.z = -distance

            let node = SCNNode(geometry: plane)
            node.simdTransform = panel.cameraTransform * offset
            return node
        }
    }
}
