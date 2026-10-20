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
        sphere.firstMaterial?.isDoubleSided = false

        let sphereNode = SCNNode(geometry: sphere)
        // Разворачиваем геометрию наизнанку, чтобы текстура была видна из центра сферы, а не только снаружи
        sphereNode.scale = SCNVector3(-1, 1, 1)
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
