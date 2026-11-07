import Synchronization

/// Work that runs once for everyone waiting on it, and stops once no one is.
///
/// Every caller of `value(starting:)` while the work runs waits for that one run. A caller
/// whose task is cancelled stops waiting at once, and when the last one has, the run's task is
/// cancelled, so work nobody wants any more stops as far as it checks for cancellation. Work
/// that another caller still waits on runs on for them.
public final class SharedWork<Value: Sendable>: Sendable {
    private struct State {
        var run: Task<Void, Never>?
        /// Counts runs, so a run that was cancelled can't finish a later one's waiters.
        var generation = 0
        var waiters: [Int: CheckedContinuation<Value?, Never>] = [:]
        var lastWaiter = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Whether the work is running for someone now.
    public var isRunning: Bool { state.withLock { $0.run != nil } }

    /// Waits for the work's value, starting the work unless it's running already.
    ///
    /// - Parameter work: What to run when nothing is running. A caller joining a run waits for
    ///   that run's value instead.
    /// - Returns: The run's value, or nil if this caller's task was cancelled first, or the work
    ///   returned nil.
    public func value(starting work: @escaping @Sendable () async -> Value?) async -> Value? {
        let id = state.withLock { s in
            s.lastWaiter += 1
            return s.lastWaiter
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Value?, Never>) in
                let waiting = state.withLock { s in
                    guard !Task.isCancelled else { return false }
                    s.waiters[id] = c
                    if s.run == nil {
                        s.generation += 1
                        let generation = s.generation
                        s.run = Task { self.finish(generation, with: await work()) }
                    }
                    return true
                }
                if !waiting { c.resume(returning: nil) }
            }
        } onCancel: {
            leave(id)
        }
    }

    private func finish(_ generation: Int, with value: Value?) {
        let waiting = state.withLock { s -> [CheckedContinuation<Value?, Never>] in
            guard s.generation == generation else { return [] }
            s.run = nil
            defer { s.waiters = [:] }
            return Array(s.waiters.values)
        }
        for c in waiting { c.resume(returning: value) }
    }

    /// Stops a caller's wait, and the run once no one waits on it.
    private func leave(_ id: Int) {
        let (waiter, run) = state.withLock { s -> (CheckedContinuation<Value?, Never>?, Task<Void, Never>?) in
            guard let c = s.waiters.removeValue(forKey: id) else { return (nil, nil) }
            guard s.waiters.isEmpty, let run = s.run else { return (c, nil) }
            s.run = nil
            s.generation += 1
            return (c, run)
        }
        waiter?.resume(returning: nil)
        run?.cancel()
    }
}
