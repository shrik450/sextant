import Foundation
import Testing
@testable import RevueCore

/// Runs against the real grammars the dev shell points `REVUE_SYNTAX` at.
@Suite struct SyntaxTests {
    let runtime = SyntaxRuntime.shared

    func kinds(_ lang: SyntaxLanguage, _ text: String) -> [(String, TokenKind)] {
        let ns = text as NSString
        return lang.tokens(text).map { (ns.substring(with: $0.range), $0.kind) }
    }

    @Test func picksGrammarsByNameAndExtension() throws {
        let r = try #require(runtime, "REVUE_SYNTAX must point at the syntax runtime")
        #expect(r.language(forPath: "src/main.rs")?.name == "rust")
        #expect(r.language(forPath: "web/app.tsx")?.name == "tsx")
        #expect(r.language(forPath: "web/app.ts")?.name == "typescript")
        #expect(r.language(forPath: "build/Makefile")?.name == "make")
        #expect(r.language(forPath: "go.mod")?.name == "gomod")
        #expect(r.language(forPath: "notes.unknownext") == nil)
    }

    @Test func highlightsKeywordsStringsAndCommentsAcrossLines() throws {
        let swift = try #require(runtime?.language(forPath: "a.swift"))
        let text = "/* open\n still */ func f() -> String { \"hi\" } // done\n"
        let k = kinds(swift, text)
        #expect(k.contains { $0.0 == "/* open\n still */" && $0.1 == .comment })
        #expect(k.contains { $0.0 == "func" && $0.1 == .keyword })
        #expect(k.contains { $0.0.contains("hi") && $0.1 == .string })
        #expect(k.contains { $0.0 == "// done" && $0.1 == .comment })
    }

    @Test func everyGrammarLoadsWithItsQueries() throws {
        let r = try #require(runtime)
        let samples = ["a.rs", "a.go", "a.py", "a.ts", "a.tsx", "a.js", "a.c", "a.cpp", "a.java", "a.kt", "a.cs", "a.rb",
                       "a.php", "a.swift", "a.nix", "a.yaml", "a.json", "a.toml", "a.html", "a.css", "a.sql", "a.sh",
                       "a.lua", "a.ex", "a.hs", "a.scala", "a.zig", "a.md", "Dockerfile", "a.dart", "a.ml", "a.xml"]
        for s in samples {
            let lang = r.language(forPath: s)
            #expect(lang != nil, "\(s) has no grammar")
            #expect(lang?.highlightsQuery != nil, "\(s) has no highlights query")
        }
    }

    @Test func tagsFindDefinitionsAndReferences() throws {
        let rust = try #require(runtime?.language(forPath: "lib.rs"))
        let text = """
        struct Cache { n: u64 }

        impl Cache {
            fn get(&self) -> u64 {
                helper(self.n)
            }
        }

        fn helper(x: u64) -> u64 { x }
        """
        let syms = rust.symbols(text)
        let defs = syms.filter(\.isDefinition)
        #expect(defs.contains { $0.name == "Cache" && $0.lines.lowerBound == 0 })
        let get = try #require(defs.first { $0.name == "get" })
        #expect(get.kind == "method" && get.lines == 3...5)
        #expect(defs.contains { $0.name == "helper" && $0.kind == "function" && $0.lines.lowerBound == 8 })
        #expect(syms.contains { $0.name == "helper" && !$0.isDefinition && $0.lines.lowerBound == 4 })
    }

    @Test func membersSpanTheirOwnLinesNotTheTypeAroundThem() throws {
        let swift = try #require(runtime?.language(forPath: "a.swift"))
        let text = """
        struct Parser {
            var tokens: [String]

            func next() -> String? {
                nil
            }
        }
        """
        let defs = swift.symbols(text).filter(\.isDefinition)
        #expect(defs.first { $0.name == "Parser" }?.lines == 0...6)
        #expect(defs.first { $0.name == "tokens" }?.lines == 1...1)
        #expect(defs.first { $0.name == "next" }?.lines == 3...5)
    }
}

@Test func tokensSplitAcrossLinesStayInOrder() {
    let lines = ["let a = 1 /* x", "still */ b", "", "c"]
    let toks = [
        Token(range: NSRange(location: 0, length: 3), kind: .keyword),
        Token(range: NSRange(location: 10, length: 13), kind: .comment),
        Token(range: NSRange(location: 8, length: 1), kind: .number),
        Token(range: NSRange(location: 27, length: 1), kind: .variable),
    ]
    let per = tokensPerLine(toks, lines: lines)
    #expect(per[0] == [Token(range: NSRange(location: 0, length: 3), kind: .keyword),
                       Token(range: NSRange(location: 8, length: 1), kind: .number),
                       Token(range: NSRange(location: 10, length: 4), kind: .comment)])
    #expect(per[1] == [Token(range: NSRange(location: 0, length: 8), kind: .comment)])
    #expect(per[2].isEmpty)
    #expect(per[3] == [Token(range: NSRange(location: 0, length: 1), kind: .variable)])
}
