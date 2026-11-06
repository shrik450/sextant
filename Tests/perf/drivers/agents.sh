#!/usr/bin/env bash
#
# Plays agents working in the work checkout while Sextant reviews it, recording each phase and
# what git says the review should show after it. Ends the app when done.
#
# Run by Tests/perf/lib/harness.sh's launch as a driver, with PID, LOG, OUT, FIX and GIT set.
# Writes $OUT/phases.txt and $OUT/truth-<phase>.txt (see lib/drive.sh).

set -uo pipefail
source "$PERF_TESTS/lib/drive.sh"
repo="$FIX/work"
cd "$repo" || exit 1
G=$GIT
export GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Agent GIT_AUTHOR_EMAIL=agent@example.com GIT_COMMITTER_NAME=Agent GIT_COMMITTER_EMAIL=agent@example.com
mapfile -t files < <($G ls-files 'src/*.zig' | head -400)

#######################################
# Ends a phase: waits for the app to catch up, then records the phase with what the review of
# the agent branch should show.
# Arguments:
#   Phase name, its start in unix nanoseconds, seconds to wait.
#######################################
done_with() {
  local end
  end=$(now_ns)
  sleep "$3"
  phase_done "$1" "$2" "$end" "$repo" "$($G merge-base origin/HEAD HEAD)"
}

wait_for "MARK agents-start"
sleep 2

for burst in 1 2; do
  t=$(now_ns)
  for i in $(seq 0 99); do rewrite "${files[$(((burst * 100 + i) % ${#files[@]}))]}" "b$burst"; done
  done_with "burst$burst" "$t" 5
done

t=$(now_ns)
for i in $(seq 0 199); do rewrite "${files[$((i % ${#files[@]}))]}" "s$i"; sleep 0.05; done
done_with sustained "$t" 6

t=$(now_ns)
mkdir -p src/agent
for i in $(seq 1 50); do printf 'const x%d = %d;\n' "$i" "$i" > "src/agent/new$i.zig"; done
for i in $(seq 1 20); do rm -f "${files[$((300 + i))]}"; done
for i in $(seq 21 40); do mv "${files[$((300 + i))]}" "${files[$((300 + i))]%.zig}_renamed.zig"; done
done_with create "$t" 5

t=$(now_ns)
mkdir -p zig-out/obj .zig-cache/o
for i in $(seq 1 2000); do
  printf 'obj %d\n' "$i" > "zig-out/obj/o$((i % 500)).o"
  printf 'c %d\n' "$i" > ".zig-cache/o/c$((i % 300))"
  ((i % 20 == 0)) && sleep 0.1
done
done_with ignored "$t" 5

t=$(now_ns)
$G add -A && $G commit -q -m "agent: work"
done_with commit "$t" 4

t=$(now_ns)
$G checkout -q -b scratch-branch HEAD~3 && sleep 2 && $G checkout -q agent
done_with checkout "$t" 4

t=$(now_ns)
for i in 1 2 3; do echo "// wip $i" >> "${files[$i]}"; done
$G stash push -q -u -m perf-agent-stash && sleep 2 && $G stash pop -q
done_with stash "$t" 4

t=$(now_ns)
$G add -A && $G commit -q -m "agent: wip"
$G rebase -q --onto HEAD~2 HEAD~1 2>/dev/null || $G rebase --abort
done_with rebase "$t" 4

t=$(now_ns)
$G worktree add -q ../work-wt-agent -b agent-wt 2>/dev/null
done_with worktree "$t" 5

t=$(now_ns)
mkdir -p src/burst
for i in $(seq 1 1000); do printf 'const b%d = %d;\nconst c%d = %d;\n' "$i" "$i" "$i" "$i" > "src/burst/u$i.zig"; done
done_with untracked "$t" 6

kill "$PID"
