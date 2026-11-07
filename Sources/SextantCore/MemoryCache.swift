import Foundation
import Synchronization

/// Keys in order of use, each with a cost, with every operation in constant time.
///
/// It's a doubly linked list threaded through arrays, with a dictionary from key to node, so
/// moving a key to the front and dropping the least recently used are both O(1).
struct UseOrder<Key: Hashable> {
    private var index: [Key: Int] = [:]
    private var keys: [Key?] = []
    private var costs: [Int] = []
    private var newer: [Int] = []
    private var older: [Int] = []
    private var free: [Int] = []
    /// The most and least recently used nodes, or -1 when empty.
    private var newest = -1
    private var oldest = -1
    /// The total cost of every key.
    private(set) var cost = 0

    var count: Int { index.count }

    func contains(_ key: Key) -> Bool { index[key] != nil }

    func cost(of key: Key) -> Int? { index[key].map { costs[$0] } }

    /// The keys from most to least recently used.
    var keysByUse: [Key] {
        var out: [Key] = []
        var n = newest
        while n >= 0 {
            out.append(keys[n]!)
            n = older[n]
        }
        return out
    }

    /// Adds a key as the most recently used, or moves it there with a new cost.
    mutating func use(_ key: Key, cost c: Int) {
        if let n = index[key] {
            cost += c - costs[n]
            costs[n] = c
            moveToFront(n)
            return
        }
        let n: Int
        if let reused = free.popLast() {
            n = reused
            keys[n] = key
            costs[n] = c
        } else {
            n = keys.count
            keys.append(key)
            costs.append(c)
            newer.append(-1)
            older.append(-1)
        }
        index[key] = n
        cost += c
        link(n)
    }

    /// Moves a key to the most recently used, if it's there.
    mutating func touch(_ key: Key) {
        if let n = index[key] { moveToFront(n) }
    }

    /// Changes a key's cost without counting it as used.
    mutating func setCost(_ c: Int, of key: Key) {
        guard let n = index[key] else { return }
        cost += c - costs[n]
        costs[n] = c
    }

    @discardableResult
    mutating func remove(_ key: Key) -> Bool {
        guard let n = index.removeValue(forKey: key) else { return false }
        unlink(n)
        cost -= costs[n]
        keys[n] = nil
        costs[n] = 0
        free.append(n)
        return true
    }

    /// The most and least recently used keys.
    var newestKey: Key? { newest >= 0 ? keys[newest] : nil }
    var oldestKey: Key? { oldest >= 0 ? keys[oldest] : nil }

    /// Removes and returns the least recently used key.
    mutating func removeOldest() -> Key? {
        guard oldest >= 0, let key = keys[oldest] else { return nil }
        remove(key)
        return key
    }

    private mutating func moveToFront(_ n: Int) {
        guard n != newest else { return }
        unlink(n)
        link(n)
    }

    private mutating func link(_ n: Int) {
        newer[n] = -1
        older[n] = newest
        if newest >= 0 { newer[newest] = n }
        newest = n
        if oldest < 0 { oldest = n }
    }

    private mutating func unlink(_ n: Int) {
        if newer[n] >= 0 { older[newer[n]] = older[n] } else { newest = older[n] }
        if older[n] >= 0 { newer[older[n]] = newer[n] } else { oldest = newer[n] }
        newer[n] = -1
        older[n] = -1
    }
}

/// A key in the memory cache, made from any key that can be sent between tasks.
public struct CacheKey: Hashable, @unchecked Sendable {
    private let base: AnyHashable

    public init<Key: Hashable & Sendable>(_ key: Key) {
        base = AnyHashable(key)
    }
}

/// What the app keeps only because it may be shown again, within one budget of bytes.
///
/// Whole files' texts with what was worked out from them, and the analyses of versions of files,
/// share it. It holds each value, dropping the least recently used once their bytes pass the
/// budget. What a reader shows is held by the reader too, so dropping it from the cache frees
/// it only once nothing shows it; owners keep weak references to find it while it lives.
public final class MemoryCache: Sendable {
    /// The cache the app's texts and analyses share.
    public static let shared = MemoryCache(budget: 64 << 20)

    private struct State {
        var order = UseOrder<CacheKey>()
        var values: [CacheKey: any Sendable] = [:]
    }

    private let state = Mutex(State())
    /// The most bytes kept.
    public let budget: Int

    public init(budget: Int) {
        self.budget = budget
    }

    /// The bytes the values kept are counted as.
    public var bytes: Int { state.withLock { $0.order.cost } }

    /// How many values are kept.
    public var count: Int { state.withLock { $0.order.count } }

    /// Returns a value, counting it as used.
    public func value(for key: CacheKey) -> (any Sendable)? {
        state.withLock { s in
            guard let v = s.values[key] else { return nil }
            s.order.touch(key)
            return v
        }
    }

    /// Keeps a value as the most recently used, dropping the least recently used ones until
    /// the total fits the budget.
    ///
    /// A value larger than the whole budget is kept by itself, until the next value comes, so
    /// whoever asked for it can take it.
    ///
    /// - Parameter bytes: About how much memory the value holds.
    public func insert(_ value: any Sendable, for key: CacheKey, bytes: Int) {
        _ = state.withLock { s -> [any Sendable] in
            var dropped: [any Sendable] = []
            if let old = s.values.removeValue(forKey: key) {
                dropped.append(old)
                s.order.remove(key)
            }
            s.values[key] = value
            s.order.use(key, cost: bytes)
            return dropped + evict(&s, sparing: key)
        }
    }

    /// Counts a kept value as holding more or less memory than it did, such as once what's
    /// worked out from it is added.
    public func resize(_ key: CacheKey, bytes: Int) {
        _ = state.withLock { s -> [any Sendable] in
            guard s.order.contains(key) else { return [] }
            s.order.setCost(bytes, of: key)
            return evict(&s, sparing: s.order.newestKey == key ? key : nil)
        }
    }

    /// Stops keeping a value.
    public func remove(_ key: CacheKey) {
        _ = state.withLock { s -> (any Sendable)? in
            s.order.remove(key)
            return s.values.removeValue(forKey: key)
        }
    }

    /// Drops the least recently used values until the rest fit the budget, returning them so
    /// they're released once the lock is let go.
    ///
    /// - Parameter spared: The newest value, kept even when it alone passes the budget.
    private func evict(_ s: inout State, sparing spared: CacheKey? = nil) -> [any Sendable] {
        var dropped: [any Sendable] = []
        while s.order.cost > budget, let key = s.order.oldestKey, key != spared {
            s.order.remove(key)
            if let v = s.values.removeValue(forKey: key) { dropped.append(v) }
        }
        return dropped
    }
}
