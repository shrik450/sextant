import Foundation
import Testing
@testable import SextantCore

/// Groups names by what the locals say they name, without a grammar.
@Suite struct ResolveNamesTests {
    /// Lays names out in a text one after another, a space apart, and returns each one's range.
    func names(_ spellings: [String]) -> [(range: NSRange, spelling: String)] {
        var at = 0
        return spellings.map { s in
            defer { at += s.utf16.count + 1 }
            return (NSRange(location: at, length: s.utf16.count), s)
        }
    }

    func range(_ names: [(range: NSRange, spelling: String)], _ i: Int) -> NSRange { names[i].range }

    func span(_ names: [(range: NSRange, spelling: String)], _ from: Int, _ to: Int) -> NSRange {
        NSRange(location: names[from].range.location, length: NSMaxRange(names[to].range) - names[from].range.location)
    }

    @Test func withoutLocalsNamesSpelledAlikeShareAnID() {
        let n = names(["a", "b", "a", "c", "b"])
        let found = resolveNames(n, locals: nil)
        #expect(found.ids == [0, 1, 0, 2, 1])
        #expect(found.locals == 0)
    }

    @Test func aDefinitionInAnInnerScopeShadowsTheOuterOne() {
        let n = names(["x", "x", "x", "x", "x"])
        var locals = LocalCaptures()
        locals.scopes = [.init(range: span(n, 0, 4)), .init(range: span(n, 2, 3))]
        locals.definitions = [.init(range: range(n, 0)), .init(range: range(n, 2))]
        locals.references = (0..<5).map { range(n, $0) }
        let ids = resolveNames(n, locals: locals).ids
        #expect(ids[0] == ids[1] && ids[1] == ids[4])
        #expect(ids[2] == ids[3])
        #expect(ids[0] != ids[2])
    }

    @Test func aReferenceFindsADefinitionLaterInItsScope() {
        let n = names(["n", "n", "n"])
        var locals = LocalCaptures()
        locals.scopes = [.init(range: span(n, 0, 2))]
        locals.definitions = [.init(range: range(n, 1))]
        locals.references = [range(n, 0), range(n, 2)]
        let ids = resolveNames(n, locals: locals).ids
        #expect(Set(ids).count == 1)
    }

    @Test func aParentDefinitionBelongsToTheScopeAroundItsOwn() {
        let n = names(["outer", "inner", "inner", "inner"])
        var locals = LocalCaptures()
        locals.scopes = [.init(range: span(n, 0, 3)), .init(range: span(n, 1, 2))]
        locals.definitions = [.init(range: range(n, 1), placement: .parent)]
        locals.references = [range(n, 2), range(n, 3)]
        let found = resolveNames(n, locals: locals)
        #expect(found.ids[1] == found.ids[2] && found.ids[2] == found.ids[3])
        #expect(found.ids[1] < found.locals)
    }

    @Test func aNearestDefinitionJoinsOneAroundItElseStartsItsOwn() {
        let n = names(["x", "x", "y", "y", "x"])
        var locals = LocalCaptures()
        locals.scopes = [.init(range: span(n, 0, 4)), .init(range: span(n, 1, 3))]
        locals.definitions = [.init(range: range(n, 0)), .init(range: range(n, 1), placement: .nearest), .init(range: range(n, 2), placement: .nearest)]
        locals.references = [range(n, 3), range(n, 4)]
        let ids = resolveNames(n, locals: locals).ids
        #expect(ids[0] == ids[1] && ids[1] == ids[4])
        #expect(ids[2] == ids[3])
        #expect(ids[2] != ids[0])
    }

    @Test func aScopeThatDoesNotInheritSeesNothingAroundIt() {
        let n = names(["v", "v", "v"])
        var locals = LocalCaptures()
        locals.scopes = [.init(range: span(n, 0, 2)), .init(range: span(n, 1, 1), inherits: false)]
        locals.definitions = [.init(range: range(n, 0))]
        locals.references = [range(n, 1), range(n, 2)]
        let found = resolveNames(n, locals: locals)
        #expect(found.ids[0] == found.ids[2])
        #expect(found.ids[1] != found.ids[0])
        #expect(found.ids[1] >= found.locals)
    }

    @Test func aNonlocalNameNeverRefersToALocal() {
        let n = names(["len", "len", "len"])
        var locals = LocalCaptures()
        locals.scopes = [.init(range: span(n, 0, 2))]
        locals.definitions = [.init(range: range(n, 0))]
        locals.references = [range(n, 1), range(n, 2)]
        locals.nonlocal = [range(n, 2)]
        let ids = resolveNames(n, locals: locals).ids
        #expect(ids[0] == ids[1])
        #expect(ids[2] != ids[0])
    }

