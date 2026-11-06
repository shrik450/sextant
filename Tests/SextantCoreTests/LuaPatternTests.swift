import Foundation
import Testing
@testable import SextantCore

@Suite struct LuaPatternTests {
    /// Patterns, texts, and where LuaJIT 2.1's `string.find` finds each pattern, as UTF-8
    /// offsets.
    static let found: [(pattern: String, text: String, match: Range<Int>?)] = [
        ("^[A-Z_][a-zA-Z0-9_]*", "Allocator", 0..<9),
        ("^[A-Z_][a-zA-Z0-9_]*", "allocator", nil),
        ("^[A-Z_][a-zA-Z0-9_]*", "_x", 0..<2),
        ("^[A-Z][A-Z_0-9]+$", "MAX_LEN", 0..<7),
        ("^[A-Z][A-Z_0-9]+$", "Max", nil),
        ("^[A-Z][A-Z_0-9]+$", "A", nil),
        ("^[A-Z][A-Z_0-9]+$", "AB c", nil),
        ("^//!", "//! doc", 0..<3),
        ("^//!", "// plain", nil),
        ("^//!", " //! not at start", nil),
        ("^[%u@][%u%d_]+$", "CMAKE_CXX_STANDARD", 0..<18),
        ("^[%u@][%u%d_]+$", "@VAR1", 0..<5),
        ("^[%u@][%u%d_]+$", "project", nil),
        ("^[%u@][%u%d_]+$", "X", nil),
        ("^#!/", "#!/usr/bin/env cmake", 0..<3),
        ("^#!/", "# comment", nil),
        ("%a+", "12abc34", 2..<5),
        ("%A+", "abc12de", 3..<5),
        ("%d+", "x2024y", 1..<5),
        ("%D+", "123abc", 3..<6),
        ("%l+", "ABcdE", 2..<4),
        ("%L+", "abCDe", 2..<4),
        ("%u+", "abCDe", 2..<4),
        ("%U+", "ABcdE", 2..<4),
        ("%s+", "a \t\nb", 1..<4),
        ("%S+", "  ab  ", 2..<4),
        ("%w+", "--a1_b", 2..<4),
        ("%W+", "ab-+cd", 2..<4),
        ("%x+", "zzBEEFg", 2..<6),
        ("%X+", "beefZZ", 4..<6),
        ("%p+", "ab.,;cd", 2..<5),
        ("%P+", ".,ab;", 2..<4),
        ("%c+", "a\u{1}\u{2}b", 1..<3),
        ("%C+", "\u{1}ab\u{2}", 1..<3),
        ("%g+", "  ab  ", 2..<4),
        ("%z", "a\u{0}b", 1..<2),
        ("%.", "a.b", 1..<2),
        ("%%", "50%", 2..<3),
        ("%]", "a]b", 1..<2),
        ("%-", "a-b", 1..<2),
        ("%^", "a^b", 1..<2),
        ("%$", "a$b", 1..<2),
        ("[abc]+", "xxbcay", 2..<5),
        ("[^abc]+", "abxyzc", 2..<5),
        ("[a-f]+", "zzbadz", 2..<5),
        ("[%d_]+", "ab1_2c", 2..<5),
        ("[]]", "a]", 1..<2),
        ("[^]]+", "]ab]", 1..<3),
        ("[a-]+", "x-a-y", 1..<4),
        ("[-a]+", "x-a-y", 1..<4),
        ("[%a-]+", "1a-b2", 1..<4),
        ("[a%-z]+", "b-az", 1..<4),
        ("[%]]", "x]", 1..<2),
        ("a*", "bbb", 0..<0),
        ("a*", "aab", 0..<2),
        ("ba*", "xbaaa", 1..<5),
        ("a+", "bbb", nil),
        ("a-b", "aaab", 0..<4),
        ("a-", "aaa", 0..<0),
        ("a?b", "xab", 1..<3),
        ("a?b", "xb", 1..<2),
        ("x*y", "xxxz", nil),
        ("[%w_]-%.", "abc.def", 0..<4),
        (".-b", "aaabab", 0..<4),
        (".*b", "aaabab", 0..<6),
        ("^a", "ba", nil),
        ("a$", "ab", nil),
        ("a$", "ba", 1..<2),
        ("^$", "", 0..<0),
        ("^$", "a", nil),
        ("$", "abc", 3..<3),
        ("b$c", "ab$c", 1..<4),
        ("a^", "a^", 0..<2),
        ("", "abc", 0..<0),
        ("(a)(b)", "xab", 1..<3),
        ("()a", "ba", 1..<2),
        ("(%a+)%s+%1", "say hello hello", 4..<15),
        ("(%a+)%s+%1", "say hello world", nil),
        ("([\"'])(.-)%1", "x = 'it\"s' y", 4..<10),
        ("(a(b)c)%2", "abcb", 0..<4),
        ("(()a)", "ba", 1..<2),
        ("%b()", "f(a(b)c) d", 1..<8),
        ("%b()", "f(a(b c", nil),
        ("%b{}x", "{a}{b}x", 3..<7),
        ("%f[%w]%w+", "  hello", 2..<7),
        ("%f[%a]THE%f[%A]", "THE (quick)", 0..<3),
        ("%f[%a]THE%f[%A]", "THEN", nil),
        ("%f[%z]", "abc", 3..<3),
        ("%f[%l]%l+", "ABcd", 2..<4),
        ("%a+", "caféx", 0..<3),
        ("[^%w]+", "caféx", 3..<5),
        (".", "é", 0..<1),
    ]

    @Test func findsWhatLuaJITFinds() {
        for (pattern, text, match) in Self.found {
            let p = LuaPattern(pattern)
            #expect(p != nil, "\(pattern)")
            #expect(p?.firstMatch(in: text) == match, "\(pattern) in \(text)")
        }
    }

    @Test func rejectsWhatLuaRejects() {
        for pattern in ["%", "[a", "[^", "(a", "%1", "(a%1)", "%b", "%ba", "%f", "%fa", "[%", "((a)%1)", "%0", "(a))"] {
            #expect(LuaPattern(pattern) == nil, "\(pattern)")
        }
    }

    @Test func findsAPatternWithoutSpecialsAsItIsWritten() {
        #expect(LuaPattern("a)")?.firstMatch(in: "(a) b") == 1..<3)
        #expect(LuaPattern("]x")?.firstMatch(in: "a]x") == 1..<3)
    }
}
