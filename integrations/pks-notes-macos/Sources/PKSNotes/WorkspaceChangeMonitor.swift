import Foundation
import CoreServices

/// One macOS filesystem event stream per opened workspace. This is only an
/// invalidation signal: NotesModel re-reads the filesystem as the sole authority.
/// A single recursive stream avoids one watcher per expanded directory.
final class WorkspaceChangeMonitor {
    private var stream: FSEventStreamRef?
    private let onChanges: ([String], Bool) -> Void
    private let startEventID: FSEventStreamEventId
    private let startedAt: Date

    init?(root: URL, onChanges: @escaping ([String], Bool) -> Void) {
        self.onChanges = onChanges
        let startEventID = FSEventsGetCurrentEventId()
        self.startEventID = startEventID
        self.startedAt = Date()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, eventIDs in
            guard let info else { return }
            let observer = Unmanaged<WorkspaceChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            let values = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let indices = (0..<Int(count)).filter { index in
                let flags = eventFlags[index]
                guard WorkspaceChangeMonitor.shouldDeliver(
                    eventID: eventIDs[index], after: observer.startEventID, flags: flags
                ) else { return false }
                return WorkspaceChangeMonitor.changedAfterStart(
                    at: String(cString: values[index]), startDate: observer.startedAt
                )
            }
            guard !indices.isEmpty else { return }
            let changed = indices.map { String(cString: values[$0]) }
            let requiresFullRescan = indices.contains {
                WorkspaceChangeMonitor.requiresFullRescan(for: eventFlags[$0])
            }
            observer.onChanges(changed, requiresFullRescan)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                                             kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
            startEventID, 0.25, flags
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

    /// FSEvents can deliver pre-open atomic-write notifications after stream creation.
    /// Check the changed object and its ancestors so deleted temp files and moved-in
    /// files are classified by the directory mutation that made them visible.
    static func changedAfterStart(at path: String, startDate: Date) -> Bool {
        var candidate = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            if let stamp = WorkspaceFiles.fileStamp(candidate) {
                let changeTime = Double(stamp.changeSeconds)
                    + Double(stamp.changeNanoseconds) / 1_000_000_000
                return changeTime > startDate.timeIntervalSince1970
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else { return false }
            candidate = parent
        }
    }

    static func shouldDeliver(
        eventID: FSEventStreamEventId,
        after startEventID: FSEventStreamEventId,
        flags: FSEventStreamEventFlags
    ) -> Bool {
        eventID > startEventID
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0
    }

    static func requiresFullRescan(for flags: FSEventStreamEventFlags) -> Bool {
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )
        return flags & rescanFlags != 0
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
