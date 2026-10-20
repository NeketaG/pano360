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
    }
}
