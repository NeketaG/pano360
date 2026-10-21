import ARKit
import SceneKit
import simd
import SwiftUI
import UIKit

struct CaptureView: View {
    let onFinished: (URL) -> Void

    @State private var capture = CaptureSession()
    @State private var showResetConfirm = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ARViewRepresentable(session: capture.session, panels: capture.capturedPanels)
                .ignoresSafeArea()

            // Отдельный view: положение камеры меняется 60 раз в секунду, и
            // перерисовываться из-за этого должны только метки, а не весь экран.
            CaptureGuideOverlay(capture: capture)
                .ignoresSafeArea()

            VStack {
                CaptureProgressBadge(captured: capture.capturedCount, total: capture.gridPoints.count)
                    .padding(.top, 8)
                Spacer()
                controls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: capture.capturedCount) { old, new in new > old }
        .onAppear {
            capture.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            capture.stop()
            capture.discardIfUnfinished()
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

    private var controls: some View {
        GlassGroup(spacing: 14) {
            HStack(spacing: 14) {
                GlassIconButton(title: "Отменить последний кадр", systemImage: "arrow.uturn.backward") {
                    capture.undoLastCapture()
                }
                .disabled(!capture.canUndo)
                .opacity(capture.canUndo ? 1 : 0.4)

                GlassIconButton(title: "Начать заново", systemImage: "trash") {
                    showResetConfirm = true
                }
                .disabled(!capture.canUndo)
                .opacity(capture.canUndo ? 1 : 0.4)

                Spacer()

                GlassIconButton(
                    title: capture.isTorchOn ? "Выключить фонарик" : "Включить фонарик",
                    systemImage: capture.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                    tint: capture.isTorchOn ? .yellow : .white
                ) {
                    capture.toggleTorch()
                }

                GlassIconButton(title: "Закрыть", systemImage: "xmark") {
                    dismiss()
                }
            }
        }
    }
}

/// "Снято 12 из 31" с полоской прогресса.
private struct CaptureProgressBadge: View {
    let captured: Int
    let total: Int

    var body: some View {
        VStack(spacing: 6) {
            Text(captured == 0 ? "Наведи кружок на точку и замри" : "Снято \(captured) из \(total)")
                .font(.subheadline.weight(.semibold))
                .contentTransition(.numericText())
                .animation(.snappy, value: captured)
            ProgressView(value: Double(captured), total: Double(max(total, 1)))
                .tint(Color.panoAccent)
                .frame(width: 180)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassSurface(in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Метки точек сетки, стрелка к ближайшей неснятой точке и прицел в центре.
private struct CaptureGuideOverlay: View {
    let capture: CaptureSession

    private let guideHalfFOV: Float = 30 * .pi / 180

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                ForEach(visibleMarkers(in: geo.size)) { marker in
                    TargetMarker(isAligned: marker.isAligned)
                        .position(x: center.x + marker.offset.x, y: center.y + marker.offset.y)
                }

                if let arrow = nearestOffscreenDirection(in: geo.size) {
                    Image(systemName: "arrow.up")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.panoAccent)
                        .frame(width: 48, height: 48)
                        .glassSurface(in: Circle())
                        .rotationEffect(.radians(Double(arrow.angle)))
                        .position(x: center.x + arrow.point.x, y: center.y + arrow.point.y)
                }

                Reticle(isAligned: capture.alignedPointID != nil)
                    .position(center)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct VisibleMarker: Identifiable {
        let id: GridPoint.ID
        let offset: CGPoint
        let isAligned: Bool
    }

    private func visibleMarkers(in size: CGSize) -> [VisibleMarker] {
        capture.gridPoints.compactMap { point in
            guard !point.captured, let offset = screenOffset(for: point, in: size) else { return nil }
            return VisibleMarker(id: point.id, offset: offset, isAligned: capture.alignedPointID == point.id)
        }
    }

    private func yawDelta(to point: GridPoint) -> Float {
        point.ignoresYaw ? 0 : angularDifference(point.yaw, capture.currentYaw)
    }

    private func screenOffset(for point: GridPoint, in size: CGSize) -> CGPoint? {
        let dYaw = yawDelta(to: point)
        let dPitch = point.pitch - capture.currentPitch
        guard abs(dYaw) < guideHalfFOV, abs(dPitch) < guideHalfFOV else { return nil }
        let x = CGFloat(dYaw / guideHalfFOV) * (size.width / 2)
        let y = CGFloat(-dPitch / guideHalfFOV) * (size.height / 2)
        return CGPoint(x: x, y: y)
    }

    private func nearestOffscreenDirection(in size: CGSize) -> (point: CGPoint, angle: Float)? {
        let remaining = capture.gridPoints.filter { !$0.captured }
        guard let target = remaining.min(by: { squaredDistance(to: $0) < squaredDistance(to: $1) }) else { return nil }

        let dYaw = yawDelta(to: target)
        let dPitch = target.pitch - capture.currentPitch
        if abs(dYaw) < guideHalfFOV, abs(dPitch) < guideHalfFOV { return nil }

        let angle = atan2(dYaw, dPitch)
        let radius = min(size.width, size.height) / 2 - 56
        return (CGPoint(x: CGFloat(sin(angle)) * radius, y: CGFloat(-cos(angle)) * radius), angle)
    }

    private func squaredDistance(to point: GridPoint) -> Float {
        let dYaw = yawDelta(to: point)
        let dPitch = point.pitch - capture.currentPitch
        return dYaw * dYaw + dPitch * dPitch
    }
}

private struct TargetMarker: View {
    let isAligned: Bool

    var body: some View {
        Circle()
            .fill(isAligned ? Color.panoAccent.opacity(0.35) : .clear)
            .overlay(
                Circle().strokeBorder(isAligned ? Color.panoAccent : .white.opacity(0.9), lineWidth: isAligned ? 4 : 2)
            )
            .frame(width: isAligned ? 50 : 34, height: isAligned ? 50 : 34)
            .shadow(color: .black.opacity(0.4), radius: 4)
            .animation(.snappy, value: isAligned)
    }
}

private struct Reticle: View {
    let isAligned: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isAligned ? Color.panoAccent : .white, lineWidth: 2.5)
                .frame(width: 66, height: 66)
            Circle()
                .fill(isAligned ? Color.panoAccent : .white)
                .frame(width: 6, height: 6)
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
        .scaleEffect(isAligned ? 1.12 : 1)
        .animation(.snappy, value: isAligned)
    }
}

/// Живая картинка камеры (ARSCNView) плюс миниатюры снятых кадров, "приклеенные"
/// в 3D-пространство сессии ARKit там, где они были сняты.
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
        /// размером с реальный угол обзора — поэтому соседние кадры перекрываются
        /// так же, как настоящие фото, без зеркалирования и поворотов.
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
