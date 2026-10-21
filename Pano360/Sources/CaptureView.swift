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
            CaptureSpaceView(
                session: capture.session,
                panels: capture.capturedPanels,
                targets: capture.gridPoints.filter { !$0.captured },
                alignedID: capture.alignedPointID
            )
            .ignoresSafeArea()

            // Отдельный view: положение камеры меняется 60 раз в секунду, и
            // перерисовываться из-за этого должны только прицел и стрелка.
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

/// Прицел в центре и стрелка к ближайшей неснятой точке, если та вне экрана.
/// Сами точки нарисованы в 3D-пространстве (CaptureSpaceView).
private struct CaptureGuideOverlay: View {
    let capture: CaptureSession

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
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

    private func yawDelta(to point: GridPoint) -> Float {
        point.ignoresYaw ? 0 : angularDifference(point.yaw, capture.currentYaw)
    }

    private func nearestOffscreenDirection(in size: CGSize) -> (point: CGPoint, angle: Float)? {
        let remaining = capture.gridPoints.filter { !$0.captured }
        guard let target = remaining.min(by: { squaredDistance(to: $0) < squaredDistance(to: $1) }) else { return nil }

        // Видимая область 3D-вида (горизонтальный угол задан в CaptureSpaceView)
        let halfX = CaptureSpaceView.horizontalFOVDegrees / 2 * .pi / 180
        let halfY = atan(tan(halfX) * Float(size.height / max(size.width, 1)))
        let dYaw = yawDelta(to: target)
        let dPitch = target.pitch - capture.currentPitch
        if abs(dYaw) < halfX * 0.85, abs(dPitch) < halfY * 0.85 { return nil }

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

/// Пространство съёмки в стиле Google Camera: тёмный "мир" с крестиками на полу,
/// видоискатель с живой камерой размером ровно с будущий снимок и уже снятые
/// кадры на своих местах. Камера ARKit задаёт только позу; угол обзора у
/// виртуальной камеры шире настоящего, чтобы было видно, что вокруг.
private struct CaptureSpaceView: UIViewRepresentable {
    static let horizontalFOVDegrees: Float = 80
    static let spaceColor = UIColor(white: 0.11, alpha: 1)

    let session: ARSession
    let panels: [GridPoint.ID: CapturedPanel]
    let targets: [GridPoint]
    let alignedID: GridPoint.ID?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = Self.spaceColor
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.delegate = context.coordinator
        view.rendersContinuously = true
        view.isPlaying = true
        view.antialiasingMode = .multisampling4X
        context.coordinator.session = session
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.sync(panels: panels, targets: targets, alignedID: alignedID)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let scene = SCNScene()
        let cameraNode = SCNNode()
        weak var session: ARSession?

        private let viewfinder = SCNNode()
        private let viewfinderMaterial = SCNMaterial()
        private var viewfinderSize = CGSize.zero
        private var lastTextureUpdate: TimeInterval = 0
        private let ciContext = CIContext()

        private var panelNodes: [GridPoint.ID: SCNNode] = [:]
        private var targetNodes: [GridPoint.ID: SCNNode] = [:]
        private var alignedID: GridPoint.ID?

        /// Видоискатель чуть ближе снятых кадров (2 м) — живая картинка поверх них.
        private let viewfinderDistance: Float = 1.95

        override init() {
            super.init()

            let camera = SCNCamera()
            camera.projectionDirection = .horizontal
            camera.fieldOfView = CGFloat(CaptureSpaceView.horizontalFOVDegrees)
            camera.zNear = 0.05
            camera.zFar = 60
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            // Дальние крестики растворяются в "тумане" цвета фона
            scene.fogColor = CaptureSpaceView.spaceColor
            scene.fogStartDistance = 4
            scene.fogEndDistance = 15
            scene.rootNode.addChildNode(Self.makeFloorCrosses())

            viewfinderMaterial.lightingModel = .constant
            viewfinderMaterial.isDoubleSided = true
            viewfinderMaterial.diffuse.contents = UIColor.black
            scene.rootNode.addChildNode(viewfinder)
        }

        // MARK: каждый кадр (поток отрисовки SceneKit)

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let frame = session?.currentFrame else { return }
            // Поза для портретной ориентации экрана — так её отдаёт сам ARKit
            cameraNode.simdTransform = frame.camera.viewMatrix(for: .portrait).inverse
            updateViewfinder(with: frame, time: time)
        }

        private func updateViewfinder(with frame: ARFrame, time: TimeInterval) {
            // Видеопоток ARKit шире 12-Мп снимка примерно на 10% (см. PanoramaStitcher),
            // поэтому рамка и картинка в ней — центральная часть потока.
            let crop = PanoramaStitcher.highResolutionFocalCorrection
            let intrinsics = frame.camera.intrinsics
            let resolution = frame.camera.imageResolution
            let halfTanX = Float(resolution.width) / (2 * intrinsics.columns.0.x) / crop
            let halfTanY = Float(resolution.height) / (2 * intrinsics.columns.1.y) / crop
            let size = CGSize(
                width: CGFloat(2 * viewfinderDistance * halfTanX),
                height: CGFloat(2 * viewfinderDistance * halfTanY)
            )
            if abs(size.width - viewfinderSize.width) > 0.001 || abs(size.height - viewfinderSize.height) > 0.001 {
                rebuildViewfinder(size: size)
            }

            var offset = matrix_identity_float4x4
            offset.columns.3.z = -viewfinderDistance
            viewfinder.simdTransform = frame.camera.transform * offset

            // Живая картинка — 30 раз в секунду и в небольшом разрешении: этого хватает глазу
            guard time - lastTextureUpdate > 1.0 / 30 else { return }
            lastTextureUpdate = time
            let image = CIImage(cvPixelBuffer: frame.capturedImage)
            let extent = image.extent
            let cropWidth = extent.width / CGFloat(crop)
            let cropHeight = extent.height / CGFloat(crop)
            let rect = CGRect(x: extent.midX - cropWidth / 2, y: extent.midY - cropHeight / 2, width: cropWidth, height: cropHeight)
            let scale = 640 / cropWidth
            let small = image.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cgImage = ciContext.createCGImage(small, from: small.extent) {
                viewfinderMaterial.diffuse.contents = cgImage
            }
        }

        private func rebuildViewfinder(size: CGSize) {
            viewfinderSize = size
            let plane = SCNPlane(width: size.width, height: size.height)
            plane.materials = [viewfinderMaterial]
            viewfinder.geometry = plane

            // Белая рамка из четырёх тонких полос
            viewfinder.childNodes.forEach { $0.removeFromParentNode() }
            let thickness: CGFloat = 0.022
            let border = SCNMaterial()
            border.lightingModel = .constant
            border.diffuse.contents = UIColor.white
            border.isDoubleSided = true
            let strips: [(CGFloat, CGFloat, Float, Float)] = [
                (size.width + thickness, thickness, 0, Float(size.height / 2)),
                (size.width + thickness, thickness, 0, -Float(size.height / 2)),
                (thickness, size.height + thickness, Float(size.width / 2), 0),
                (thickness, size.height + thickness, -Float(size.width / 2), 0)
            ]
            for (width, height, x, y) in strips {
                let strip = SCNPlane(width: width, height: height)
                strip.materials = [border]
                let node = SCNNode(geometry: strip)
                node.simdPosition = SIMD3<Float>(x, y, 0.002)
                viewfinder.addChildNode(node)
            }
        }

        // MARK: снятые кадры и точки-цели (главный поток)

        func sync(panels: [GridPoint.ID: CapturedPanel], targets: [GridPoint], alignedID: GridPoint.ID?) {
            for (id, panel) in panels where panelNodes[id] == nil {
                let node = Self.makePanelNode(panel)
                scene.rootNode.addChildNode(node)
                panelNodes[id] = node
            }
            for (id, node) in panelNodes where panels[id] == nil {
                node.removeFromParentNode()
                panelNodes[id] = nil
            }

            let targetIDs = Set(targets.map(\.id))
            for (id, node) in targetNodes where !targetIDs.contains(id) {
                node.removeFromParentNode()
                targetNodes[id] = nil
            }
            for point in targets where targetNodes[point.id] == nil {
                let node = Self.makeTargetNode(point)
                scene.rootNode.addChildNode(node)
                targetNodes[point.id] = node
            }
            if alignedID != self.alignedID {
                if let old = self.alignedID { Self.styleTarget(targetNodes[old], aligned: false) }
                if let new = alignedID { Self.styleTarget(targetNodes[new], aligned: true) }
                self.alignedID = alignedID
            }
        }

        /// Плоскость ставится туда, где в момент снимка была "картинка" камеры:
        /// в её системе координат, в 2 м перед объективом, размером с угол обзора.
        private static func makePanelNode(_ panel: CapturedPanel) -> SCNNode {
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

        private static func makeTargetNode(_ point: GridPoint) -> SCNNode {
            let plane = SCNPlane(width: 0.17, height: 0.17)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.isDoubleSided = true
            // Точки всегда поверх видоискателя и кадров, иначе цель "прячется" за рамкой
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            plane.materials = [material]

            let node = SCNNode(geometry: plane)
            node.renderingOrder = 10
            node.constraints = [SCNBillboardConstraint()]
            let direction = SIMD3<Float>(
                cos(point.pitch) * sin(point.yaw),
                sin(point.pitch),
                -cos(point.pitch) * cos(point.yaw)
            )
            node.simdPosition = direction * 2
            styleTarget(node, aligned: false)
            return node
        }

        private static func styleTarget(_ node: SCNNode?, aligned: Bool) {
            node?.geometry?.firstMaterial?.diffuse.contents = aligned ? alignedTargetImage : targetImage
            node?.scale = aligned ? SCNVector3(1.35, 1.35, 1.35) : SCNVector3(1, 1, 1)
        }

        private static let targetImage = ringImage(fill: .clear, stroke: .white)
        private static let alignedTargetImage = ringImage(fill: UIColor(Color.panoAccent).withAlphaComponent(0.85), stroke: .white)

        private static func ringImage(fill: UIColor, stroke: UIColor) -> UIImage {
            let size = CGSize(width: 128, height: 128)
            return UIGraphicsImageRenderer(size: size).image { context in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)
                fill.setFill()
                context.cgContext.fillEllipse(in: rect)
                stroke.setStroke()
                context.cgContext.setLineWidth(9)
                context.cgContext.strokeEllipse(in: rect)
            }
        }

        /// Сетка крестиков на полу (в 1.4 м под камерой, шаг 1 м) — даёт ощущение
        /// пространства и горизонта, как в Google Camera.
        private static func makeFloorCrosses() -> SCNNode {
            let floorY: Float = -1.4
            let half: Float = 0.08
            let radius = 14
            var vertices: [SCNVector3] = []
            var indices: [Int32] = []
            for x in -radius...radius {
                for z in -radius...radius {
                    let fx = Float(x), fz = Float(z)
                    guard fx * fx + fz * fz <= Float(radius * radius) else { continue }
                    let base = Int32(vertices.count)
                    vertices.append(SCNVector3(fx - half, floorY, fz))
                    vertices.append(SCNVector3(fx + half, floorY, fz))
                    vertices.append(SCNVector3(fx, floorY, fz - half))
                    vertices.append(SCNVector3(fx, floorY, fz + half))
                    indices.append(contentsOf: [base, base + 1, base + 2, base + 3])
                }
            }
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: vertices)],
                elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
            )
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor(white: 1, alpha: 0.5)
            geometry.materials = [material]
            return SCNNode(geometry: geometry)
        }
    }
}