    @Test func namesOutsideEveryScopeAreSharedBySpelling() {
        let n = names(["T", "a", "T", "a", "T"])
        var locals = LocalCaptures()
        locals.scopes = [.init(range: span(n, 1, 3))]
        locals.definitions = [.init(range: range(n, 0)), .init(range: range(n, 1))]
        locals.references = [range(n, 2), range(n, 3), range(n, 4)]
        let found = resolveNames(n, locals: locals)
        #expect(found.ids[0] == found.ids[2] && found.ids[2] == found.ids[4])
        #expect(found.ids[0] >= found.locals)
        #expect(found.ids[1] == found.ids[3])
        #expect(found.ids[1] < found.locals)
    }
}

/// A small file, and names in it with the lines of everything each one names.
struct LocalsSample: Sendable, CustomTestStringConvertible {
    struct Expectation: Sendable {
        /// The name, the first one spelled this way on `line` unless `nth` says otherwise.
        var name: String
        /// The one-based line it's on.
        var line: Int
        var nth = 0
        /// The one-based lines of every name that names the same thing, once for each name.
        var lines: [Int]
    }

    var path: String
    var text: String
    var expectations: [Expectation]

    var testDescription: String { path }
}

/// Runs Sextant's own locals queries against the real grammars the dev shell points
/// `SEXTANT_SYNTAX` at.
@Suite struct LocalsTests {
    let runtime = SyntaxRuntime.shared

    func index(_ path: String, _ text: String) throws -> (NameIndex, [String]) {
        let lang = try #require(runtime?.language(forPath: path), "\(path) has no grammar")
        #expect(lang.hasLocals, "\(path) has no locals query")
        let lines = text.components(separatedBy: "\n")
        return (lang.names(of: lines, tokens: tokensPerLine(lang.tokens(text), lines: lines)), lines)
    }

    static func e(_ name: String, _ line: Int, nth: Int = 0, _ lines: [Int]) -> LocalsSample.Expectation {
        .init(name: name, line: line, nth: nth, lines: lines)
    }

