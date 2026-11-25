#!/bin/bash
# Acceptance: ./launch.sh --resume after a crash  (see STATEMENTS.md, statement `resume`)
. "$(dirname "$0")/../lib.sh"
num() { python3 -c "import sys;print(float(open(sys.argv[1]).read().strip()))" "$1"; }

mk_workdir lead h1 h2; setup_wd; launch >/dev/null 2>&1; start_gateway
wait_for 8 test -s "$W/state/heartbeat"
check "the gateway writes state/heartbeat, the time of its last beat" '^ok$' python3 -c "
import time; t = float(open('$W/state/heartbeat').read()); print('ok' if abs(time.time() - t) < 10 else t)"
as lead team sql "CREATE TABLE keep(x); INSERT INTO keep VALUES (41)" >/dev/null 2>&1
check "a statement lands before the crash" 'ACCEPTED' land h1 a
( cd "$W" && harness/boss.sh remove h2 ) >/dev/null 2>&1
D0=$(num "$W/state/deadline")

# the crash: the gateway and the tmux session are gone; the last beat was 600 s ago
stop_gateway; rm -f "$STUB_DIR/session"
python3 -c "import time; open('$W/state/heartbeat','w').write(str(time.time() - 600))"

check "boss.sh status says the run was interrupted" 'INTERRUPTED' sh -c "cd '$W' && harness/boss.sh status"
: > "$STUB_DIR/calls.log"
out=$(cd "$W" && ./launch.sh 2>&1); rc=$?
[ $rc -ne 0 ] && ok "a plain ./launch.sh refuses to start over an interrupted run" || no "a plain ./launch.sh refuses to start over an interrupted run" "$out"
check "the refusal names --resume" '--resume' echo "$out"
check "the refusal names --archive" '--archive' echo "$out"
refute "the refusal does not advertise --purge" '--purge' echo "$out"
refute "the refusal starts nothing" 'new-session|new-window' cat "$STUB_DIR/calls.log"
check "the refusal leaves the clock alone" '^ok$' python3 -c "print('ok' if abs(float(open('$W/state/deadline').read()) - $D0) < 1 else 'moved')"

out=$(cd "$W" && ./launch.sh --resume 2>&1); rc=$?
[ $rc -eq 0 ] && ok "./launch.sh --resume succeeds" || no "./launch.sh --resume succeeds" "$out"
check "the deadline moves by the time lost (600 s)" '^ok$' python3 -c "
d = float(open('$W/state/deadline').read()) - $D0; print('ok' if 570 <= d <= 660 else d)"
check "an earlier removal is kept" . ls "$W/state/removed/h2"
check "what had landed is kept" '"a"' cat "$W/state/landed.json"
check "the session is started again" 'tmux new-session' cat "$STUB_DIR/calls.log"
check "the lead gets a window" 'new-window .*-n lead ' cat "$STUB_DIR/calls.log"
check "a helper gets a window" 'new-window .*-n h1 ' cat "$STUB_DIR/calls.log"
check "records/resumes.jsonl records the time lost" '^ok$' python3 -c "
import json; r = json.loads(open('$W/records/resumes.jsonl').read().splitlines()[-1]); print('ok' if 570 <= r['down_s'] <= 660 else r)"

lead_first=$(cd "$W" && python3 harness/render.py lead); lead_again=$(cd "$W" && python3 harness/render.py lead --resume)
[ -n "$lead_again" ] && [ "$lead_first" != "$lead_again" ] && ok "render.py <agent> --resume prints a different brief" || no "render.py <agent> --resume prints a different brief"
check "the lead's resume brief says it is rejoining" -i 'rejoin|resum' echo "$lead_again"
check "the lead's resume brief asks it to reopen stale claims" -i 'claim' echo "$lead_again"
refute "the lead's resume brief does not ask for the tables again" 'Create five tables' echo "$lead_again"
check "a helper's resume brief says it is rejoining" -i 'rejoin|resum' sh -c "cd '$W' && python3 harness/render.py h1 --resume"

start_gateway
check "the board is as it was" '^41$' as lead team sql "SELECT x FROM keep"
check "the removed helper is still refused" 'removed' as h2 team status
check "work goes on after the resume" 'ACCEPTED' land h1 b
check "and the run can complete" 'RUN COMPLETE' land h1 c
refute "a finished run is not reported as interrupted" 'INTERRUPTED' sh -c "cd '$W' && harness/boss.sh status"

check "SKILL.md documents --resume" '--resume' cat "$REPO/SKILL.md"
finish
