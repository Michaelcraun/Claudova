import Foundation
import Observation
import simd

/// Loads the workspace's model file into the viewer scene and reloads it whenever it changes.
@MainActor
@Observable
final class ModelPreview {
    struct Stats: Equatable {
        var size: SIMD3<Float>
        var triangleCount: Int
        var partCount: Int
    }

    let scene = ViewerScene()
    private(set) var stats: Stats?
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var url: URL?

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Frame the camera on the first successful load of each file; keep the user's view on reloads.
    @ObservationIgnored private var needsFraming = true
    @ObservationIgnored private var generation = 0
    /// Model bounds the camera was last framed for.
    @ObservationIgnored private var framedBounds: ViewerBounds?

    /// Small edits keep the user's camera; a big change in size or position re-frames, since the
    /// old view would crop the model or show it as a speck.
    nonisolated static func shouldReframe(from old: ViewerBounds?, to new: ViewerBounds?) -> Bool {
        guard let old, let new else { return old == nil && new != nil }
        let oldExtent = max(simd_length(old.size), 1)
        let newExtent = max(simd_length(new.size), 1)
        let scale = newExtent / oldExtent
        let shift = simd_distance(old.center, new.center) / oldExtent
        return scale > 1.4 || scale < 0.6 || shift > 0.4
    }

    /// Starts showing (and watching) the model at `url`. Passing the current URL is a no-op.
    func show(_ url: URL?) {
        guard url != self.url else { return }
        self.url = url
        needsFraming = true
        watcher = url.map { FileWatcher(url: $0) { [weak self] in self?.reload() } }
        reload()
    }

    func reload() {
        loadTask?.cancel()
        generation += 1
        let generation = generation
        guard let url else {
            scene.setModel(nil)
            stats = nil
            loadError = nil
            isLoading = false
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Keep showing the last model if the file vanished mid-rebuild.
            isLoading = false
            return
        }
        isLoading = true
        loadTask = Task {
            // Only the most recent load may touch state.
            defer { if generation == self.generation { isLoading = false } }
            do {
                let model = try await ThreeMFMeshLoader.load(url)
                guard generation == self.generation else { return }
                scene.setModel(model)
                if needsFraming || Self.shouldReframe(from: framedBounds, to: model.bounds) {
                    scene.resetCamera()
                    framedBounds = model.bounds
                    needsFraming = false
                }
                stats = Stats(
                    size: model.bounds?.size ?? .zero,
                    triangleCount: model.triangleCount,
                    partCount: model.parts.count
                )
                loadError = nil
            } catch {
                guard generation == self.generation, !(error is CancellationError) else { return }
                loadError = "Couldn't load \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}
