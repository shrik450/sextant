/// A Lua pattern, matched the way Neovim's LuaJIT matches it in `string.find`.
///
/// Tree-sitter queries written for Neovim test captures with `#lua-match?`, which runs
/// `string.find` on the capture's text. Patterns and texts are bytes, and character classes
/// such as `%a` and `%u` are ASCII, as in Lua's C locale. LuaJIT reads patterns as Lua 5.1 does,
/// with `%g` from Lua 5.2.
public struct LuaPattern: Sendable, Hashable {
    private let pattern: [UInt8]
    private let anchored: Bool
    /// Whether the pattern has no special characters, so it's found as it's written.
    private let isPlain: Bool

    /// Reads a pattern, or returns nil for one Lua rejects as malformed, such as one ending in
    /// `%`, with an unclosed `[` or `(`, or with a back reference to a capture not closed yet.
    public init?(_ pattern: String) {
        var bytes = Array(pattern.utf8)
        isPlain = !bytes.contains { LuaPattern.specials.contains($0) }
        anchored = !isPlain && bytes.first == UInt8(ascii: "^")
        if anchored { bytes.removeFirst() }
        self.pattern = bytes
        guard isPlain || LuaPattern.isWellFormed(bytes) else { return nil }
    }

    private static let specials = Array("^$*+?.([%-".utf8)

    /// Whether the pattern matches anywhere in a text.
    public func matches(_ text: String) -> Bool { firstMatch(in: text) != nil }

    /// Returns the UTF-8 offsets of the first match in a text, as `string.find` finds it.
    public func firstMatch(in text: String) -> Range<Int>? {
        var text = text
        return text.withUTF8 { firstMatch(in: $0) }
    }

    /// Returns the offsets of the first match in some bytes, as `string.find` finds it.
    public func firstMatch(in text: UnsafeBufferPointer<UInt8>) -> Range<Int>? {
        if isPlain {
            guard pattern.count <= text.count else { return nil }
            let start = (0...(text.count - pattern.count)).first { s in pattern.indices.allSatisfy { pattern[$0] == text[s + $0] } }
            return start.map { $0..<$0 + pattern.count }
        }
        return pattern.withUnsafeBufferPointer { p in
            var m = Matcher(pattern: p, text: text)
            var start = 0
            repeat {
                if let end = m.match(start, 0) { return start..<end }
                start += 1
            } while start <= text.count && !anchored
            return nil
        }
    }

    private static let escape = UInt8(ascii: "%")

    /// Whether Lua would accept a pattern, checking what Lua checks only as it reaches each
    /// part, since a match may never reach it.
    private static func isWellFormed(_ pattern: [UInt8]) -> Bool {
        pattern.withUnsafeBufferPointer { p in
            var closed: [Bool] = []
            var open: [Int] = []
            var i = 0
            while i < p.count {
                let next: UInt8 = i + 1 < p.count ? p[i + 1] : 0
                switch p[i] {
                case UInt8(ascii: "("):
                    open.append(closed.count)
                    closed.append(false)
                    i += 1
                case UInt8(ascii: ")"):
                    guard let c = open.popLast() else { return false }
                    closed[c] = true
                    i += 1
                case escape where next == UInt8(ascii: "b"):
                    guard i + 3 < p.count else { return false }
                    i += 4
                case escape where next == UInt8(ascii: "f"):
                    guard i + 2 < p.count, p[i + 2] == UInt8(ascii: "["), let end = classEnd(p, i + 2) else { return false }
                    i = end
                case escape where isDigit(next):
                    let n = Int(next) - Int(UInt8(ascii: "1"))
                    guard closed.indices.contains(n), closed[n] else { return false }
                    i += 2
                default:
                    guard let end = classEnd(p, i) else { return false }
                    i = end
                    if i < p.count, quantifiers.contains(p[i]) { i += 1 }
                }
            }
            return open.isEmpty
        }
    }

