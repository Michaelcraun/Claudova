import AppKit
import SceneKit

/// The SceneKit scene used by the model viewer.
///
/// Cadova models are Z-up in millimeters; SceneKit is Y-up. All model content lives under
/// `modelRoot`, which is rotated so model +Z points up on screen. One scene unit = 1 mm.
@MainActor
final class ViewerScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Parent for model geometry, in Cadova (Z-up) coordinates.
    let modelRoot = SCNNode()
    private var gridNode = SCNNode()
    private var modelBounds: ViewerBounds?
    private weak var view: SCNView?

    init() {
        modelRoot.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(modelRoot)
        addLights()

        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 20_000
        camera.fieldOfView = 40
        // The viewer pane is often narrower than it is tall, so fit to width.
        camera.projectionDirection = .horizontal
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        updateGrid()
        resetCamera()
    }

    func attach(to view: SCNView) {
        self.view = view
    }

    // MARK: - Model

    /// Replaces the displayed model; `nil` clears it.
    func setModel(_ model: ViewerModel?) {
        modelRoot.childNodes.forEach { $0.removeFromParentNode() }
        modelBounds = model?.bounds
        for part in model?.parts ?? [] {
            modelRoot.addChildNode(Self.makeNode(for: part))
        }
        updateGrid()
    }

    private static func makeNode(for part: ViewerPart) -> SCNNode {
        let vertexCount = part.positions.count
        let stride = MemoryLayout<SIMD3<Float>>.stride
        let positions = part.positions.withUnsafeBytes { Data($0) }
        let normals = part.normals.withUnsafeBytes { Data($0) }
        let sources = [
            SCNGeometrySource(
                data: positions, semantic: .vertex, vectorCount: vertexCount, usesFloatComponents: true,
                componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride
            ),
            SCNGeometrySource(
                data: normals, semantic: .normal, vectorCount: vertexCount, usesFloatComponents: true,
                componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride
            ),
        ]
        let elements = part.submeshes.map { submesh in
            let indices = (submesh.triangles.lowerBound * 3..<submesh.triangles.upperBound * 3).map { UInt32($0) }
            return SCNGeometryElement(indices: indices, primitiveType: .triangles)
        }
        let geometry = SCNGeometry(sources: sources, elements: elements)
        geometry.materials = part.submeshes.map { makeMaterial($0.material, semantic: part.semantic) }

        let node = SCNNode(geometry: geometry)
        node.name = part.name
        // Draw see-through parts after opaque ones.
        if part.semantic != .solid { node.renderingOrder = 10 }
        return node
    }

    /// Default look for geometry without a material: a neutral, slightly warm light gray.
    private static let defaultColor = NSColor(srgbRed: 0.82, green: 0.82, blue: 0.80, alpha: 1)

    private static func makeMaterial(_ source: ViewerMaterial?, semantic: ViewerPart.Semantic) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        let color = source.map {
            NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
        } ?? defaultColor
        material.diffuse.contents = color
        material.metalness.contents = source?.metallicness ?? 0
        material.roughness.contents = source?.roughness ?? 0.55

        var opacity = source?.alpha ?? 1
        // Background/context parts are reference geometry: show them faintly.
        if semantic == .context { opacity = min(opacity, 0.25) }
        if opacity < 1 {
            material.transparency = opacity
            material.transparencyMode = .dualLayer
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
        }
        return material
    }

    // MARK: - Camera

    /// Frames the current model from a three-quarter view.
    func resetCamera() {
        let bounds = modelBounds ?? ViewerBounds(min: [-25, -25, 0], max: [25, 25, 25])
        // Model (Z-up) center → world (Y-up).
        let localCenter = bounds.center
        let center = modelRoot.convertPosition(
            SCNVector3(CGFloat(localCenter.x), CGFloat(localCenter.y), CGFloat(localCenter.z)), to: nil
        )
        // Fit the bounding sphere inside the (horizontal) field of view with some margin.
        let radius = CGFloat(max(simd_length(bounds.size) / 2, 5))
        let halfFOV = (cameraNode.camera?.fieldOfView ?? 40) / 2 * .pi / 180
        // The bounding sphere is already conservative for boxy models, so keep the margin small.
        let distance = radius / sin(halfFOV) * 1.1

        let direction = SCNVector3(0.8, 0.6, 1.0).normalized
        cameraNode.position = SCNVector3(
            center.x + direction.x * distance,
            center.y + direction.y * distance,
            center.z + direction.z * distance
        )
        cameraNode.look(at: center)

        if let view {
            view.pointOfView = cameraNode
            view.defaultCameraController.target = center
        }
    }

    // MARK: - Scene content

    private func addLights() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1000
        key.eulerAngles = SCNVector3(-CGFloat.pi / 3, CGFloat.pi / 5, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 400
        fill.eulerAngles = SCNVector3(-CGFloat.pi / 6, -CGFloat.pi * 0.75, 0)
        scene.rootNode.addChildNode(fill)
    }

    /// Rebuilds the build-plate grid to comfortably cover the model's footprint.
    private func updateGrid() {
        gridNode.removeFromParentNode()
        let footprint: Float = modelBounds.map {
            2 * max(abs($0.min.x), abs($0.max.x), abs($0.min.y), abs($0.max.y))
        } ?? 0
        let spacing: CGFloat = footprint > 1000 ? 100 : footprint > 300 ? 50 : 10
        let size = max(200, (CGFloat(footprint) * 1.25 / spacing).rounded(.up) * spacing)
        gridNode = Self.makeGrid(size: size, spacing: spacing)
        scene.rootNode.addChildNode(gridNode)
    }

    /// Grid on the XZ plane (world space), i.e. the model's XY build plate, with emphasized axes.
    private static func makeGrid(size: CGFloat, spacing: CGFloat) -> SCNNode {
        let half = size / 2
        var vertices: [SCNVector3] = []
        var offset = -half
        while offset <= half + 0.001 {
            if abs(offset) > 0.001 {
                vertices += [SCNVector3(offset, 0, -half), SCNVector3(offset, 0, half)]
                vertices += [SCNVector3(-half, 0, offset), SCNVector3(half, 0, offset)]
            }
            offset += spacing
        }
        let node = SCNNode()
        node.addChildNode(lines(vertices, color: NSColor.secondaryLabelColor.withAlphaComponent(0.3)))
        // Model +X runs along world +X; model +Y runs along world −Z.
        node.addChildNode(lines([SCNVector3(-half, 0, 0), SCNVector3(half, 0, 0)], color: NSColor.systemRed.withAlphaComponent(0.6)))
        node.addChildNode(lines([SCNVector3(0, 0, half), SCNVector3(0, 0, -half)], color: NSColor.systemGreen.withAlphaComponent(0.6)))
        return node
    }

    private static func lines(_ vertices: [SCNVector3], color: NSColor) -> SCNNode {
        let indices = (0..<Int32(vertices.count)).map { $0 }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}

private extension SCNVector3 {
    var normalized: SCNVector3 {
        let length = (x * x + y * y + z * z).squareRoot()
        return length > 0 ? SCNVector3(x / length, y / length, z / length) : self
    }
}
