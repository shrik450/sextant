#!/usr/bin/env bash
#
# Builds a repository exercising everything Revue has to render.
#
# Usage: make-fixture.sh <dir>
#
# The repository covers languages, renames, binary files, mode changes, deletions, CRLF, tabs,
# unicode, missing trailing newlines, long lines, lock files, a feature branch with a merge,
# stashes, and staged, unstaged and untracked working-tree changes.

set -euo pipefail
dir=$1
rm -rf "$dir"
mkdir -p "$dir"
cd "$dir"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Ada Lovelace" GIT_AUTHOR_EMAIL="ada@example.com"
export GIT_COMMITTER_NAME="Ada Lovelace" GIT_COMMITTER_EMAIL="ada@example.com"
t=1767225600

#######################################
# Edits a file in place with sed, portably (BSD and GNU sed disagree on -i).
# Arguments:
#   Sed script.
#   File to edit.
#######################################
edit() { sed "$1" "$2" > "$2.tmp" && cat "$2.tmp" > "$2" && rm "$2.tmp"; }
commit() { GIT_AUTHOR_DATE="@$t +0000" GIT_COMMITTER_DATE="@$t +0000" git commit -q "$@"; t=$((t + 3600)); }

git init -q -b main .
git config core.autocrlf false
mkdir -p src web scripts docs

cat > src/parser.swift <<'EOF'
import Foundation

/// Parses a list of tokens.
struct Parser {
    var tokens: [String]
    var index = 0

    mutating func next() -> String? {
        guard index < tokens.count else { return nil }
        defer { index += 1 }
        return tokens[index]
    }

    func peek() -> String? {
        index < tokens.count ? tokens[index] : nil
    }
}

func parse(_ input: String) -> [String] {
    input.split(separator: " ").map(String.init)
}
EOF

cat > src/lib.rs <<'EOF'
use std::collections::HashMap;

/* Block comment
   spanning lines */
#[derive(Debug, Clone)]
pub struct Cache<'a> {
    entries: HashMap<&'a str, u64>,
}

impl<'a> Cache<'a> {
    pub fn new() -> Self {
        Self { entries: HashMap::new() }
    }

    pub fn get(&self, key: &str) -> Option<u64> {
        self.entries.get(key).copied()
    }
}
EOF

cat > web/app.ts <<'EOF'
import { render } from "./render";

export interface User {
  id: number;
  name: string;
}

export async function load(id: number): Promise<User> {
  const res = await fetch(`/api/users/${id}`);
  return res.json();
}
EOF

cat > scripts/build.py <<'EOF'
#!/usr/bin/env python3
"""Build script."""
import sys

def main(argv):
    if len(argv) < 2:
        print("usage: build.py <target>")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
EOF

cat > go.mod <<'EOF'
module example.com/fixture

go 1.22
EOF

cat > main.go <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("hello")
}
EOF

printf 'line one\r\nline two\r\nline three\r\n' > docs/windows.txt
printf 'no trailing newline' > docs/nonl.txt
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR' > docs/logo.png
cat > README.md <<'EOF'
# Fixture

A repository for exercising **Revue**.

- item one
- item two
EOF
cat > old-name.c <<'EOF'
#include <stdio.h>

int add(int a, int b) {
    return a + b;
}

int main(void) {
    printf("%d\n", add(1, 2));
    return 0;
}
EOF
cat > deploy.sh <<'EOF'
#!/bin/sh
echo "deploying $1"
EOF
seq 1 200 | sed 's/^/config line /' > config.txt
git add -A
commit -m "Initial commit"

edit 's/    func peek() -> String? {/    func peek(offset: Int = 0) -> String? {/' src/parser.swift
edit 's/        index < tokens.count ? tokens\[index\] : nil/        index + offset < tokens.count ? tokens[index + offset] : nil/' src/parser.swift
cat >> src/parser.swift <<'EOF'

extension Parser {
    /// Returns all remaining tokens.
    mutating func rest() -> [String] {
        var out: [String] = []
        while let t = next() { out.append(t) }
        return out
    }
}
EOF
edit 's/u64/usize/g' src/lib.rs
edit 's/config line 100$/config line 100 (changed)/' config.txt
edit 's/config line 150$/config line 150 (changed)/' config.txt
commit -am "Teach the parser to peek ahead" -m "Adds an offset to peek() and a rest() helper.

Also switches the cache to usize and tweaks config."

git mv old-name.c src/math.c
edit 's/return a + b;/return a + b; \/\/ sum/' src/math.c
chmod +x deploy.sh
git rm -q docs/nonl.txt
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x01' > docs/logo.png
cat > src/tabs.go <<'EOF'
package main

func tabs() {
	if true {
		println("tabbed")	// trailing comment
	}
}
EOF
git add -A
commit -m "Move math into src, make deploy executable"

awk 'BEGIN {
  print "// Ünïcödé — 日本語 — emoji 🎉"
  printf "const LONG = ["
  for (i = 0; i < 120; i++) printf "%s\"item-%d\"", (i ? ", " : ""), i
  print "];"
}' > web/long.js
git add -A
commit -m "Add long line fixture"

awk 'BEGIN {
  printf "{\n  \"lockfileVersion\": 3,\n  \"packages\": {\n"
  for (i = 0; i < 400; i++)
    printf "    \"node_modules/pkg%d\": {\n      \"version\": \"1.0.%d\"\n    }%s\n", i, i, (i < 399 ? "," : "")
  printf "  }\n}"
}' > package-lock.json
seq 0 3999 | sed 's/^/big line /' > big.txt
git add -A
commit -m "Add lockfile and big file"

git checkout -q -b feature/search
cat > src/search.swift <<'EOF'
func search(_ haystack: [String], for needle: String) -> Int? {
    haystack.firstIndex(of: needle)
}
EOF
git add -A
commit -m "Add search"
edit 's/firstIndex(of: needle)/firstIndex { $0.hasPrefix(needle) }/' src/search.swift
commit -am "Search by prefix"
git checkout -q main
edit 's/# Fixture/# Fixture repository/' README.md
commit -am "Retitle README"
GIT_AUTHOR_DATE="@$t +0000" GIT_COMMITTER_DATE="@$t +0000" git merge -q --no-ff feature/search -m "Merge branch 'feature/search'"
t=$((t + 3600))
git tag v1.0

git checkout -q -b feature/peek
edit 's/print("usage: build.py <target>")/print("usage: build.py <target>", file=sys.stderr)/' scripts/build.py
commit -am "Print usage to stderr"
cat >> web/app.ts <<'EOF'

export function greet(user: User): string {
  return `Hello, ${user.name}!`;
}
EOF
commit -am "Add greet()"

echo "stashed change" >> README.md
git stash push -q -m "experiment with README"

edit 's/fmt.Println("hello")/fmt.Println("hello, world")/' main.go
git add main.go
edit 's/return 0/return 0  # ok/' scripts/build.py
edit 's/self.entries.get(key).copied()/self.entries.get(key).cloned()/' src/lib.rs
cat > notes.md <<'EOF'
# Notes

Untracked file with a few lines.
EOF
mkdir -p "dir with space"
echo "spaces in path" > "dir with space/file name.txt"
echo "done: $dir"
