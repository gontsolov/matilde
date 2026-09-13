import SwiftUI
import SceneKit

/// A snapshot textured onto a bending mesh. The editable new draft stays underneath.
struct PageCurlView: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> CurlSceneView { CurlSceneView(image: image) }
    func updateNSView(_ nsView: CurlSceneView, context: Context) {}
}

final class CurlSceneView: SCNView {
    override var isOpaque: Bool { false }
    private let pageImage: NSImage
    private let front = SCNNode()
    private let back = SCNNode()
    private let cameraNode = SCNNode()
    private let shadowPlane = SCNNode()
    private let frontMaterial = SCNMaterial()
    private let backMaterial = SCNMaterial()
    private var started = false
    private var pageSize = CGSize.zero

    init(image: NSImage) {
        pageImage = image
        super.init(frame: .zero, options: nil)
        backgroundColor = .clear
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
        autoenablesDefaultLighting = false
        allowsCameraControl = false
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        self.scene = scene
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.usesOrthographicProjection = true
        cameraNode.camera?.zNear = 1
        cameraNode.camera?.zFar = 5000
        cameraNode.position = SCNVector3(0, 0, 2000)
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode

        frontMaterial.diffuse.contents = image
        frontMaterial.lightingModel = .blinn
        frontMaterial.ambient.contents = NSColor.white
        frontMaterial.specular.contents = NSColor(white: 0.16, alpha: 1)
        frontMaterial.shininess = 0.18
        frontMaterial.cullMode = .back
        backMaterial.diffuse.contents = Self.underside(image)
        backMaterial.lightingModel = .blinn
        backMaterial.specular.contents = NSColor(white: 0.22, alpha: 1)
        backMaterial.shininess = 0.25
        backMaterial.cullMode = .front
        backMaterial.isDoubleSided = true
        // Separate winding on the back gives lighting the outward-facing normal.
        front.castsShadow = true; back.castsShadow = false
        scene.rootNode.addChildNode(front)
        scene.rootNode.addChildNode(back)

        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 650
        scene.rootNode.addChildNode(ambient)
        let light = SCNNode()
        light.light = SCNLight(); light.light?.type = .directional
        light.light?.intensity = 420
        light.light?.castsShadow = true
        light.light?.shadowMode = .deferred
        light.light?.shadowColor = NSColor.black.withAlphaComponent(0.24)
        light.light?.shadowRadius = 14
        light.light?.shadowSampleCount = 16
        light.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        light.light?.orthographicScale = 1800
        light.eulerAngles = SCNVector3(-0.25, -0.35, 0)
        scene.rootNode.addChildNode(light)
        scene.rootNode.addChildNode(shadowPlane)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        guard !started, bounds.width > 0, bounds.height > 0 else { return }
        started = true
        pageSize = bounds.size
        cameraNode.camera?.orthographicScale = Double(bounds.height / 2)
        let plane = SCNPlane(width: bounds.width * 3, height: bounds.height * 3)
        let shadow = SCNMaterial()
        shadow.lightingModel = .shadowOnly
        shadow.diffuse.contents = NSColor.white
        plane.materials = [shadow]
        shadowPlane.geometry = plane
        shadowPlane.position.z = -2
        updateCurl(0)
        isPlaying = true
        // Lift gently, roll through the middle, then accelerate off the left edge.
        let action = SCNAction.customAction(duration: 1.0) { [weak self] _, elapsed in
            self?.updateCurl(Double(elapsed))
        }
        scene?.rootNode.runAction(action) { [weak self] in
            DispatchQueue.main.async {
                self?.front.isHidden = true; self?.back.isHidden = true
                self?.shadowPlane.isHidden = true; self?.isPlaying = false
            }
        }
    }

    private func updateCurl(_ time: Double) {
        let mesh = CurlMesh(size: pageSize, progress: min(max(time, 0), 1))
        let sources = [SCNGeometrySource(vertices: mesh.vertices), SCNGeometrySource(normals: mesh.normals), SCNGeometrySource(textureCoordinates: mesh.uvs)]
        let geometry = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
        geometry.materials = [frontMaterial]
        front.geometry = geometry
        let reverseNormals = mesh.normals.map { SCNVector3(-$0.x, -$0.y, -$0.z) }
        var reversed: [Int32] = []
        for index in stride(from: 0, to: mesh.indices.count, by: 3) {
            reversed.append(mesh.indices[index])
            reversed.append(mesh.indices[index + 2])
            reversed.append(mesh.indices[index + 1])
        }
        let reverse = SCNGeometry(sources: [sources[0], SCNGeometrySource(normals: reverseNormals), sources[2]], elements: [SCNGeometryElement(indices: reversed, primitiveType: .triangles)])
        reverse.materials = [backMaterial]
        backMaterial.cullMode = .back
        backMaterial.isDoubleSided = false
        back.geometry = reverse
    }

    private static func underside(_ image: NSImage) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        NSColor(calibratedRed: 0.955, green: 0.940, blue: 0.900, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 0.045)
        result.unlockFocus()
        return result
    }
}

/// Cylinder deformation: flat paper, a smooth half-turn, then the returning backside.
struct CurlMesh {
    var vertices: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var uvs: [CGPoint] = []
    var indices: [Int32] = []
    init(size: CGSize, progress: Double) {
        let columns = 120, rows = 24
        let width = Double(size.width), height = Double(size.height)
        let t = progress * progress * (3 - 2 * progress)
        let radius = max(12, width * (0.055 + 0.045 * sin(.pi * t)))
        // Project onto the diagonal pointing toward the bottom-right corner.
        // Moving the fold backward along it rolls the sheet toward the top-left.
        let diagonal = max(1, hypot(width, height))
        let directionX = width / diagonal
        let directionY = -height / diagonal
        let maximum = width * directionX
        let minimum = height * directionY
        let crease = maximum + 20 - t * (maximum - minimum + diagonal * 0.75 + 100)
        for row in 0...rows {
            let v = Double(row) / Double(rows)
            let y = v * height
            for column in 0...columns {
                let u = Double(column) / Double(columns)
                let x = u * width
                let projection = x * directionX + y * directionY
                let distance = max(0, projection - crease)
                let angle = min(.pi, distance / radius)
                let bentProjection = distance == 0 ? projection : crease + radius * sin(angle) - max(0, distance - .pi * radius)
                let displacement = bentProjection - projection
                let z = radius * (1 - cos(angle))
                vertices.append(SCNVector3(x + directionX * displacement - width / 2, y + directionY * displacement - height / 2, z))
                let nx = -directionX * sin(angle), ny = -directionY * sin(angle), nz = cos(angle)
                let length = sqrt(nx * nx + ny * ny + nz * nz)
                normals.append(SCNVector3(nx / length, ny / length, nz / length))
                uvs.append(CGPoint(x: u, y: 1 - v))
            }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let a = Int32(row * (columns + 1) + column), b = a + 1
                let c = a + Int32(columns + 1), d = c + 1
                indices += [a, b, c, b, d, c]
            }
        }
    }
}
