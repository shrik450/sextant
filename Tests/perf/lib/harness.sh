#!/usr/bin/env bash
#
# Builds what the benchmarks measure and runs the app on an automation script, recording what
# it costs. Sourced by Tests/perf/run.sh.
#
# Globals set here and used by scenarios:
#   PERF_ROOT  the checkout being measured
#   PERF_WORK  where the app and the tools are built (.build/perf)
#   APP        the Sextant.app being measured
#   BUNDLE     its bundle ID
#   FIX        the fixtures folder
#   GIT        the git the app and the drivers run

PERF_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PERF_WORK="$PERF_ROOT/.build/perf"
PERF_TESTS="$PERF_ROOT/Tests/perf"
main_checkout=$(cd "$(git -C "$PERF_ROOT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)
FIX=${SEXTANT_PERF_FIXTURES:-$main_checkout/scratch/perf/fixtures}
GUI_LOCK=${SEXTANT_PERF_LOCK:-$main_checkout/scratch/gui-lock}
BUNDLE=${SEXTANT_PERF_BUNDLE:-com.shrikanthup.Sextant.perf}
APP=${SEXTANT_PERF_APP:-$PERF_WORK/Sextant.app}
GIT=$(command -v git)

#######################################
# Builds the release app with the benchmark bundle ID, and the measurement tools.
# Globals:
#   PERF_ROOT, PERF_WORK, PERF_TESTS, APP, BUNDLE, SEXTANT_SYNTAX
# Arguments:
#   "tools" to build only the tools, for a given app.
#######################################
build_suite() {
  mkdir -p "$PERF_WORK"
  local cc=(clang -O2 -Wall -I "$PERF_TESTS/tools")
  "${cc[@]}" -o "$PERF_WORK/gitwrap" "$PERF_TESTS/tools/gitwrap.c"
  "${cc[@]}" -framework CoreGraphics -framework CoreFoundation -o "$PERF_WORK/psample" "$PERF_TESTS/tools/psample.c"
  "${cc[@]}" -o "$PERF_WORK/stall" "$PERF_TESTS/tools/stall.c"
  "${cc[@]}" -dynamiclib -o "$PERF_WORK/libprobe.dylib" "$PERF_TESTS/tools/probe.c"
  codesign --force --sign - "$PERF_WORK/libprobe.dylib" 2>/dev/null
  [[ ${1:-} == tools ]] && return
  (
    cd "$PERF_ROOT" || exit
    swift build -c release --product SextantApp >/dev/null
    swift build -c release --product sextant >/dev/null
    bash "$PERF_ROOT/bundle.sh" "$(swift build -c release --show-bin-path)" "$PERF_WORK" "$GIT" "$SEXTANT_SYNTAX" >/dev/null
  )
  plutil -replace CFBundleIdentifier -string "$BUNDLE" "$APP/Contents/Info.plist"
  plutil -remove CFBundleURLTypes "$APP/Contents/Info.plist"
  plutil -remove CFBundleDocumentTypes "$APP/Contents/Info.plist"
  codesign --force --sign - "$APP" 2>/dev/null
  git -C "$PERF_ROOT" rev-parse HEAD > "$PERF_WORK/commit"
  if [[ -n $(git -C "$PERF_ROOT" status --porcelain -- Sources) ]]; then echo "+dirty" >> "$PERF_WORK/commit"; fi
}

#######################################
# Kills the app being measured and forgets its settings.
# Globals:
#   APP, BUNDLE
#######################################
reset_app() {
  pkill -9 -f "$APP/Contents/MacOS/Sextant" 2>/dev/null || true
  defaults delete "$BUNDLE" >/dev/null 2>&1 || true
}

#######################################
# Releases the GUI lock if this shell holds it.
# Globals:
#   GUI_LOCK, holding_lock
#######################################
release_lock() {
  if [[ ${holding_lock:-0} == 1 ]]; then
    rmdir "$GUI_LOCK" 2>/dev/null || true
    holding_lock=0
  fi
}

