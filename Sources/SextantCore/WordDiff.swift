import Foundation

/// Splits UTF-16 text into identifier runs, whitespace runs and single other characters.
func wordTokens(_ s: [UInt16]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var i = 0
    func cls(_ c: UInt16) -> Int {
        if c == 32 || c == 9 { return 1 }
        if (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 { return 2 }
        return 0
    }
    while i < s.count {
        let k = cls(s[i])
        var j = i + 1
        if k != 0 { while j < s.count, cls(s[j]) == k { j += 1 } }
        out.append(i..<j)
        i = j
    }
    return out
}

/// Returns the character ranges that differ between two versions of a line.
///
/// - Returns: The differing ranges in the old and new line, or nil when the lines are too
///   different for intra-line emphasis to be meaningful.
public func wordDiff(_ a: String, _ b: String) -> (old: [NSRange], new: [NSRange])? {
    let ua = Array(a.utf16), ub = Array(b.utf16)
    let ta = wordTokens(ua), tb = wordTokens(ub)
    let n = ta.count, m = tb.count
    guard n > 0, m > 0, n * m <= 250_000 else { return nil }
    func eq(_ i: Int, _ j: Int) -> Bool { ua[ta[i]] == ub[tb[j]] }

    var dp = [UInt16](repeating: 0, count: (n + 1) * (m + 1))
    let w = m + 1
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            dp[i * w + j] = eq(i, j) ? dp[(i + 1) * w + j + 1] + 1 : max(dp[(i + 1) * w + j], dp[i * w + j + 1])
        }
    }
    var keepA = [Bool](repeating: false, count: n), keepB = [Bool](repeating: false, count: m)
    var i = 0, j = 0, common = 0
    while i < n, j < m {
        if eq(i, j) {
            keepA[i] = true; keepB[j] = true
            common += ta[i].count
            i += 1; j += 1
        } else if dp[(i + 1) * w + j] >= dp[i * w + j + 1] {
            i += 1
        } else {
            j += 1
        }
    }
    let nonSpace = max(ua.filter { $0 != 32 && $0 != 9 }.count, ub.filter { $0 != 32 && $0 != 9 }.count)
    guard nonSpace > 0, Double(common) / Double(max(ua.count, ub.count)) >= 0.35 else { return nil }

    func ranges(_ toks: [Range<Int>], _ keep: [Bool]) -> [NSRange] {
        var out: [NSRange] = []
        for (k, t) in toks.enumerated() where !keep[k] {
            if let last = out.last, last.location + last.length == t.lowerBound {
                out[out.count - 1].length += t.count
            } else {
                out.append(NSRange(location: t.lowerBound, length: t.count))
            }
        }
        return out
    }
    return (ranges(ta, keepA), ranges(tb, keepB))
}

/// Pairs each run of deleted lines with the run of added lines right after it, line by line.
///
/// - Returns: `(deletedIndex, addedIndex)` pairs of indices into `lines`.
public func pairChangedLines(_ lines: [DiffLine]) -> [(Int, Int)] {
    var pairs: [(Int, Int)] = []
    var i = 0
    while i < lines.count {
        guard lines[i].kind == .deleted else { i += 1; continue }
        let delStart = i
        while i < lines.count, lines[i].kind == .deleted { i += 1 }
        let addStart = i
        while i < lines.count, lines[i].kind == .added { i += 1 }
        let count = min(addStart - delStart, i - addStart)
        for k in 0..<count { pairs.append((delStart + k, addStart + k)) }
    }
    return pairs
}
