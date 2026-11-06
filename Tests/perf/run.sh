#!/usr/bin/env bash
#
# Runs Sextant's benchmarks and checks each measurement against its budget in budgets.tsv.
#
# Usage: Tests/perf/run.sh [options] <quick|full|scenario>...   (inside `nix develop`)
#        Tests/perf/run.sh fixtures [name...]   make the fixtures now
#        Tests/perf/run.sh report <results>     print the table for an earlier run again
#        Tests/perf/run.sh list                 list the scenarios and their tiers
#
# Options:
#   --out <dir>   where results go (default scratch/perf/<commit>-<what>-<time>)
#   --app <path>  measure this Sextant.app instead of building one; its bundle ID is used
#   --no-build    measure the app built last time
#
# quick takes a few minutes and is for every change. full adds the Linux checkout, the soak,
# pathological files and several worktrees, and takes about an hour, plus about 10 minutes to
# fetch Linux the first time.
#
# The app runs behind the windows in use, one run at a time under a GUI lock shared with other
# checkouts. Fixtures live outside the checkout, in $SEXTANT_PERF_FIXTURES (default
# <main checkout>/scratch/perf/fixtures), and are made on first use. Settings:
#   SEXTANT_PERF_BUNDLE    bundle ID for the built app (default com.shrikanthup.Sextant.perf)
#   SEXTANT_PERF_FIXTURES  fixtures folder
#   SEXTANT_PERF_GHOSTTY   the ghostty checkout to clone (default <main>/scratch/showcase/ghostty)
#   SEXTANT_PERF_LOCK      the GUI lock folder (default <main checkout>/scratch/gui-lock)
#
# Prints one row per budget: the scenario, the metric, what was measured, the budget, and PASS,
# FAIL or MISSING. Exits 1 if any budget isn't met.

set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/lib/harness.sh"
source "$here/lib/metrics.sh"
source "$here/lib/fixtures.sh"
for f in "$here"/scenarios/*.sh; do source "$f"; done

QUICK=(probe launch idle reading bigfile overview agents synth goto-work)
FULL=("${QUICK[@]}" linux goto-linux lookups patho worktrees soak)

#######################################
# Prints the budget table for a results folder and says whether every budget was met.
# Arguments:
#   Results folder holding */metrics.tsv.
# Returns:
#   1 if a budget was missed or a measurement is missing.
#######################################
report() {
  local dir=$1
  cat "$dir"/*/metrics.tsv 2>/dev/null > "$dir/metrics.tsv"
  awk -F'\t' -v ran="$(cat "$dir/scenarios.txt" 2>/dev/null)" '
    BEGIN { n = split(ran, r, " "); for (i = 1; i <= n; i++) ran_[r[i]] = 1 }
    FNR == NR { if ($3 != "") V[$1 "\t" $2] = $3; seen[$1 "\t" $2] = 1; next }
    /^#/ || NF < 5 { next }
    {
      if (!($1 in ran_)) next
      k = $1 "\t" $2
      v = V[k]
      if (v == "") verdict = "MISSING"
      else if ($3 == "<=") verdict = (v + 0 <= $4 + 0) ? "PASS" : "FAIL"
      else if ($3 == ">=") verdict = (v + 0 >= $4 + 0) ? "PASS" : "FAIL"
      else verdict = "?"
      count[verdict]++
      printf "%-11s %-34s %12s %2s %-10s %-6s %s\n", $1, $2, (v == "" ? "-" : v), $3, $4, $5, verdict
    }
    END {
      printf "\n%d pass, %d fail, %d missing\n", count["PASS"], count["FAIL"], count["MISSING"]
      exit (count["FAIL"] + count["MISSING"] > 0)
    }' "$dir/metrics.tsv" "$here/budgets.tsv" | tee "$dir/report.txt"
}

#######################################
# Runs one scenario into its own folder, logging how long it took.
# Globals:
#   OUT_DIR, SCENARIO, SCENARIO_DIR
# Arguments:
#   Scenario name.
#######################################
run_scenario() {
  SCENARIO=$1
  SCENARIO_DIR="$OUT_DIR/$SCENARIO"
  rm -rf "$SCENARIO_DIR"
  mkdir -p "$SCENARIO_DIR"
  local t0=$SECONDS
  echo "== $SCENARIO" >&2
  "scenario_${SCENARIO//-/_}" > "$SCENARIO_DIR/scenario.log" 2>&1
  echo "   $((SECONDS - t0)) s" >&2
  emit scenario_s $((SECONDS - t0))
}

out="" build=1 targets=()
while (($#)); do
  case $1 in
    --out) out=$2; shift ;;
    --app) APP=$(cd "$2" && pwd); build=tools; shift ;;
    --no-build) build=0 ;;
    -h | --help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) targets+=("$1") ;;
  esac
  shift
done
case ${targets[0]:-} in
  "") echo "usage: Tests/perf/run.sh [options] <quick|full|scenario>..." >&2; exit 2 ;;
  list)
    echo "quick: ${QUICK[*]}"
    echo "full:  ${FULL[*]}"
    exit 0 ;;
  fixtures) fixture "${targets[@]:1}"; exit ;;
  report) report "${targets[1]}"; exit ;;
esac

scenarios=()
for t in "${targets[@]}"; do
  case $t in
    quick) scenarios+=("${QUICK[@]}") ;;
    full) scenarios+=("${FULL[@]}") ;;
    *)
      if ! declare -F "scenario_${t//-/_}" >/dev/null; then echo "no scenario $t" >&2; exit 2; fi
      scenarios+=("$t") ;;
  esac
done

trap 'reset_app; release_lock' EXIT
if [[ $build == 1 ]]; then build_suite; elif [[ $build == tools ]]; then build_suite tools; fi
[[ $build == tools ]] && BUNDLE=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")
[[ -f $PERF_WORK/commit ]] || git -C "$PERF_ROOT" rev-parse HEAD > "$PERF_WORK/commit"
commit=$(head -1 "$PERF_WORK/commit" | cut -c1-7)
OUT_DIR=${out:-$PERF_ROOT/scratch/perf/$commit-$(IFS=-; echo "${targets[*]}" | cut -c1-40)-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
echo "${scenarios[*]}" > "$OUT_DIR/scenarios.txt"
{
  echo "commit $(tr '\n' ' ' < "$PERF_WORK/commit")"
  echo "app $APP ($BUNDLE)"
  echo "machine $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, macOS $(sw_vers -productVersion)"
  echo "started $(date) load $(sysctl -n vm.loadavg)"
} > "$OUT_DIR/meta.txt"
for s in "${scenarios[@]}"; do run_scenario "$s"; done
echo "finished $(date) load $(sysctl -n vm.loadavg)" >> "$OUT_DIR/meta.txt"
echo
report "$OUT_DIR"
status=$?
echo "results in $OUT_DIR"
exit $status
