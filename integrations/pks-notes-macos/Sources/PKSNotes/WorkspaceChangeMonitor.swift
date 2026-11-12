import Foundation
import CoreServices

/// One macOS filesystem event stream per opened workspace. This is only an
/// invalidation signal: NotesModel re-reads the filesystem as the sole authority.
/// A single recursive stream avoids one watcher per expanded directory.
final class WorkspaceChangeMonitor {
    private var stream: FSEventStreamRef?
    private let onChanges: ([String]) -> Void

    init?(root: URL, onChanges: @escaping ([String]) -> Void) {
        self.onChanges = onChanges
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let observer = Unmanaged<WorkspaceChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            let values = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let changed = (0..<Int(count)).map { String(cString: values[$0]) }
            observer.onChanges(changed)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                                             kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags
        ) else { return nil }
        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            return nil
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
