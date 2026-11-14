import Foundation

/// Calls `onChange` (on the main queue, debounced) when a file is modified.
/// Survives editors that save by writing a new file and renaming it over the old one.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var retries = 0

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }

    private func start() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Mid atomic-save the file can briefly not exist; try again shortly.
            if retries < 25 {
                retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.start() }
            }
            return
        }
        retries = 0
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        src.setEventHandler { [weak self, unowned src] in
            guard let self else { return }
            if !src.data.isDisjoint(with: [.delete, .rename]) {
                self.source?.cancel()
                self.source = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.start() }
            }
            self.scheduleChange()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
