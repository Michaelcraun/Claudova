import Foundation
import simd
import ThreeMF

/// Render-ready mesh data for a whole 3MF file, in model coordinates (Z-up, millimeters).
struct ViewerModel: Sendable {
    var parts: [ViewerPart]

    var triangleCount: Int { parts.reduce(0) { $0 + $1.triangleCount } }

    /// Bounds of the printable (solid) parts, or of everything if there are none.
    var bounds: ViewerBounds? {
        let solids = parts.filter { $0.semantic == .solid }
        return (solids.isEmpty ? parts : solids).map(\.bounds).reduce(nil) { $0?.union($1) ?? $1 }
    }
}

/// One build item (a Cadova part), as unindexed triangles grouped by material.
struct ViewerPart: Sendable {
    enum Semantic: String, Sendable {
        case solid, visual, context
    }

    var name: String
    var semantic: Semantic
    /// Three vertices per triangle (unindexed, so faces get flat normals).
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    /// Contiguous triangle ranges sharing a material.
    var submeshes: [Submesh]
    var bounds: ViewerBounds

    var triangleCount: Int { positions.count / 3 }

    struct Submesh: Sendable {
        var material: ViewerMaterial?
        /// Range in triangles.
        var triangles: Range<Int>
    }
}

/// A resolved 3MF material: sRGB color (0–1) plus PBR parameters from metallic display properties.
struct ViewerMaterial: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    var metallicness: Double?
    var roughness: Double?
}

struct ViewerBounds: Equatable, Sendable {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var size: SIMD3<Float> { max - min }
    var center: SIMD3<Float> { (min + max) / 2 }

    func union(_ other: ViewerBounds) -> ViewerBounds {
        ViewerBounds(min: simd_min(min, other.min), max: simd_max(max, other.max))
    }
}

enum ThreeMFMeshLoader {
    /// Reads and flattens a 3MF file. Runs on the global executor (off the main actor).
    @concurrent
    static func load(_ url: URL) async throws -> ViewerModel {
        let loaded = try await ModelLoader(url: url).load()
        var parts: [ViewerPart] = []

        for loadedItem in loaded.items {
            let semantic = loadedItem.item.customAttributes
                .first { $0.key.localName == "semantic" }
                .flatMap { ViewerPart.Semantic(rawValue: $0.value) } ?? .solid
            let name = loadedItem.item.partNumber ?? loadedItem.rootObject.name ?? "Part"

            // Collect triangles per material across all components of the item.
            var trianglesByMaterial: [ViewerMaterial?: [SIMD3<Float>]] = [:]
            var materialOrder: [ViewerMaterial?] = []

            for component in loadedItem.components {
                try Task.checkCancellation()
                let loadedMesh = loaded.meshes[component.meshIndex]
                let model = loaded.models[loadedMesh.modelIndex]
                let mesh = loadedMesh.mesh
                let vertices = transformedVertices(mesh.vertices, by: component.transforms)
                var resolver = MaterialResolver(model: model)

                for triangle in mesh.triangles {
                    let material = resolver.material(
                        group: triangle.propertyGroup ?? component.propertyGroupID,
                        index: triangle.propertyIndex?.indices.first ?? component.propertyIndex
                    )
                    guard vertices.indices.contains(triangle.v1),
                          vertices.indices.contains(triangle.v2),
                          vertices.indices.contains(triangle.v3) else { continue }
                    if trianglesByMaterial[material] == nil { materialOrder.append(material) }
                    trianglesByMaterial[material, default: []]
                        .append(contentsOf: [vertices[triangle.v1], vertices[triangle.v2], vertices[triangle.v3]])
                }
            }

            if let part = makePart(name: name, semantic: semantic, trianglesByMaterial, order: materialOrder) {
                parts.append(part)
            }
        }
        return ViewerModel(parts: parts)
    }

