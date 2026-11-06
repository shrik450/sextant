#!/usr/bin/env bash
#
# Times Find References, Peek Definition and Find in Files on Linux.

#######################################
# Puts the caret on a common name in Linux's last 30 commits, and finds its references and
# definition twice each, then searches the tree for kmalloc.
# Globals:
#   SCENARIO_DIR, FIX
#######################################
scenario_lookups() {
  fixture linux
  local run="$SCENARIO_DIR/run" c
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/linux HEAD~30..HEAD
sleep 3000
measure 1 menu Next File
key w
key w
key w
key w
key w
key w
mark refs-start
measure 1 menu Find References
sleep 1500
measure 1 menu Find References
sleep 1500
measure 1 menu Peek Definition
sleep 1500
key esc
measure 1 menu Peek Definition
sleep 1500
key esc
mark refs-end
menu Find in Files…
type kmalloc
mark find-start
key return
sleep 8000
mark find-end
quit
EOF
  launch "$run" --probe --timeout 300
  emit_measured "$run" references_first "menu Find References" 1 settled:max
  emit_measured "$run" references_again "menu Find References" 2 settled:max
  emit_measured "$run" peek_first "menu Peek Definition" 1 settled:max
  emit_measured "$run" peek_again "menu Peek Definition" 2 settled:max
  c=$(cost_between "$run" refs-start refs-end)
  emit_cost lookups "$c" cpu_ms git_cpu_ms gits max_stall_ms
  c=$(cost_between "$run" find-start find-end)
  emit_cost find "$c" cpu_ms git_cpu_ms gits max_stall_ms fp_growth_mb
}
