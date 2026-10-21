import SceneKit
import SwiftUI

/// Показывает equirectangular-панораму как сферу изнутри — можно тянуть пальцем,
/// как фотографию (содержимое следует за пальцем, а не "взгляд").
struct SphereViewer: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .black

        let scene = SCNScene()
        scnView.scene = scene

        let sphere = SCNSphere(radius: 20)
        sphere.segmentCount = 96
        sphere.firstMaterial?.diffuse.contents = image
        sphere.firstMaterial?.diffuse.wrapS = .repeat
        // isDoubleSided — чтобы поверхность было видно и изнутри сферы, не только снаружи.
        // constant — чтобы текстура показывалась как есть, без имитации освещения
        // (иначе без источников света на сцене материал рендерится чёрным).
        sphere.firstMaterial?.isDoubleSided = true
        sphere.firstMaterial?.lightingModel = .constant

        let sphereNode = SCNNode(geometry: sphere)
        // Без этого разворота текстура изнутри сферы видна зеркально (классическая
        // особенность сфер-скайбоксов: при взгляде изнутри направление "вправо по
        // текстуре" меняется на обратное). Файл на диске при этом не зеркалится —
        // это только про то, как рисует сцену SceneKit.
        sphereNode.scale = SCNVector3(-1, 1, 1)
        scene.rootNode.addChildNode(sphereNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 80
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode

        context.coordinator.cameraNode = cameraNode
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        scnView.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        scnView.addGestureRecognizer(pinch)

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    final class Coordinator: NSObject {
        weak var cameraNode: SCNNode?
        private var yaw: Float = 0
        private var pitch: Float = 0

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let cameraNode else { return }
            let translation = gesture.translation(in: gesture.view)
            let sensitivity: Float = 0.005

            // Знак подобран так, чтобы изображение "тянулось" за пальцем,
            // как фотография, а не камера крутилась вслед за свайпом.
            yaw += Float(translation.x) * sensitivity
            pitch += Float(translation.y) * sensitivity
            pitch = max(-1.5, min(1.5, pitch))

            cameraNode.eulerAngles = SCNVector3(pitch, yaw, 0)
            gesture.setTranslation(.zero, in: gesture.view)
        }

        /// Масштаб двумя пальцами — меняем угол обзора камеры (как зум в просмотрщиках 360°).
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let camera = cameraNode?.camera else { return }
            camera.fieldOfView = min(max(camera.fieldOfView / gesture.scale, 35), 100)
            gesture.scale = 1
        }
    }
}
