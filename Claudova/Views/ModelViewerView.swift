import SceneKit
import SwiftUI

/// The 3D preview pane: the SceneKit view plus status overlays.
struct ModelViewerView: View {
    let preview: ModelPreview

    var body: some View {
        SceneView(scene: preview.scene)
            .overlay {
                if preview.stats == nil, preview.loadError == nil {
                    ContentUnavailableView(
                        preview.isLoading ? "Loading Model…" : "No Model Yet",
                        systemImage: "cube.transparent",
                        description: Text(preview.isLoading ? "" : "Describe a design in the chat to get started.")
                    )
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = preview.loadError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if let stats = preview.stats {
                        StatsView(stats: stats)
                    }
                }
                .font(.caption)
                .padding(10)
            }
    }
}

private struct StatsView: View {
    let stats: ModelPreview.Stats

    var body: some View {
        HStack(spacing: 8) {
            Text(dimensions).monospacedDigit()
            Text("·")
            Text("\(stats.triangleCount.formatted()) triangles")
            if stats.partCount > 1 {
                Text("·")
                Text("\(stats.partCount) parts")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .help("Bounding box of the printable parts (X × Y × Z)")
    }

    private var dimensions: String {
        let format = FloatingPointFormatStyle<Float>().precision(.fractionLength(0...2))
        return "\(stats.size.x.formatted(format)) × \(stats.size.y.formatted(format)) × \(stats.size.z.formatted(format)) mm"
    }
}

/// Hosts an `SCNView` showing the `ViewerScene`, with mouse orbit/pan/zoom.
private struct SceneView: NSViewRepresentable {
    let scene: ViewerScene

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = scene.scene
        view.pointOfView = scene.cameraNode
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .windowBackgroundColor
        scene.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}
}