    private static let quantifiers: [UInt8] = [UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "?")]

    private static func isDigit(_ c: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) }

    /// Returns where the single-character class starting at `i` ends, or nil if it doesn't.
    private static func classEnd(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int? {
        var k = i + 1
        if p[i] == escape { return k < p.count ? k + 1 : nil }
        guard p[i] == UInt8(ascii: "[") else { return k }
        if k < p.count, p[k] == UInt8(ascii: "^") { k += 1 }
        repeat {
            guard k < p.count else { return nil }
            let d = p[k]
            k += 1
            if d == escape {
                guard k < p.count else { return nil }
                k += 1
            }
        } while k >= p.count || p[k] != UInt8(ascii: "]")
        return k + 1
    }

    /// One attempt to match, with the captures it has made so far.
    private struct Matcher {
        let p: UnsafeBufferPointer<UInt8>
        let s: UnsafeBufferPointer<UInt8>
        var captures: [(start: Int, length: Int)] = []

        static let unfinished = -1
        static let position = -2

        init(pattern: UnsafeBufferPointer<UInt8>, text: UnsafeBufferPointer<UInt8>) {
            p = pattern
            s = text
        }

        /// Matches the pattern from `pi` against the text from `si`.
        ///
        /// - Returns: Where the match ends in the text, or nil.
        mutating func match(_ si: Int, _ pi: Int) -> Int? {
            var si = si, pi = pi
            while true {
                guard pi < p.count else { return si }
                switch p[pi] {
                case UInt8(ascii: "("):
                    if pi + 1 < p.count, p[pi + 1] == UInt8(ascii: ")") { return startCapture(si, pi + 2, length: Self.position) }
                    return startCapture(si, pi + 1, length: Self.unfinished)
                case UInt8(ascii: ")"):
                    return endCapture(si, pi + 1)
                case UInt8(ascii: "$") where pi + 1 == p.count:
                    return si == s.count ? si : nil
                case LuaPattern.escape where pi + 1 < p.count && p[pi + 1] == UInt8(ascii: "b"):
                    guard let end = balanced(si, pi + 2) else { return nil }
                    si = end
                    pi += 4
                    continue
                case LuaPattern.escape where pi + 1 < p.count && p[pi + 1] == UInt8(ascii: "f"):
                    pi += 2
                    guard let ep = LuaPattern.classEnd(p, pi) else { return nil }
                    let previous: UInt8 = si == 0 ? 0 : s[si - 1]
                    let current: UInt8 = si < s.count ? s[si] : 0
                    if inBrackets(previous, pi, ep - 1) || !inBrackets(current, pi, ep - 1) { return nil }
                    pi = ep
                    continue
                case LuaPattern.escape where pi + 1 < p.count && LuaPattern.isDigit(p[pi + 1]):
                    guard let end = matchCapture(si, Int(p[pi + 1]) - Int(UInt8(ascii: "1"))) else { return nil }
                    si = end
                    pi += 2
                    continue
                default:
                    break
                }
                guard let ep = LuaPattern.classEnd(p, pi) else { return nil }
                let matched = si < s.count && single(s[si], pi, ep)
                let quantifier: UInt8 = ep < p.count ? p[ep] : 0
                switch quantifier {
                case UInt8(ascii: "?"):
                    if matched, let end = match(si + 1, ep + 1) { return end }
                    pi = ep + 1
                case UInt8(ascii: "*"):
                    return maxExpand(si, pi, ep)
                case UInt8(ascii: "+"):
                    return matched ? maxExpand(si + 1, pi, ep) : nil
                case UInt8(ascii: "-"):
                    return minExpand(si, pi, ep)
                default:
                    guard matched else { return nil }
                    si += 1
                    pi = ep
                }
            }
        }

        mutating func maxExpand(_ si: Int, _ pi: Int, _ ep: Int) -> Int? {
            var i = 0
            while si + i < s.count, single(s[si + i], pi, ep) { i += 1 }
            while i >= 0 {
                if let end = match(si + i, ep + 1) { return end }
                i -= 1
            }
            return nil
        }

        mutating func minExpand(_ si: Int, _ pi: Int, _ ep: Int) -> Int? {
            var si = si
            while true {
                if let end = match(si, ep + 1) { return end }
                guard si < s.count, single(s[si], pi, ep) else { return nil }
                si += 1
            }
        }

        mutating func startCapture(_ si: Int, _ pi: Int, length: Int) -> Int? {
            captures.append((si, length))
            if let end = match(si, pi) { return end }
            captures.removeLast()
            return nil
        }

        mutating func endCapture(_ si: Int, _ pi: Int) -> Int? {
            guard let l = captures.lastIndex(where: { $0.length == Self.unfinished }) else { return nil }
            captures[l].length = si - captures[l].start
            if let end = match(si, pi) { return end }
            captures[l].length = Self.unfinished
            return nil
        }

        func matchCapture(_ si: Int, _ l: Int) -> Int? {
            guard captures.indices.contains(l), captures[l].length >= 0 else { return nil }
            let (start, length) = captures[l]
            guard s.count - si >= length else { return nil }
            for k in 0..<length where s[start + k] != s[si + k] { return nil }
            return si + length
        }

        func balanced(_ si: Int, _ pi: Int) -> Int? {
            guard si < s.count, s[si] == p[pi] else { return nil }
            let open = p[pi], close = p[pi + 1]
            var depth = 1
            var k = si + 1
            while k < s.count {
                if s[k] == close {
                    depth -= 1
                    if depth == 0 { return k + 1 }
                } else if s[k] == open {
                    depth += 1
                }
                k += 1
            }
            return nil
        }

        /// Whether a byte matches the single-character class from `pi` up to `ep`.
        func single(_ c: UInt8, _ pi: Int, _ ep: Int) -> Bool {
            switch p[pi] {
            case UInt8(ascii: "."): true
            case LuaPattern.escape: LuaPattern.inClass(c, p[pi + 1])
            case UInt8(ascii: "["): inBrackets(c, pi, ep - 1)
            default: p[pi] == c
            }
        }

        /// Whether a byte matches the set from the `[` at `pi` to the `]` at `end`.
        func inBrackets(_ c: UInt8, _ pi: Int, _ end: Int) -> Bool {
            var k = pi
            var found = true
            if p[k + 1] == UInt8(ascii: "^") {
                found = false
                k += 1
            }
            k += 1
            while k < end {
                if p[k] == LuaPattern.escape {
                    k += 1
                    if LuaPattern.inClass(c, p[k]) { return found }
                } else if k + 2 < end, p[k + 1] == UInt8(ascii: "-") {
                    if p[k] <= c && c <= p[k + 2] { return found }
                    k += 2
                } else if p[k] == c {
                    return found
                }
                k += 1
            }
            return !found
        }
    }

    /// Whether a byte is in the class `%` and a letter names, or is the character escaped.
    static func inClass(_ c: UInt8, _ cl: UInt8) -> Bool {
        let lower = cl | 0x20
        let isLetter = (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lower)
        let alpha = isASCIILetter(c)
        let digit = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c)
        let graph = (0x21...0x7E).contains(c)
        let result: Bool
        switch isLetter ? lower : 0 {
        case UInt8(ascii: "a"): result = alpha
        case UInt8(ascii: "c"): result = c < 0x20 || c == 0x7F
        case UInt8(ascii: "d"): result = digit
        case UInt8(ascii: "g"): result = graph
        case UInt8(ascii: "l"): result = (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c)
        case UInt8(ascii: "p"): result = graph && !alpha && !digit
        case UInt8(ascii: "s"): result = c == 0x20 || (0x09...0x0D).contains(c)
        case UInt8(ascii: "u"): result = (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(c)
        case UInt8(ascii: "w"): result = alpha || digit
        case UInt8(ascii: "x"): result = digit || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(c) || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(c)
        case UInt8(ascii: "z"): result = c == 0
        default: return cl == c
        }
        return (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(cl) ? !result : result
    }

    private static func isASCIILetter(_ c: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(c)
    }
}
