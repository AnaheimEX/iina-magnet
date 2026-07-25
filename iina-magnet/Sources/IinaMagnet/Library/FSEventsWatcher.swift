//
//  FSEventsWatcher.swift
//  IinaMagnet
//
//  Phase 2 (Issue 04). Watches scan roots for changes and, after a debounce,
//  hands the set of affected directories to a callback so LibraryService can do
//  a localized re-scan. The debounce + path-folding logic lives in the pure
//  `ChangeCoalescer` (unit-tested); the live FSEvents stream is a thin wrapper.

import Foundation
import CoreServices
import OSLog

/// Pure accumulator: collect changed file paths, fold to the set of affected
/// directories on flush. No timers — deterministic and unit-testable.
struct ChangeCoalescer {
    private var pending: Set<String> = []

    mutating func add(_ path: String) {
        pending.insert(path)
    }

    var isEmpty: Bool { pending.isEmpty }

    /// Returns the affected directories (parent dir of each changed path,
    /// deduped) and clears the buffer.
    mutating func flush() -> Set<URL> {
        defer { pending.removeAll(keepingCapacity: true) }
        return Set(pending.map { path in
            URL(fileURLWithPath: path).deletingLastPathComponent()
        })
    }
}

public final class FSEventsWatcher: @unchecked Sendable {

    private static let logger = Logger(subsystem: "iina-magnet", category: "fsevents")

    private let roots: [URL]
    private let debounce: TimeInterval
    private let onChange: (Set<URL>) -> Void

    private let queue = DispatchQueue(label: "iina-magnet.fsevents")
    private var stream: FSEventStreamRef?
    private var coalescer = ChangeCoalescer()

    public init(roots: [URL],
                debounce: TimeInterval = 0.5,
                onChange: @escaping (Set<URL>) -> Void) {
        self.roots = roots
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard stream == nil, !roots.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let paths = roots.map { $0.path } as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
                // FSEvents passes eventPaths as a void* that actually points to a
                // CFArray of CFString; unsafeBitCast is required to recover it
                // (the API erases the type). compactMap guards non-string entries.
                let cfPaths = unsafeBitCast(paths, to: NSArray.self)
                watcher.handleBatch(cfPaths.compactMap { $0 as? String })
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            flags) else {
            Self.logger.error("FSEventStreamCreate failed")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        Self.logger.info("watching \(self.roots.count) root(s)")
    }

    public func stop() {
        queue.sync {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    /// Called on `queue` from the FSEvents callback with one already-debounced
    /// batch (the stream's `latency` coalesces events within the window). Fold
    /// the batch's paths to affected directories and fire once.
    private func handleBatch(_ paths: [String]) {
        for p in paths { coalescer.add(p) }
        let dirs = coalescer.flush()
        if !dirs.isEmpty { onChange(dirs) }
    }
}
