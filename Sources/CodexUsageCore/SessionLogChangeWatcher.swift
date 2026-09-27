import CoreServices
import Darwin
import Foundation

/// Delivers coalesced changes from a watched session-log directory tree.
public final class SessionLogChangeWatcher: @unchecked Sendable {
    public struct ChangeBatch: Sendable {
        public let changedFiles: [URL]
        public let requiresReconciliation: Bool
        public let rootWasChanged: Bool
    }

    public typealias ChangeHandler = @Sendable (ChangeBatch) -> Void

    private let rootURL: URL
    private let latency: TimeInterval
    private let handler: ChangeHandler
    private let queue = DispatchQueue(label: "CodexUsageCore.SessionLogChangeWatcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private struct FileWatch {
        let id: UUID
        let device: dev_t
        let inode: ino_t
        let source: DispatchSourceFileSystemObject
    }
    private var fileWatches: [URL: FileWatch] = [:]
    private var pendingFiles = Set<URL>()
    private var pendingReconciliation = false
    private var pendingRootChange = false
    private var pendingDelivery: DispatchWorkItem?

    public init(rootURL: URL, latency: TimeInterval = 0.25, handler: @escaping ChangeHandler) {
        self.rootURL = rootURL.standardizedFileURL
        self.latency = max(0.05, latency)
        self.handler = handler
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    /// Starts watching the directory tree. Returns false if the directory or event stream is unavailable.
    @discardableResult
    public func start() -> Bool {
        onQueue { startOnQueue() }
    }

    private func startOnQueue() -> Bool {
        guard stream == nil,
              FileManager.default.fileExists(atPath: rootURL.path) else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.receiveEvents,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return false }

        FSEventStreamSetDispatchQueue(createdStream, queue)
        guard FSEventStreamStart(createdStream) else {
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            return false
        }
        stream = createdStream
        reconcileFileWatches()
        return true
    }

    public func stop() {
        onQueue { stopOnQueue() }
    }

    private func stopOnQueue() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        for watch in fileWatches.values { watch.source.cancel() }
        fileWatches.removeAll()
        pendingDelivery?.cancel()
        pendingDelivery = nil
        pendingFiles.removeAll()
        pendingReconciliation = false
        pendingRootChange = false
    }

    private func onQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return work() }
        return queue.sync(execute: work)
    }

    private static let receiveEvents: FSEventStreamCallback = { _, info, eventCount, rawPaths, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<SessionLogChangeWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray
        watcher.receive(paths: paths, flags: eventFlags, count: eventCount)
    }

    private func receive(paths: NSArray, flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        guard stream != nil else { return }
        for index in 0..<count {
            let eventFlags = flags[index]
            if Self.requiresReconciliation(for: eventFlags) || eventFlags == 0 {
                pendingReconciliation = true
            }
            if Self.rootWasChanged(for: eventFlags) {
                pendingRootChange = true
            }
            guard let path = paths[index] as? String else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if url.pathExtension == "jsonl" {
                synchronizeFileWatch(for: url)
                pendingFiles.insert(url)
            }
        }

        if pendingReconciliation { reconcileFileWatches() }
        scheduleDelivery()
    }

    /// FSEvents discovers paths, but can defer repeated writes until the writer closes its descriptor.
    /// Vnode sources report each append even when Codex keeps its writer open between responses.
    private func synchronizeFileWatch(for url: URL) {
        guard url.path.hasPrefix(rootURL.path + "/"),
              url.pathExtension == "jsonl",
              !url.lastPathComponent.hasPrefix(".") else { return }

        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            fileWatches.removeValue(forKey: url)?.source.cancel()
            return
        }
        if let watch = fileWatches[url] {
            if watch.device == metadata.st_dev && watch.inode == metadata.st_ino { return }
            fileWatches.removeValue(forKey: url)?.source.cancel()
        }

        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        guard Double(metadata.st_mtimespec.tv_sec) >= dayStart else { return }
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(descriptor)
            return
        }
        let id = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.receiveFileEvent(for: url, watchID: id)
        }
        source.setCancelHandler { close(descriptor) }
        fileWatches[url] = FileWatch(id: id, device: metadata.st_dev, inode: metadata.st_ino, source: source)
        source.resume()
    }

    private func reconcileFileWatches() {
        // Keep existing sources across midnight: a writer opened yesterday may remain active today.
        for url in Array(fileWatches.keys) { synchronizeFileWatch(for: url) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        let dayStart = Calendar.current.startOfDay(for: Date())
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= dayStart else { continue }
            synchronizeFileWatch(for: url.standardizedFileURL)
        }
    }

    private func receiveFileEvent(for url: URL, watchID: UUID) {
        guard stream != nil, let watch = fileWatches[url], watch.id == watchID else { return }
        let flags = watch.source.data
        pendingFiles.insert(url)
        if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
            pendingReconciliation = true
            fileWatches.removeValue(forKey: url)?.source.cancel()
            synchronizeFileWatch(for: url)
        }
        scheduleDelivery()
    }

    private func scheduleDelivery() {
        guard pendingReconciliation || !pendingFiles.isEmpty else { return }
        pendingDelivery?.cancel()
        let delivery = DispatchWorkItem { [weak self] in self?.deliverPendingChanges() }
        pendingDelivery = delivery
        queue.asyncAfter(deadline: .now() + 0.15, execute: delivery)
    }

    static func requiresReconciliation(for eventFlags: FSEventStreamEventFlags) -> Bool {
        let mustReconcile = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )
        let structuralChange = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed
        )
        return eventFlags & mustReconcile != 0 || eventFlags & structuralChange != 0
    }

    static func rootWasChanged(for eventFlags: FSEventStreamEventFlags) -> Bool {
        eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
    }

    private func deliverPendingChanges() {
        guard stream != nil, pendingReconciliation || !pendingFiles.isEmpty else { return }
        let batch = ChangeBatch(
            changedFiles: pendingFiles.sorted { $0.path < $1.path },
            requiresReconciliation: pendingReconciliation,
            rootWasChanged: pendingRootChange
        )
        pendingFiles.removeAll(keepingCapacity: true)
        pendingReconciliation = false
        pendingRootChange = false
        pendingDelivery = nil
        handler(batch)
    }
}
