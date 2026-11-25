#!/bin/bash
# Acceptance: the stall limit, stall_min  (see STATEMENTS.md, statement `stall`)
. "$(dirname "$0")/../lib.sh"

# a three-second limit: 0.05 min
mk_workdir; setcfg stall_min 0.05; setup_wd; launch >/dev/null 2>&1; start_gateway
check "work lands while the run is moving" 'ACCEPTED' land h1 a
refute "an accepted merge is not a stall" . sh -c "ls '$W/state/STALLED' 2>/dev/null"
wait_for 15 test -e "$W/state/STALLED" && ok "state/STALLED appears when nothing is accepted for stall_min" || no "state/STALLED appears when nothing is accepted for stall_min"
check "wait-run.sh reports STALLED first" '^STALLED' sh -c "cd '$W' && harness/wait-run.sh 1 | head -1"
check "team status tells the agent" 'STALLED' as h1 team status
out=$(as h1 team sql "SELECT 1" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q STALLED <<<"$out" && ok "the door refuses work after a stall" || no "the door refuses work after a stall" "$rc $out"
check "a stalled run lets agents stop" '^$' sh -c "echo '{}' | python3 '$W/harness/keepgoing.py' h1"
check "boss.sh status shows the stall" 'STALLED' sh -c "cd '$W' && harness/boss.sh status"
check "what landed before the stall is still there" '"a"' cat "$W/state/landed.json"

# stall_min 0 switches the limit off
mk_workdir; setcfg stall_min 0; setup_wd; launch >/dev/null 2>&1; start_gateway
sleep 5
refute "stall_min 0 never stalls" . sh -c "ls '$W/state/STALLED' 2>/dev/null"
check "and agents are kept going" '"decision": "block"' sh -c "echo '{}' | python3 '$W/harness/keepgoing.py' h1"
check "and the door still works" '^1$' as h1 team sql "SELECT 1 AS one" 
check "SKILL.md documents stall_min" 'stall_min' cat "$REPO/SKILL.md"
check "SKILL.md says the budget is a ceiling" -i 'ceiling' cat "$REPO/SKILL.md"
finish
