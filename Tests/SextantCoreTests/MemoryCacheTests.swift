import Foundation
import Testing
@testable import SextantCore

@Test func useOrderMatchesAListKeptInOrderOfUse() {
    var order = UseOrder<Int>()
    var reference: [(key: Int, cost: Int)] = []
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<20_000 {
        let key = Int.random(in: 0..<50, using: &rng)
        switch Int.random(in: 0..<10, using: &rng) {
        case 0..<4:
            let cost = Int.random(in: 0..<100, using: &rng)
            order.use(key, cost: cost)
            reference.removeAll { $0.key == key }
            reference.insert((key, cost), at: 0)
        case 4..<6:
            order.touch(key)
            if let i = reference.firstIndex(where: { $0.key == key }) { reference.insert(reference.remove(at: i), at: 0) }
        case 6:
            let cost = Int.random(in: 0..<100, using: &rng)
            order.setCost(cost, of: key)
            if let i = reference.firstIndex(where: { $0.key == key }) { reference[i].cost = cost }
        case 7:
            #expect(order.remove(key) == reference.contains { $0.key == key })
            reference.removeAll { $0.key == key }
        default:
            #expect(order.removeOldest() == reference.popLast()?.key)
        }
        #expect(order.count == reference.count)
        #expect(order.cost == reference.reduce(0) { $0 + $1.cost })
    }
    #expect(order.keysByUse == reference.map(\.key))
}

@Test func useOrderReusesTheRoomOfKeysRemoved() {
    var order = UseOrder<String>()
    for round in 0..<100 {
        for k in 0..<10 { order.use("\(round)-\(k)", cost: 1) }
        while order.removeOldest() != nil {}
    }
    #expect(order.count == 0 && order.cost == 0 && order.keysByUse.isEmpty)
}

@Suite struct MemoryCacheTests {
    final class Held: Sendable {}

    @Test func dropsTheLeastRecentlyUsedOnceTheBytesPassTheBudget() {
        let cache = MemoryCache(budget: 100)
        cache.insert(1, for: CacheKey("a"), bytes: 40)
        cache.insert(2, for: CacheKey("b"), bytes: 40)
        #expect(cache.value(for: CacheKey("a")) as? Int == 1)
        cache.insert(3, for: CacheKey("c"), bytes: 40)
        #expect(cache.value(for: CacheKey("b")) == nil)
        #expect(cache.value(for: CacheKey("a")) as? Int == 1 && cache.value(for: CacheKey("c")) as? Int == 3)
        #expect(cache.bytes == 80 && cache.count == 2)
    }

    @Test func aValueLargerThanTheBudgetIsKeptAloneUntilTheNextComes() {
        let cache = MemoryCache(budget: 100)
        cache.insert(1, for: CacheKey("a"), bytes: 40)
        cache.insert(2, for: CacheKey("huge"), bytes: 150)
        #expect(cache.value(for: CacheKey("huge")) as? Int == 2)
        #expect(cache.value(for: CacheKey("a")) == nil && cache.bytes == 150)
        cache.insert(3, for: CacheKey("b"), bytes: 10)
        #expect(cache.value(for: CacheKey("huge")) == nil)
        #expect(cache.value(for: CacheKey("b")) as? Int == 3 && cache.bytes == 10)
    }

    @Test func aValueThatGrowsMakesRoomForItself() {
        let cache = MemoryCache(budget: 100)
        cache.insert(1, for: CacheKey("a"), bytes: 30)
        cache.insert(2, for: CacheKey("b"), bytes: 30)
        cache.resize(CacheKey("b"), bytes: 60)
        #expect(cache.bytes == 90)
        cache.resize(CacheKey("b"), bytes: 80)
        #expect(cache.value(for: CacheKey("a")) == nil && cache.bytes == 80)
        cache.resize(CacheKey("b"), bytes: 200)
        #expect(cache.value(for: CacheKey("b")) as? Int == 2 && cache.bytes == 200)
        cache.insert(3, for: CacheKey("c"), bytes: 10)
        cache.resize(CacheKey("b"), bytes: 300)
        #expect(cache.value(for: CacheKey("b")) == nil && cache.bytes == 10)
        cache.resize(CacheKey("never kept"), bytes: 10)
        #expect(cache.count == 1)
    }

    @Test func aValueDroppedIsFreedUnlessSomethingElseHoldsIt() {
        let cache = MemoryCache(budget: 10)
        weak var dropped: Held?, shown: Held?
        let holder: Held
        do {
            let a = Held(), b = Held()
            dropped = a
            shown = b
            holder = b
            cache.insert(a, for: CacheKey(1), bytes: 10)
            cache.insert(b, for: CacheKey(2), bytes: 10)
            cache.insert(Held(), for: CacheKey(3), bytes: 10)
        }
        #expect(dropped == nil)
        #expect(shown === holder)
        cache.remove(CacheKey(3))
        #expect(cache.count == 0)
    }

    @Test func keysOfDifferentTypesNeverMatch() {
        let cache = MemoryCache(budget: 100)
        cache.insert("int", for: CacheKey(1), bytes: 1)
        cache.insert("string", for: CacheKey("1"), bytes: 1)
        #expect(cache.value(for: CacheKey(1)) as? String == "int")
        #expect(cache.value(for: CacheKey("1")) as? String == "string")
    }
}
