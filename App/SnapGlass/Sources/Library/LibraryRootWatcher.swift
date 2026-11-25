import Darwin
import Foundation

extension Notification.Name {
    /// Posted (debounced) when a recording root, its session index, or its
    /// index file changes. The library window refreshes without polling.
    static let recordingLibraryDidChange = Notification.Name(
        "SnapGlass.recordingLibraryDidChange"
    )
}

/// Watches recording roots and their index/session directories with
/// `DispatchSource`, then posts one debounced library refresh.
@MainActor
final class LibraryRootWatcher: ObservableObject {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var watchedPaths = Set<String>()
    private var debounceTask: Task<Void, Never>?
    private let queue = DispatchQueue(
        label: "com.snapglass.library.root-watcher",
        qos: .utility
    )

    func start(roots: [URL]) {
        stop()
        for root in roots {
            watch(root)
            let sessions = root.appendingPathComponent(
                ".SnapGlassSessions",
                isDirectory: true
            )
            watch(sessions)
            watch(sessions.appendingPathComponent("recording-index.json"))
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
        watchedPaths.removeAll()
    }

    private func watch(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard watchedPaths.insert(standardized.path).inserted else { return }
        let descriptor = open(standardized.path, O_EVTONLY)
        guard descriptor >= 0 else {
            watchedPaths.remove(standardized.path)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        sources.append(source)
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, self != nil else { return }
            NotificationCenter.default.post(
                name: .recordingLibraryDidChange,
                object: nil
            )
        }
    }

    deinit {
        debounceTask?.cancel()
        for source in sources {
            source.cancel()
        }
    }
}