    private static func makePart(
        name: String,
        semantic: ViewerPart.Semantic,
        _ trianglesByMaterial: [ViewerMaterial?: [SIMD3<Float>]],
        order: [ViewerMaterial?]
    ) -> ViewerPart? {
        var positions: [SIMD3<Float>] = []
        var submeshes: [ViewerPart.Submesh] = []
        for material in order {
            guard let corners = trianglesByMaterial[material], !corners.isEmpty else { continue }
            let start = positions.count / 3
            positions.append(contentsOf: corners)
            submeshes.append(.init(material: material, triangles: start..<(positions.count / 3)))
        }
        guard let first = positions.first else { return nil }

        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(positions.count)
        var bounds = ViewerBounds(min: first, max: first)
        for t in stride(from: 0, to: positions.count, by: 3) {
            let a = positions[t], b = positions[t + 1], c = positions[t + 2]
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            let normal = length > 0 ? cross / length : SIMD3<Float>(0, 0, 1)
            normals.append(contentsOf: [normal, normal, normal])
            bounds.min = simd_min(bounds.min, simd_min(a, simd_min(b, c)))
            bounds.max = simd_max(bounds.max, simd_max(a, simd_max(b, c)))
        }
        return ViewerPart(
            name: name, semantic: semantic, positions: positions, normals: normals,
            submeshes: submeshes, bounds: bounds
        )
    }

    /// Applies 3MF transforms (ordered parent → child) to vertices.
    /// 3MF uses row vectors: p' = [x y z 1] · M, with M given as four rows of three.
    static func transformedVertices(_ vertices: [Mesh.Vertex], by transforms: [Matrix3D]) -> [SIMD3<Float>] {
        // Child transform applies first, so compose child-to-parent.
        let matrices = transforms.reversed().map(\.values)
        return vertices.map { vertex in
            var p = SIMD3<Double>(vertex.x, vertex.y, vertex.z)
            for m in matrices {
                p = SIMD3(
                    p.x * m[0][0] + p.y * m[1][0] + p.z * m[2][0] + m[3][0],
                    p.x * m[0][1] + p.y * m[1][1] + p.z * m[2][1] + m[3][1],
                    p.x * m[0][2] + p.y * m[1][2] + p.z * m[2][2] + m[3][2]
                )
            }
            return SIMD3<Float>(p)
        }
    }
}

/// Resolves (property group, index) pairs against one 3MF model's resources, with caching.
private struct MaterialResolver {
    let model: ThreeMF.Model
    private var cache: [Key: ViewerMaterial?] = [:]

    private struct Key: Hashable {
        let group: ResourceID
        let index: ResourceIndex
    }

    init(model: ThreeMF.Model) {
        self.model = model
    }

    mutating func material(group: ResourceID?, index: ResourceIndex?) -> ViewerMaterial? {
        guard let group, let index else { return nil }
        let key = Key(group: group, index: index)
        if let cached = cache[key] { return cached }
        let resolved = resolve(group: group, index: index)
        cache[key] = resolved
        return resolved
    }

    private func resolve(group: ResourceID, index: ResourceIndex) -> ViewerMaterial? {
        switch model.resources.resource(for: group) {
        case let colors as ColorGroup:
            guard colors.colors.indices.contains(index) else { return nil }
            var material = ViewerMaterial(colors.colors[index])
            if let propertiesID = colors.displayPropertiesID,
               let metallic = model.resources.resource(for: propertiesID) as? MetallicDisplayProperties,
               metallic.metallics.indices.contains(index) {
                material.metallicness = metallic.metallics[index].metallicness
                material.roughness = metallic.metallics[index].roughness
            }
            return material
        case let base as BaseMaterialGroup:
            guard base.properties.indices.contains(index) else { return nil }
            return ViewerMaterial(base.properties[index].displayColor)
        default:
            return nil
        }
    }
}

private extension ViewerMaterial {
    init(_ color: ThreeMF.Color) {
        self.init(
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255,
            alpha: Double(color.alpha) / 255
        )
    }
}