#######################################
# Runs the app on an automation script and records what it costs.
#
# The run folder must hold script.txt. Afterwards it holds run.log (the automation log),
# samples.txt (psample), git.log (one line per git started), probe.bin and probe.stalls with
# --probe, driver.txt, and meta.txt (commit, options, load averages, and TIMEOUT or KILLED).
# Takes the GUI lock for the run and deletes the app's settings before and after.
# Globals:
#   APP, BUNDLE, FIX, GIT, GUI_LOCK, PERF_WORK
# Arguments:
#   The run folder, then options:
#     --probe          load libprobe, pinging the main thread every 4 ms
#     --malloc         also count allocations (implies --probe)
#     --driver <cmd>   run <cmd> with bash beside the app; it sees PID, LOG, OUT, FIX and GIT
#     --timeout <s>    kill the app after this long (default 600)
#     --foreground     let the app take focus
#     --max-mb <mb>    kill the app if its footprint passes this, to spare the machine
#######################################
launch() {
  local run=$1
  shift
  local probe=0 malloc=0 driver="" timeout=600 background=--background max_mb=8192
  while (($#)); do
    case $1 in
      --max-mb) max_mb=$2; shift ;;
      --probe) probe=1 ;;
      --malloc) probe=1 malloc=1 ;;
      --driver) driver=$2; shift ;;
      --timeout) timeout=$2; shift ;;
      --foreground) background="" ;;
      *) echo "launch: unknown option $1" >&2; return 2 ;;
    esac
    shift
  done
  local log="$run/run.log"
  rm -f "$log" "$run/samples.txt" "$run/git.log" "$run/probe.bin" "$run/probe.stalls" "$run/driver.txt"
  until mkdir "$GUI_LOCK" 2>/dev/null; do sleep 5; done
  holding_lock=1
  reset_app
  {
    echo "commit $(tr '\n' ' ' < "$PERF_WORK/commit")"
    echo "start $(date +%s) load $(sysctl -n vm.loadavg)"
    echo "options probe=$probe malloc=$malloc timeout=$timeout background=${background:-no}"
  } > "$run/meta.txt"
  local envs=(--env "SEXTANT_GIT=$PERF_WORK/gitwrap" --env "GITWRAP_REAL=$GIT" --env "GITWRAP_LOG=$run/git.log")
  if ((probe)); then
    envs+=(--env "DYLD_INSERT_LIBRARIES=$PERF_WORK/libprobe.dylib" --env "PROBE_OUT=$run/probe" --env PROBE_PING_MS=4 --env PROBE_LOG_MS=16 --env "PROBE_MALLOC=$malloc")
  fi
  local args=(--automation "$run/script.txt" --log "$log")
  [[ -n $background ]] && args+=("$background")
  open -n -g -a "$APP" --stdout "$run/stdout.txt" --stderr "$run/stderr.txt" "${envs[@]}" --args "${args[@]}"
  local pid="" i
  for i in $(seq 1 200); do
    pid=$(pgrep -n -f "$APP/Contents/MacOS/Sextant" || true)
    [[ -n $pid ]] && break
    sleep 0.05
  done
  if [[ -z $pid ]]; then
    echo "app didn't start" >> "$run/meta.txt"
    release_lock
    return 1
  fi
  echo "pid $pid" >> "$run/meta.txt"
  local probearg=""
  ((probe)) && probearg="$run/probe"
  "$PERF_WORK/psample" "$pid" 100 "$log" "$probearg" > "$run/samples.txt" &
  local spid=$! dpid=""
  if [[ -n $driver ]]; then
    PID=$pid LOG=$log OUT=$run FIX=$FIX GIT=$GIT PERF_TESTS=$PERF_TESTS bash -c "$driver" > "$run/driver.txt" 2>&1 &
    dpid=$!
  fi
  local start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if ((SECONDS - start > timeout)); then
      echo "TIMEOUT" >> "$run/meta.txt"
      kill -9 "$pid" 2>/dev/null || true
      break
    fi
    if tail -n 3 "$run/samples.txt" | awk -v max="$max_mb" '!/^#/ && NF >= 30 { fp = $6 } END { exit !(fp > max) }'; then
      echo "KILLED footprint over $max_mb MB" >> "$run/meta.txt"
      kill -9 "$pid" 2>/dev/null || true
      break
    fi
    if [[ -n $background ]] && { [[ $(lsappinfo info -only pid "$(lsappinfo front)") == "\"pid\"=$pid" ]] ||
      tail -n 3 "$run/samples.txt" | awk '!/^#/ && NF >= 31 && $31 == 1 { found = 1 } END { exit !found }'; }; then
      echo "KILLED came in front of the windows in use" >> "$run/meta.txt"
      kill -9 "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.2
  done
  wait "$spid" 2>/dev/null || true
  if [[ -n $dpid ]]; then
    pkill -P "$dpid" 2>/dev/null || true
    kill "$dpid" 2>/dev/null || true
    wait "$dpid" 2>/dev/null || true
  fi
  echo "end $(date +%s) load $(sysctl -n vm.loadavg)" >> "$run/meta.txt"
  reset_app
  release_lock
}
