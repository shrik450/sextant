import Foundation
import Testing
@testable import SextantCore

/// A small file and the definitions its grammar's tags query should find in it.
struct TagsSample: Sendable, CustomTestStringConvertible {
    var path: String
    var text: String
    /// Each definition as "<kind> <name>", in document order.
    var definitions: [String]

    var testDescription: String { path }
}

/// Runs Sextant's own tags queries against the real grammars the dev shell points
/// `SEXTANT_SYNTAX` at.
@Suite struct TagsTests {
    let runtime = SyntaxRuntime.shared

    func definitions(_ path: String, _ text: String) throws -> [Symbol] {
        let lang = try #require(runtime?.language(forPath: path), "\(path) has no grammar")
        #expect(lang.hasTags, "\(path) has no tags query")
        return lang.symbols(text).filter(\.isDefinition)
    }

    static let samples: [TagsSample] = [
        TagsSample(path: "a.zig", text: """
            const std = @import("std");
            pub var count: u32 = 0;

            pub const Point = struct {
                x: f32,
                pub const zero: Point = .{ .x = 0 };

                pub fn len(self: Point) f32 {
                    const sq = self.x * self.x;
                    return std.math.sqrt(sq);
                }
            };

            const Color = enum { red };
            const Value = union(enum) { int: i64 };
            const Failure = error{Bad};

            pub fn List(comptime T: type) type {
                return struct {
                    items: []T,
                    pub fn append(self: *@This(), item: T) void {}
                };
            }

            fn helper() void {}

            test "point length" {
                const p = Point.zero;
            }
            """, definitions: [
                "constant std", "variable count", "struct Point", "field x", "constant zero", "method len",
                "enum Color", "field red", "union Value", "field int", "enum Failure",
                "type List", "field items", "method append", "function helper", "test point length",
            ]),
        TagsSample(path: "deploy.sh", text: """
            NAME=demo
            export TARGET="/srv"
            build() {
              local out=1
              make "$out"
            }
            function deploy {
              build
            }
            """, definitions: ["variable NAME", "variable TARGET", "function build", "function deploy"]),
        TagsSample(path: "config.fish", text: """
            set -gx EDITOR vim
            function greet --description 'Say hi'
                set -l name $argv[1]
                echo $name
            end
            alias ll 'ls -l'
            """, definitions: ["variable EDITOR", "function greet", "function ll"]),
        TagsSample(path: "Shapes.kt", text: """
            package demo

            typealias Name = String
            const val LIMIT = 3

            interface Shape { fun area(): Double }

            data class Point(val x: Double, var y: Double) : Shape {
                val norm: Double = x
                override fun area(): Double = 0.0
                companion object Factory { fun origin() = Point(0.0, 0.0) }
            }

            enum class Color { RED, GREEN }

            object Registry { fun register(p: Point) {} }

            fun main() {
                val p = Point.origin()
            }
            """, definitions: [
                "type Name", "property LIMIT", "interface Shape", "method area", "class Point", "property x",
                "property y", "property norm", "method area", "object Factory", "method origin", "enum Color",
                "constant RED", "constant GREEN", "object Registry", "method register", "function main",
            ]),
        TagsSample(path: "Shape.hs", text: """
            module Data.Shape where

            data Shape = Circle Double | Rect { width :: Double }

            newtype Name = Name String

            class Describe a where
              describe :: a -> String

            area :: Shape -> Double
            area (Circle r) = r
            area (Rect w) = w

            instance Show Name where
              show _ = "name"

            total xs = sum (map area xs)
              where helper = 1

            limit = 3
            """, definitions: [
                "module Data.Shape", "type Shape", "constructor Circle", "constructor Rect", "field width",
                "type Name", "constructor Name", "interface Describe", "method describe", "function area",
                "function total", "function limit",
            ]),
        TagsSample(path: "shapes.erl", text: """
            -module(shapes).
            -define(LIMIT, 3).
            -record(point, {x = 0}).
            -type shape() :: {circle, float()}.

            area({circle, R}) -> R * R;
            area({square, S}) -> S * S.

            start() -> helper(?LIMIT).

            %% Returns its argument.
            -spec helper(integer()) -> integer().
            helper(N) -> N.
            """, definitions: [
                "module shapes", "macro LIMIT", "struct point", "type shape", "function area",
                "function start", "function helper",
            ]),
        TagsSample(path: "core.clj", text: """
            (ns my.app.core)
            (def limit 3)
            (defn greet [name] (let [x 1] (str name)))
            (defn- helper [x] x)
            (defmacro unless [c & body] nil)
            (defprotocol Shape (area [this]))
            (defrecord Circle [r])
            (defmulti draw :kind)
            """, definitions: [
                "module my.app.core", "variable limit", "function greet", "function helper", "macro unless",
                "interface Shape", "class Circle", "function draw",
            ]),
        TagsSample(path: "shapes.jl", text: """
            module Shapes

            const LIMIT = 3

            abstract type Shape end

            struct Circle <: Shape
                r::Float64
            end

            function area(c::Circle)
                c.r^2
            end

            function Base.show(io::IO, c::Circle)
            end

            perimeter(c::Circle) = 2c.r

            macro twice(ex)
                :($ex; $ex)
            end

            end
            """, definitions: [
                "module Shapes", "constant LIMIT", "type Shape", "struct Circle", "function area",
                "function show", "function perimeter", "macro twice",
            ]),
        TagsSample(path: "lib.scm", text: """
            (define limit 3)
            (define (square x) (* x x))
            (define-syntax swap! (syntax-rules () ((_ a b) b)))
            (define-record-type point (make-point x) point? (x point-x))
            """, definitions: ["variable limit", "function square", "macro swap!", "struct point"]),
        TagsSample(path: "shop.proto", text: """
            syntax = "proto3";
            package shop.v1;
            message Order {
              string id = 1;
              enum Status { UNKNOWN = 0; }
              oneof payment { string card = 2; }
            }
            service Orders {
              rpc Get(Order) returns (Order);
            }
            """, definitions: [
                "module shop.v1", "class Order", "field id", "enum Status", "constant UNKNOWN", "field payment",
                "field card", "interface Orders", "method Get",
            ]),
        TagsSample(path: "schema.graphql", text: """
            scalar Date
            type Order implements Node { id: ID! }
            interface Node { id: ID! }
            enum Status { PAID }
            input OrderInput { total: Float }
            union Result = Order
            fragment OrderFields on Order { id }
            query GetOrder { order { ...OrderFields } }
            """, definitions: [
                "type Date", "class Order", "field id", "interface Node", "field id", "enum Status",
                "constant PAID", "class OrderInput", "field total", "union Result", "fragment OrderFields",
                "function GetOrder",
            ]),
        TagsSample(path: "site.css", text: """
            :root { --accent: red; }
            .button, .link:hover { color: var(--accent); }
            #main > .card { padding: 0; }
            .nav .menu > .item { margin: 0; }
            @keyframes spin { from { opacity: 0; } }
            h1 { margin: 0; }
            """, definitions: [
                "variable --accent", "class button", "class link", "id main", "class card", "class nav",
                "class menu", "class item", "keyframes spin",
            ]),
        TagsSample(path: "Makefile", text: """
            CC := cc
            define compile
            \t$(CC) $(1)
            endef
            .PHONY: all
            all: build
            build: main.o
            \t$(call compile,main.c)

            """, definitions: ["variable CC", "macro compile", "target all", "target build"]),
        TagsSample(path: "justfile", text: """
            version := "1.0"
            alias b := build
            build target="debug": fmt
                cargo build --profile {{target}}
            fmt:
                cargo fmt
            mod tools

            """, definitions: ["variable version", "function b", "function build", "function fmt", "module tools"]),
        TagsSample(path: "README.md", text: """
            # Title

            ## Install

            ### Deep

            ## Usage
            """, definitions: ["heading Title", "heading Install", "heading Deep", "heading Usage"]),
        TagsSample(path: "ci.yaml", text: """
            jobs:
              build:
                runs-on: ubuntu-latest
              test:
                needs: build
            defaults: &base
              shell: bash
            """, definitions: [
                "property jobs", "property build", "property runs-on", "property test", "property needs",
                "property defaults", "anchor base", "property shell",
            ]),
        TagsSample(path: "Cargo.toml", text: """
            title = "x"
            [package]
            name = "demo"
            [[bin]]
            path = "main.rs"
            """, definitions: ["property title", "table package", "property name", "table bin", "property path"]),
        TagsSample(path: "CMakeLists.txt", text: """
            set(SOURCES main.c)
            function(add_demo name)
              add_executable(${name} ${SOURCES})
            endfunction()
            macro(log msg)
              message(${msg})
            endmacro()
            add_library(core STATIC core.c)
            """, definitions: ["variable SOURCES", "function add_demo", "macro log", "target core"]),
        TagsSample(path: "schema.sql", text: """
            CREATE TABLE users (id INT, name TEXT);
            CREATE VIEW active_users AS SELECT * FROM users;
            CREATE INDEX users_name_idx ON users (name);
            CREATE FUNCTION add_one(x INT) RETURNS INT AS $$ SELECT x + 1 $$ LANGUAGE SQL;
            """, definitions: [
                "table users", "field id", "field name", "view active_users", "index users_name_idx",
                "function add_one",
            ]),
        TagsSample(path: "plugin.vim", text: """
            let g:loaded_demo = 1
            function! s:Helper(x) abort
              let l:y = a:x
              return l:y
            endfunction
            command! -nargs=0 Demo call s:Helper(1)
            """, definitions: ["variable g:loaded_demo", "function s:Helper", "function Demo"]),
        TagsSample(path: "Dockerfile", text: """
            ARG BASE=alpine
            FROM golang:1.22 AS builder
            ENV CGO_ENABLED=0
            FROM ${BASE}
            COPY --from=builder /app /app
            """, definitions: ["variable BASE", "target builder", "variable CGO_ENABLED"]),
    ]

