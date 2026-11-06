import CoreServices
import Foundation

/// An FSEvents watcher that delivers batches of changed paths, which FSEvents gives canonical.
public final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?

    /// The handler, kept by the stream itself so no callback outlives it.
    private final class Delivery {
        let handler: ([String]) -> Void
        init(_ handler: @escaping ([String]) -> Void) { self.handler = handler }
    }

    /// Starts watching folders and everything inside them.
    ///
    /// - Parameters:
    ///   - paths: The folders.
    ///   - latency: How long FSEvents gathers changes before delivering them, in seconds.
    ///   - queue: Where the handler runs.
    ///   - handler: Told the paths that changed.
    public init(paths: [CanonicalPath], latency: TimeInterval = 0.1, queue: DispatchQueue = .main, handler: @escaping ([String]) -> Void) {
        let delivery = Unmanaged.passRetained(Delivery(handler)).toOpaque()
        var ctx = FSEventStreamContext(version: 0, info: delivery, retain: nil, release: { info in
            if let info { Unmanaged<Delivery>.fromOpaque(info).release() }
        }, copyDescription: nil)
        let unique = Array(Set(paths.map(\.path)))
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let arr = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            Unmanaged<Delivery>.fromOpaque(info).takeUnretainedValue().handler(Array(arr.prefix(count)))
        }, &ctx, unique as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        } else {
            Unmanaged<Delivery>.fromOpaque(delivery).release()
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