    static let samples: [LocalsSample] = [
        LocalsSample(path: "a.zig", text: """
            const Point = struct {
                x: f32,
                fn len(self: Point, k: f32) f32 {
                    var total: f32 = 0;
                    for (items, 0..) |item, i| {
                        total += item * k;
                    }
                    const r = foo() catch |e| return e;
                    blk: { break :blk 1; }
                    return self.x + total + r + i;
                }
            };
            fn other(total: f32) f32 { return total; }
            """, expectations: [
                e("total", 4, [4, 6, 10]), e("item", 5, [5, 6]), e("x", 2, [2, 10]), e("k", 3, [3, 6]),
                e("e", 8, [8, 8]), e("blk", 9, [9, 9]), e("total", 13, [13, 13]), e("self", 3, [3, 10]),
            ]),
        LocalsSample(path: "a.swift", text: """
            struct S {
                var count = 0
                func run(_ x: Int, label y: Int) -> Int {
                    let a = x + y
                    if let d = opt { print(d) }
                    guard let g = opt else { return 0 }
                    for (i, item) in list.enumerated() { print(i, item) }
                    let k = list.map { p in p + a }
                    func inner(z: Int) -> Int { z + a }
                    self.count += a + g + inner(z: 1)
                    return count
                }
                init(count: Int) { self.count = count }
            }
            """, expectations: [
                e("a", 4, [4, 8, 9, 10]), e("count", 2, [2, 10, 11, 13]), e("count", 13, [13, 13]),
                e("d", 5, [5, 5]), e("g", 6, [6, 10]), e("item", 7, [7, 7]), e("p", 8, [8, 8]),
                e("inner", 9, [9, 10]), e("z", 9, [9, 9]), e("x", 3, [3, 4]),
            ]),
        LocalsSample(path: "a.c", text: """
            struct point { int x; };
            static int counter = 0;
            int add(int a, struct point *p) {
                int sum = a + p->x;
                for (int i = 0; i < 4; i++) { sum += i; }
                { int a = 2; sum += a; }
                return sum + counter;
            }
            int x(void) { return counter; }
            """, expectations: [
                e("a", 3, [3, 4]), e("a", 6, [6, 6]), e("sum", 4, [4, 5, 6, 7]), e("i", 5, [5, 5, 5, 5]),
                e("x", 1, [1, 4, 9]), e("counter", 2, [2, 7, 9]), e("p", 3, [3, 4]),
            ]),
        LocalsSample(path: "a.cpp", text: """
            class K {
              int m;
              int run(int a, const std::vector<int>& vs) {
                auto sum = a + m;
                for (auto& v : vs) { sum += v; }
                auto f = [&sum](int p) { return p + sum; };
                return f(1) + this->m;
              }
            };
            """, expectations: [
                e("sum", 4, [4, 5, 6, 6]), e("v", 5, [5, 5]), e("vs", 3, [3, 5]), e("m", 2, [2, 4, 7]), e("f", 6, [6, 7]),
            ]),
        LocalsSample(path: "a.go", text: """
            type T struct{ n int }
            func (t *T) Run(a int) int {
            \tx := a + t.n
            \tfor i, v := range xs { x += i + v }
            \tif w := x; w > 0 { x = w }
            \tf := func(p int) int { return p + x }
            \treturn f(x) + len(T{n: x}.n)
            }
            """, expectations: [
                e("x", 3, [3, 4, 5, 5, 6, 7, 7]), e("t", 2, [2, 3]), e("n", 1, [1, 3, 7, 7]), e("w", 5, [5, 5, 5]), e("p", 6, [6, 6]),
            ]),
        LocalsSample(path: "a.rs", text: """
            struct P { x: i32 }
            fn run(p: &P, (b, c): (i32, i32)) -> i32 {
                let d = p.x + b;
                let mut e = d;
                if let Some(f) = opt { e += f; }
                for (i, h) in v.iter().enumerate() { e += h + i; }
                let cl = |q: i32| q + e;
                fn inner(z: i32) -> i32 { z }
                match o { Some(m) => m, None => 0 };
                e + c + inner(1) + cl(1)
            }
            """, expectations: [
                e("e", 4, [4, 5, 6, 7, 10]), e("x", 1, [1, 3]), e("f", 5, [5, 5]), e("q", 7, [7, 7]), e("inner", 8, [8, 10]),
                e("m", 9, [9, 9]), e("c", 2, [2, 10]),
            ]),
        LocalsSample(path: "a.py", text: """
            LIMIT = 1
            class C:
                attr = 2
                def run(self, a, *args, b=1):
                    x = a + self.attr + LIMIT
                    for i, v in enumerate(args):
                        x += v
                    sq = [n * n for n in args]
                    def inner(r):
                        return r + x
                    return inner(x) + b
            def other(x):
                return x
            """, expectations: [
                e("x", 5, [5, 7, 10, 11]), e("n", 8, [8, 8, 8]), e("attr", 3, [3, 5]), e("LIMIT", 1, [1, 5]),
                e("inner", 9, [9, 11]), e("x", 12, [12, 13]), e("self", 4, [4, 5]),
            ]),
        LocalsSample(path: "a.ts", text: """
            export function run(a: number, { b, c: d }: Opts): number {
              const x = a + b + d;
              for (const item of list) { console.log(item, x); }
              const f = (p: number) => p + x;
              return x + f(1) + helper() + obj.x;
              function helper() { return b; }
            }
            """, expectations: [
                e("x", 2, [2, 3, 4, 5]), e("b", 1, [1, 2, 6]), e("d", 1, [1, 2]), e("item", 3, [3, 3]), e("helper", 5, [5, 6]),
            ]),
        LocalsSample(path: "a.js", text: """
            function run(a, [e]) {
              const { short } = a;
              try { go(e); } catch (err) { log(err, { short }); }
            }
            """, expectations: [e("short", 2, [2, 3]), e("err", 3, [3, 3]), e("e", 1, [1, 3])]),
        LocalsSample(path: "a.rb", text: """
            def run(a)
              x = a
              [1].each { |i| x += i }
              x
            end
            def other(a)
              a
            end
            """, expectations: [e("x", 2, [2, 3, 4]), e("a", 6, [6, 7]), e("i", 3, [3, 3])]),
        LocalsSample(path: "a.lua", text: """
            function M.run(a)
              local x = a
              for i, v in ipairs(t) do x = x + v end
              local function helper(p) return p + x end
              return helper(x)
            end
            """, expectations: [e("x", 2, [2, 3, 3, 4, 5]), e("helper", 4, [4, 5]), e("v", 3, [3, 3])]),
        LocalsSample(path: "a.nix", text: """
            { pkgs, ... }@args:
            let
              a = b + 1;
              b = 2;
              f = x: x + a;
            in
            { out = f b + args.pkgs + pkgs.hello; inherit a; }
            """, expectations: [e("b", 3, [3, 4, 7]), e("a", 3, [3, 5, 7]), e("pkgs", 1, [1, 7]), e("x", 5, [5, 5])]),
        LocalsSample(path: "A.java", text: """
            class A {
              int field;
              int run(int a, String... rest) {
                int x = a + field + this.field;
                for (String s : rest) { use(s, x); }
                java.util.function.Function<Integer, Integer> f = v -> v + x;
                return x;
              }
            }
            """, expectations: [e("x", 4, [4, 5, 6, 7]), e("field", 2, [2, 4, 4]), e("s", 5, [5, 5]), e("v", 6, [6, 6])]),
    ]

