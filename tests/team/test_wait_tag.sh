#!/bin/bash
# Team test for wait_tag: what the acceptance test does not cover.
. "$(dirname "$0")/../lib.sh"
mk_workdir; setcfg session '"my team.x"'; setup_wd; launch >/dev/null 2>&1
S='my team\.x'
check "a session name with a space and a dot is printed as is" "^STILL RUNNING \[$S\]\$" sh -c "cd / && '$W/harness/wait-run.sh' 0 | head -1"
check "STILL RUNNING still ends with the done-on-main line" '^done on main: ' sh -c "cd / && '$W/harness/wait-run.sh' 0 | tail -1"
check "two lines only when STILL RUNNING" '^2$' sh -c "'$W/harness/wait-run.sh' 0 | wc -l | tr -d ' '"
check "exit status stays 0" '^rc=0$' sh -c "'$W/harness/wait-run.sh' 0 >/dev/null; echo rc=\$?"
echo '{"why": "probe-stall"}' > "$W/state/STALLED"
check "STALLED record is still the second line" '^\{"why": "probe-stall"\}$' sh -c "cd / && '$W/harness/wait-run.sh' 1 | sed -n 2p"
check "STALLED still ends with done on main" '^done on main: ' sh -c "cd / && '$W/harness/wait-run.sh' 1 | tail -1"
rm "$W/state/STALLED"; touch "$W/state/DONE"
check "DONE output is exactly two lines" '^2$' sh -c "'$W/harness/wait-run.sh' 1 | wc -l | tr -d ' '"
refute "the tag appears only on the first line" '\[my team' sh -c "'$W/harness/wait-run.sh' 1 | tail -n +2"
check "callers matching ^DONE keep working" '^DONE' sh -c "cd /tmp && '$W/harness/wait-run.sh' 1 | head -1"
# a second team gets its own tag
W1=$W; mk_workdir; setup_wd; launch >/dev/null 2>&1
S2=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['session'])" "$W/config.json")
check "a second team prints its own session" "^STILL RUNNING \[$S2\]\$" sh -c "cd '$W1' && '$W/harness/wait-run.sh' 0 | head -1"
check "the first team still prints its session" "^DONE \[$S\]\$" sh -c "cd '$W' && '$W1/harness/wait-run.sh' 0 | head -1"
finish