    @Test(arguments: samples)
    func findsDefinitions(_ sample: TagsSample) throws {
        let found = try definitions(sample.path, sample.text).map { "\($0.kind) \($0.name)" }
        #expect(found == sample.definitions)
    }

    @Test func aFunctionWithSeveralEquationsIsDefinedOnceAtItsSignature() throws {
        let text = "area :: Shape -> Double\narea (Circle r) = r\narea (Rect w) = w\n"
        let area = try definitions("a.hs", text).filter { $0.name == "area" }
        #expect(area.map(\.nameLine) == [0])
    }

    @Test func aGenericZigTypeKeepsItsMethodsInTheOutline() throws {
        let text = """
            pub fn List(comptime T: type) type {
                return struct {
                    pub fn append(self: *@This(), item: T) void {
                        const n = 1;
                    }
                };
            }
            """
        let names = outlineDefinitions(try definitions("a.zig", text)).map(\.name)
        #expect(names == ["List", "append"])
    }

    @Test func definitionsSpanTheirBodies() throws {
        let vim = try definitions("a.vim", "function! s:Helper(x) abort\n  return a:x\nendfunction\n")
        #expect(vim.first?.lines == 0...2)
        let kotlin = try definitions("a.kt", "val greeting = listOf(\n    1,\n)\n")
        #expect(kotlin.first?.lines == 0...2)
        let markdown = try definitions("a.md", "# Title\n\n## Install\n\nSteps.\n\n## Usage\n")
        #expect(markdown.map(\.lines) == [0...6, 2...5, 6...6])
    }
}
