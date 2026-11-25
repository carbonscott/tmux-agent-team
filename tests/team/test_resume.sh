#!/bin/bash
# Team tests for `resume`: what launch.sh --resume refuses, what it keeps, and how it meets
# pauses, the stall clock, removals and the end of a run.
. "$(dirname "$0")/../lib.sh"
num() { python3 -c "import sys;print(float(open(sys.argv[1]).read().strip()))" "$1"; }
ago() { python3 -c "import time,sys; open(sys.argv[1],'w').write(str(time.time() - float(sys.argv[2])))" "$W/state/$1" "$2"; }
near() { python3 -c "import sys; d = float(sys.argv[1]) - float(sys.argv[2]); print('ok' if abs(d - float(sys.argv[3])) <= 30 else d)" "$@"; }
crash() { stop_gateway; rm -f "$STUB_DIR/session"; ago heartbeat "${1:-300}"; }
st() { ( cd "$W" && harness/boss.sh status 2>&1 ); }

# --- nothing to resume, or something still running
mk_workdir lead h1 h2; setup_wd
out=$(cd "$W" && ./launch.sh --resume 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "new" <<<"$out" && ok "--resume refuses a run that never started" || no "--resume refuses a run that never started" "$out"
refute "and starts nothing" 'new-session' cat "$STUB_DIR/calls.log"
check "an unknown flag is refused with the usage" 'usage' sh -c "cd '$W' && ./launch.sh --bogus"
launch >/dev/null 2>&1; start_gateway
wait_for 8 test -s "$W/state/heartbeat"
check "--resume refuses while the session is up" 'already exists' sh -c "cd '$W' && ./launch.sh --resume"
refute "a live run is not reported as interrupted" 'INTERRUPTED' st
rm -f "$STUB_DIR/session"; D0=$(num "$W/state/deadline")
out=$(cd "$W" && ./launch.sh --resume 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "gateway may still be serving" <<<"$out" && ok "--resume refuses while the gateway still beats" || no "--resume refuses while the gateway still beats" "$out"
check "and leaves the clock alone" '^ok$' near "$(num "$W/state/deadline")" "$D0" 0

# --- a broken work directory is not trusted, and nothing changes
crash 300
mv "$W/ws/h1" "$W/ws.h1.away"
out=$(cd "$W" && ./launch.sh --resume 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "ws/h1 is missing" <<<"$out" && ok "--resume refuses when a workspace is missing" || no "--resume refuses when a workspace is missing" "$out"
check "the refusal moves no clock" '^ok$' near "$(num "$W/state/deadline")" "$D0" 0
refute "the refusal records no resume" . sh -c "cat '$W/records/resumes.jsonl' 2>/dev/null"
mv "$W/ws.h1.away" "$W/ws/h1"
cp "$W/state/board.db" "$TOP/board.keep"; rm -f "$W"/state/board.db-wal "$W"/state/board.db-shm
head -c 4096 /dev/urandom > "$W/state/board.db"
out=$(cd "$W" && ./launch.sh --resume 2>&1); rc=$?
[ $rc -ne 0 ] && grep -qi "board" <<<"$out" && ok "--resume refuses a damaged board" || no "--resume refuses a damaged board" "$out"
cp "$TOP/board.keep" "$W/state/board.db"

# --- the stall clock moves with the deadline; removed helpers get no window
echo "$(python3 -c 'import time;print(time.time()-60)')" > "$W/state/stall_from"; F0=$(num "$W/state/stall_from")
touch "$W/state/removed/h2"; : > "$STUB_DIR/calls.log"
out=$(cd "$W" && ./launch.sh --resume 2>&1)
check "--resume succeeds on an intact directory" 'resuming' echo "$out"
check "the resume names the removed helper" 'not restarted: h2' echo "$out"
check "the record lists the removal" '"removed": \["h2"\]' tail -1 "$W/records/resumes.jsonl"
check "the deadline moved by the time down" '^ok$' near "$(num "$W/state/deadline")" "$D0" 300
check "time down does not count towards a stall" '^ok$' near "$(num "$W/state/stall_from")" "$F0" 300
check "a resume writes a fresh beat, so the same time is never given twice" '^ok$' near "$(num "$W/state/heartbeat")" "$(date +%s)" 0
check "agents start from the rejoining brief" 'run-agent.sh h1 --resume' cat "$STUB_DIR/calls.log"
refute "a removed helper gets no window" 'new-window .*-n h2 ' cat "$STUB_DIR/calls.log"
check "offline_monitor.py lists the resume" 'resumes after an interruption: 1' sh -c "cd '$W' && python3 harness/offline_monitor.py"
check "the lead's rejoining brief names who is gone" 'not coming back: `h2`' sh -c "cd '$W' && python3 harness/render.py lead --resume"
check "a helper's rejoining brief keeps the limits" 'Action monitor' sh -c "cd '$W' && python3 harness/render.py h1 --resume"
refute "a helper's first brief is unchanged" -i 'rejoin' sh -c "cd '$W' && python3 harness/render.py h1"
( cd "$W" && PATH="$REPO/tests/stubs:$PATH" bash harness/run-agent.sh h1 --resume ) </dev/null >/dev/null 2>&1
check "run-agent.sh hands claude the rejoining brief" 'rejoining a run' cat "$STUB_DIR/claude.argv.json"

# --- a run paused when it died resumes paused; clearing the pause gives the time back once
start_gateway; wait_for 8 test -s "$W/state/heartbeat"
python3 -c "import json,time; json.dump(dict(ts=time.time()-400, agent='h1', reason='test'), open('$W/state/HALT','w'))"
crash 300; D1=$(num "$W/state/deadline")
check "a paused run is reported as interrupted" 'INTERRUPTED' st
check "--resume says the team is still paused" 'PAUSED' sh -c "cd '$W' && ./launch.sh --resume"
check "the pause is kept" . ls "$W/state/HALT"
check "no time is given back while paused" '^ok$' near "$(num "$W/state/deadline")" "$D1" 0
check "the record says it resumed paused" '"paused": true' tail -1 "$W/records/resumes.jsonl"
( cd "$W" && harness/boss.sh resume ) >/dev/null 2>&1
check "clearing the pause gives back pause and time down together" '^ok$' near "$(num "$W/state/deadline")" "$D1" 400

# --- a run that had ended is not interrupted, and is not resumed
mk_workdir lead h1; setup_wd; launch >/dev/null 2>&1; start_gateway; wait_for 8 test -s "$W/state/heartbeat"
ago deadline 100; crash 30
refute "a run that ran out of time is not interrupted" 'INTERRUPTED' st
check "boss.sh status says it ended" 'ended' st
out=$(cd "$W" && ./launch.sh --resume 2>&1); rc=$?
[ $rc -ne 0 ] && ok "--resume refuses a run that had ended" || no "--resume refuses a run that had ended" "$out"
out=$(cd "$W" && ./launch.sh 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q -- '--archive' <<<"$out" && ! grep -q -- '--purge' <<<"$out" && ok "a plain launch over an ended run points to --archive only" || no "a plain launch over an ended run points to --archive only" "$out"
mk_workdir lead h1; setup_wd; launch >/dev/null 2>&1; start_gateway; wait_for 8 test -s "$W/state/heartbeat"
crash 30; touch "$W/state/STALLED"
refute "a stalled run is not interrupted" 'INTERRUPTED' st
check "--resume refuses a stalled run" 'STALLED' sh -c "cd '$W' && ./launch.sh --resume"

# --- a complete run is neither interrupted nor started over
mk_workdir lead h1; setup_wd; launch >/dev/null 2>&1; start_gateway
for s in a b c; do land h1 $s >/dev/null 2>&1; done
crash 30
refute "a complete run is not interrupted" 'INTERRUPTED' st
out=$(cd "$W" && ./launch.sh 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q complete <<<"$out" && ok "a plain launch does not start over a complete run" || no "a plain launch does not start over a complete run" "$out"
check "SKILL.md tells resume from a pause's resume" 'boss.sh resume` clears a pause' cat "$REPO/SKILL.md"
finish