    @Test(arguments: samples)
    func localsGroupNamesByWhatTheyName(_ sample: LocalsSample) throws {
        let (index, lines) = try index(sample.path, sample.text)
        for x in sample.expectations {
            let text = lines[x.line - 1]
            let named = wholeWordMatches(of: x.name, in: text).compactMap { index.name(atLine: x.line - 1, range: $0) }
            let name = try #require(named.indices.contains(x.nth) ? named[x.nth] : nil, "\(x.name) isn't a name on line \(x.line)")
            let got = index.occurrences(of: name.binding).map { $0.line + 1 }
            #expect(got == x.lines, "\(x.name) on line \(x.line)")
        }
    }

    @Test func everyLocalsQueryCompiles() throws {
        struct Entry: Decodable {
            var name: String
            var fileTypes: [String]
        }
        let r = try #require(runtime)
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: r.directory.appendingPathComponent("languages.json")))
        for e in entries where FileManager.default.fileExists(atPath: r.directory.appendingPathComponent(e.name).appendingPathComponent("locals.scm").path) {
            let type = try #require(e.fileTypes.first, "\(e.name) has no file types")
            #expect(r.language(forPath: type)?.hasLocals == true, "\(e.name)'s locals query doesn't compile")
        }
    }

    @Test func everyGrammarListsItsKeywordNodes() throws {
        struct Entry: Decodable {
            var name: String
            var keywordNodes: [String]?
        }
        let r = try #require(runtime)
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: r.directory.appendingPathComponent("languages.json")))
        let generatedWhenBuilt: Set = ["sql"]
        for e in entries where !generatedWhenBuilt.contains(e.name) {
            #expect(e.keywordNodes != nil, "\(e.name) has no grammar.json to list keyword nodes from")
        }
        let cpp = try #require(entries.first { $0.name == "cpp" }?.keywordNodes)
        #expect(cpp.contains("auto") && cpp.contains("this") && !cpp.contains("identifier"))
    }

    @Test func namesLeaveOutKeywordsCommentsStringsAndUnderscores() throws {
        let (index, lines) = try index("a.go", """
            // count the things
            func f(s string) int { _ = "count"; return len(s) + count }
            """)
        #expect(index.name(atLine: 0, column: 4) == nil)
        let second = lines[1] as NSString
        #expect(index.name(atLine: 1, column: second.range(of: "func").location) == nil)
        #expect(index.name(atLine: 1, column: second.range(of: "_").location) == nil)
        #expect(index.name(atLine: 1, column: second.range(of: "\"count\"").location + 2) == nil)
        let count = try #require(index.name(atLine: 1, column: second.range(of: "count }").location))
        #expect(index.occurrences(of: count.binding).count == 1)
    }

    @Test func theCaretJustAfterANameIsOnIt() throws {
        let (index, lines) = try index("a.py", "def f(abc):\n    return abc\n")
        let line = lines[1] as NSString
        let at = line.range(of: "abc")
        #expect(index.name(atLine: 1, column: NSMaxRange(at))?.range == at)
        #expect(index.name(atLine: 1, column: at.location - 1) == nil)
    }

    @Test func aNameSpelledAsItsNodeTypeIsANameButAKeywordNodeIsNot() throws {
        for (path, text) in [("a.py", "identifier = 1\nprint(identifier)\n"), ("a.js", "let identifier = 1;\nf(identifier);\n"),
                             ("a.rs", "fn f(identifier: i32) -> i32 {\n    identifier\n}\n")] {
            let (index, lines) = try index(path, text)
            let first = try #require(index.name(atLine: 0, column: (lines[0] as NSString).range(of: "identifier").location), "\(path)")
            #expect(index.occurrences(of: first.binding).count == 2, "\(path)")
        }
        let (cpp, lines) = try index("a.cpp", "int f() {\n    auto total = 1;\n    return total;\n}\n")
        #expect(cpp.name(atLine: 1, column: (lines[1] as NSString).range(of: "auto").location) == nil)
        #expect(cpp.name(atLine: 1, column: (lines[1] as NSString).range(of: "total").location) != nil)
        let (rust, rustLines) = try index("a.rs", "impl P {\n    fn x(&self) -> i32 { self.x }\n}\n")
        #expect(rust.name(atLine: 1, column: (rustLines[1] as NSString).range(of: "self.x").location) == nil)
    }
}
