import Foundation

/// Calls `onChange` (debounced) when a file is created, modified, replaced or deleted.
///
/// Cadova writes its output atomically (write to a temp file, then rename), which replaces the
/// inode, so watching only the file would miss changes. The parent directory is watched for
/// renames/creates, and the file itself for in-place writes; the file source is reopened after each
/// event. Changes are confirmed with a modification-date/size fingerprint to skip unrelated events.
@MainActor
final class FileWatcher {
    let url: URL
    private let debounce: Duration
    private let onChange: @MainActor () -> Void

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var lastFingerprint: Fingerprint?

    private struct Fingerprint: Equatable {
        let modified: Date?
        let size: Int?
        let exists: Bool
    }

    init(url: URL, debounce: Duration = .milliseconds(150), onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lastFingerprint = fingerprint()
        directorySource = makeSource(path: directory.path, events: [.write, .rename, .delete])
        fileSource = makeSource(path: url.path, events: [.write, .extend, .rename, .delete, .attrib])
    }

    isolated deinit {
        pending?.cancel()
        directorySource?.cancel()
        fileSource?.cancel()
    }

    private func makeSource(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.eventReceived() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func eventReceived() {
        pending?.cancel()
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    private func settle() {
        // The file may have been replaced; watch the current inode.
        fileSource?.cancel()
        fileSource = makeSource(path: url.path, events: [.write, .extend, .rename, .delete, .attrib])

        let current = fingerprint()
        guard current != lastFingerprint else { return }
        lastFingerprint = current
        onChange()
    }

    private func fingerprint() -> Fingerprint {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Fingerprint(
            modified: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.intValue,
            exists: attributes != nil
        )
    }
}
