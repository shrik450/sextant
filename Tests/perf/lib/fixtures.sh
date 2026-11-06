#!/usr/bin/env bash
#
# Makes the benchmark repositories under $FIX, and puts them back in their starting state
# before each scenario. Sourced by Tests/perf/run.sh.
#
#   ghostty  a clone of the ghostty showcase checkout ($SEXTANT_PERF_GHOSTTY), left as it is
#   work     an agent's checkout: a clone of ghostty on branch "agent", 20 commits ahead of
#            origin/main, with one uncommitted edit; made again for every scenario that uses it
#   synth    300,000 small files in 3 levels of folders, then a commit that changes 3,000, adds
#            500, deletes 500 and renames 200 of them
#   many     2 commits 10,000 changed Swift files apart
#   bigfile  2 commits 400 changed Swift files apart, with a 30,000-line file among them
#   patho    pathological inputs, each changed between HEAD~1 and HEAD: a 10 MB minified one-line
#            JavaScript file, a million-line C file, a 1 MB line, a 64 MB binary, a chain of
#            renames, a 60-level-deep folder, Latin-1 text and a Latin-1 file name, CRLF lines,
#            and a 200,000-character line in a Swift file
#   linux    a shallow clone of the Linux kernel, 400 commits deep (about 7 GB, fetched once)

GHOSTTY_SOURCE=${SEXTANT_PERF_GHOSTTY:-$main_checkout/scratch/showcase/ghostty}

#######################################
# Runs git with no user or system configuration and a fixed identity, so fixtures come out the
# same everywhere.
# Arguments:
#   git's arguments.
#######################################
fixture_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com \
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com \
    "$GIT" "$@"
}

#######################################
# Prints a fast-import stream for the synthetic repository.
# Arguments:
#   Number of files.
#######################################
synth_stream() {
  awk -v n="$1" '
    function body(i, v) {
      return sprintf("// file %d\n#include <stdio.h>\n\nint f%d(int x) {\n    int y = x * %d;\n    return y + %d;\n}\n", i, i, (i % 7) + 2, v)
    }
    function path(i) { return sprintf("d%03d/s%02d/f%05d.c", int(i / 3000), int(i / 60) % 50, i) }
    function emit(p, s) { printf "M 100644 inline %s\ndata %d\n%s\n", p, length(s), s }
    BEGIN {
      printf "commit refs/heads/main\nmark :1\ncommitter Fixture <fixture@example.com> 1700000000 +0000\ndata 5\nbase\n"
      for (i = 0; i < n; i++) emit(path(i), body(i, 0))
      printf "\ncommit refs/heads/main\nmark :2\ncommitter Fixture <fixture@example.com> 1700000100 +0000\ndata 7\nchange\nfrom :1\n"
      for (i = 0; i < 3000; i++) { k = i * 100; emit(path(k), body(k, 1)) }
      for (i = 0; i < 500; i++) emit(sprintf("new/n%03d/added%04d.c", i % 37, i), body(n + i, 2))
      for (i = 0; i < 500; i++) printf "D %s\n", path(i * 600 + 33)
      for (i = 0; i < 200; i++) { k = i * 1500 + 67; printf "R %s moved/%s\n", path(k), path(k) }
      printf "\n"
    }'
}

make_synth() {
  local repo="$FIX/synth"
  rm -rf "$repo"
  fixture_git init -q -b main "$repo"
  synth_stream 300000 | fixture_git -C "$repo" fast-import --quiet
  fixture_git -C "$repo" checkout -q -f main
}

make_many() {
  local repo="$FIX/many" v
  rm -rf "$repo"
  fixture_git init -q -b main "$repo"
  for v in 1 2; do
    awk -v v="$v" -v root="$repo/Sources" 'BEGIN {
      for (i = 0; i < 10000; i++) {
        d = root "/m" int(i / 100)
        if (i % 100 == 0) system("mkdir -p " d)
        f = d "/file" i ".swift"
        for (j = 0; j < 40; j++) {
          printf "/// Scales input %d.\nfunc g%d_%d(_ x: Int) -> Int {\n    let y = x + %d\n    return y * %d\n}\n\n", j, i, j, j, (v == 2 && j % 9 == 3) ? 3 : 2 > f
        }
        close(f)
      }
    }'
    fixture_git -C "$repo" add -A
    fixture_git -C "$repo" commit -q -m "Version $v"
  done
}

