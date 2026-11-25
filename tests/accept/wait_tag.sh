#!/bin/bash
# Acceptance: wait-run.sh names its team  (see STATEMENTS.md, statement `wait_tag`)
. "$(dirname "$0")/../lib.sh"
mk_workdir; setup_wd; launch >/dev/null 2>&1
S=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['session'])" "$W/config.json")
first() { sh -c "cd '$W' && harness/wait-run.sh ${1:-1} | head -1"; }
check "STILL RUNNING carries the session" "^STILL RUNNING \[$S\]\$" first 0
echo '{"tool": "Bash", "why": "probe"}' > "$W/state/HALT"
check "HALT carries the session" "^HALT \[$S\]\$" first
check "HALT still prints the blocked action on its second line" '^\{"tool": "Bash", "why": "probe"\}$' sh -c "cd '$W' && harness/wait-run.sh 1 | sed -n 2p"
rm "$W/state/HALT"; echo '{"why": "probe"}' > "$W/state/STALLED"
check "STALLED carries the session" "^STALLED \[$S\]\$" first
rm "$W/state/STALLED"; cp "$W/state/deadline" "$TOP/deadline"; echo 1 > "$W/state/deadline"
check "TIME UP carries the session" "^TIME UP \[$S\]\$" first
cp "$TOP/deadline" "$W/state/deadline"; touch "$W/state/DONE"
check "DONE carries the session" "^DONE \[$S\]\$" first
check "the last line is unchanged" '^done on main: ' sh -c "cd '$W' && harness/wait-run.sh 1 | tail -1"
check "it works when called by absolute path from elsewhere" "^DONE \[$S\]\$" sh -c "cd / && '$W/harness/wait-run.sh' 1 | head -1"
finish
