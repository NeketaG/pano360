import SceneKit
import SwiftUI

/// Показывает equirectangular-панораму как сферу изнутри — можно крутить пальцем.
struct SphereViewer: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .black
        scnView.allowsCameraControl = true

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

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