make_patho() {
  local repo="$FIX/patho" d=deep i v
  rm -rf "$repo"
  fixture_git init -q -b main "$repo"
  (
    cd "$repo" || exit
    mkdir -p src
    for i in $(seq 1 60); do d="$d/level$i"; done
    mkdir -p "$d"
    for v in 1 2 3 4; do
      awk -v v="$v" 'BEGIN { for (i = 0; i < 220000; i++) { printf "var a%d=function(b,c){return b*%d+c%s};", i, (v % 2 == 0 && i % 5000 == 0) ? 3 : 2, (i % 3 ? "" : "||null") } }' > src/minified.min.js
      awk -v v="$v" 'BEGIN { for (i = 0; i < 1000000; i++) printf "int v%d = %d;\n", i, (v % 2 == 0 && i % 100000 == 7) ? i + 1 : i }' > src/million.c
      awk -v v="$v" 'BEGIN { printf "let s = \""; for (i = 0; i < 1048576; i++) printf "%c", 97 + (i * (v % 2 == 0 ? 7 : 5)) % 26; printf "\"\n" }' > src/megaline.swift
      awk -v v="$v" 'BEGIN { printf "let wide = ["; for (i = 0; i < 25000; i++) printf "%d, ", (v % 2 == 0 && i == 12345) ? 0 : i; printf "]\n" }' > src/longline.swift
      head -c $((64 << 20)) /dev/zero | LC_ALL=C tr '\0' "\\$((v + 1))" > src/blob.bin
      printf 'binary\0' | dd of=src/blob.bin bs=1 seek=100 conv=notrunc 2>/dev/null
      printf 'caf\xe9 cr\xe8me br\xfbl\xe9e version %d\n' "$v" > src/latin1.txt
      local latin oid
      latin=$(printf 'src/r\xe9sum\xe9.txt')
      oid=$(printf 'r\xe9sum\xe9 %d\n' "$v" | fixture_git hash-object -w --stdin)
      fixture_git update-index --add --cacheinfo "100644,$oid,$latin"
      fixture_git update-index --skip-worktree "$latin"
      printf 'line one\r\nline two v%d\r\nline three\r\n' "$v" > src/crlf.txt
      printf 'deep file version %d\n' "$v" > "$d/leaf.txt"
      if [[ $v == 1 ]]; then
        awk 'BEGIN { for (i = 0; i < 300; i++) printf "func chain%d() -> Int { %d }\n", i, i }' > src/chain-a.swift
      else
        local prev cur
        prev=$(ls src/chain-*.swift)
        cur="src/chain-$(printf "\\x$(printf %x $((96 + v)))").swift"
        fixture_git mv -f "$prev" "$cur"
        printf 'func added%d() -> Int { %d }\n' "$v" "$v" >> "$cur"
      fi
      fixture_git add -A
      fixture_git commit -q -m "Version $v"
    done
  )
}

#######################################
# Writes a Swift file of small functions, every 25th of which changes in version 2.
# Arguments:
#   Number of functions, version (1 or 2), file to write.
#######################################
swift_functions() {
  awk -v n="$1" -v v="$2" 'BEGIN {
    print "import Foundation\n"
    for (j = 0; j < n; j++) {
      printf "/// Scales input %d.\nfunc f%d(_ x: Int) -> Int {\n    let y = x + %d\n    return y * %d\n}\n\n", j, j, j, (v == 2 && j % 25 == 5) ? 3 : 2
    }
  }' > "$3"
}

make_bigfile() {
  local repo="$FIX/bigfile" v i
  rm -rf "$repo"
  fixture_git init -q -b main "$repo"
  for v in 1 2; do
    for i in $(seq 0 399); do
      mkdir -p "$repo/src/m$((i / 10))"
      swift_functions 75 "$v" "$repo/src/m$((i / 10))/file$i.swift"
    done
    swift_functions 5000 "$v" "$repo/src/big.swift"
    fixture_git -C "$repo" add -A
    fixture_git -C "$repo" commit -q -m "Version $v"
  done
}

make_ghostty() {
  rm -rf "$FIX/ghostty"
  fixture_git clone -q "$GHOSTTY_SOURCE" "$FIX/ghostty"
}

make_linux() {
  rm -rf "$FIX/linux"
  fixture_git clone --depth=400 --single-branch --no-tags https://github.com/torvalds/linux "$FIX/linux"
}

#######################################
# Makes "work" again from ghostty, with any linked worktrees it had removed.
# Globals:
#   FIX
#######################################
make_work() {
  local repo="$FIX/work"
  rm -rf "$repo" "$FIX"/work-wt-*
  fixture_git clone -q "$FIX/ghostty" "$repo"
  fixture_git -C "$repo" checkout -q -b agent
  fixture_git -C "$repo" update-ref refs/remotes/origin/main HEAD~20
  fixture_git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  echo "// agent edit" >> "$repo/src/main.zig"
}

#######################################
# Makes a fixture if it's missing, and otherwise puts it back as it was made: tracked files
# reset, untracked and ignored files removed, and the app's review state dropped. Work is
# always made again.
# Globals:
#   FIX
# Arguments:
#   Fixture names.
#######################################
fixture() {
  local name repo
  mkdir -p "$FIX"
  for name in "$@"; do
    repo="$FIX/$name"
    if [[ $name == work ]]; then
      [[ -d $FIX/ghostty/.git ]] || make_ghostty
      make_work
      continue
    fi
    if ! "$GIT" -C "$repo" rev-parse -q --verify HEAD >/dev/null 2>&1; then
      echo "making fixture $name" >&2
      "make_$name"
    fi
    if [[ $name != ghostty ]]; then
      fixture_git -C "$repo" reset -q --hard 2>/dev/null || true
      fixture_git -C "$repo" clean -qfdx
    fi
    rm -rf "$repo/.git/sextant"
  done
}
