#!/bin/bash
# Team tests for `stall` (stall_min): what the acceptance test does not cover. Which merges
# reset the stall clock, that a pause and time down before a resume do not count, that a run
# that was never launched, is complete or is out of time does not stall, boss.sh unstall,
# and bad settings.
. "$(dirname "$0")/../lib.sh"
num() { python3 -c "import sys;print(float(open(sys.argv[1]).read().strip()))" "$1"; }
age() { python3 -c "import sys,time;print(time.time()-float(open(sys.argv[1]).read().strip()))" "$1"; }
no_stall() { refute "$1" . sh -c "ls '$W/state/STALLED' 2>/dev/null"; }

# --- the stall clock: twelve seconds
mk_workdir lead h1 h2; setcfg stall_min 0.2; setup_wd; launch >/dev/null 2>&1; start_gateway
check "launch.sh starts the stall clock" '^ok$' python3 -c "
f = float(open('$W/state/stall_from').read()); s = float(open('$W/state/started').read()); print('ok' if abs(f - s) < 2 else (f, s))"
check "boss.sh status shows the stall clock to the boss" 'stall clock: [0-9]+ of 0.2 min' sh -c "cd '$W' && harness/boss.sh status"
refute "agents are not shown the stall clock" -i 'stall' as h1 team status
t0=$(date +%s)
check "a merge lands" 'ACCEPTED' land h1 a
check "an accepted merge restarts the stall clock" '^ok$' python3 -c "print('ok' if $(num "$W/state/stall_from") >= $t0 else 'old')"
s1=$(num "$W/state/stall_from")
check "a wrong answer is rejected" 'REJECTED' land h2 b "wrong b" no
check "a rejected merge does not restart the stall clock" "^$s1\$" num "$W/state/stall_from"

# a pause: the threshold has long passed, but the team is paused, so nothing stalls
echo "{\"ts\": $(python3 -c 'import time;print(time.time()-299)'), \"agent\": \"h1\", \"reason\": \"test\"}" > "$W/state/HALT"
python3 -c "import time; open('$W/state/stall_from','w').write(str(time.time()-300))"
sleep 3
no_stall "a paused run does not stall"
check "boss.sh resume clears the pause" 'pause cleared' sh -c "cd '$W' && harness/boss.sh resume"
check "and moves the stall clock by the length of the pause" '^ok$' python3 -c "
a = $(age "$W/state/stall_from"); print('ok' if 0 <= a < 5 else a)"
sleep 2
no_stall "so the paused time does not count afterwards"
python3 -c "import time; open('$W/state/stall_from','w').write(str(time.time()-10))"   # skip ahead to near the limit
wait_for 25 test -e "$W/state/STALLED" && ok "the clock runs again after the pause and the run stalls" || no "the clock runs again after the pause and the run stalls"
check "state/STALLED says why" '^ok$' python3 -c "
import json; s = json.load(open('$W/state/STALLED')); print('ok' if s['stall_min'] == 0.2 and s['idle_s'] >= 12 and s['landed'] == ['a'] else s)"
out=$(as h2 team mr "late b" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q STALLED <<<"$out" && ok "mr is refused after a stall" || no "mr is refused after a stall" "$rc $out"
out=$(as h2 team push 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q STALLED <<<"$out" && ok "push is refused after a stall" || no "push is refused after a stall" "$rc $out"
as h1 team status >/dev/null 2>&1; [ $? -eq 4 ] && ok "status still answers, with exit status 4: the run is over" || no "status still answers, with exit status 4: the run is over"
check "whoami still answers" '^h1$' as h1 team whoami
check "the reminder loop stops on a stall" 'state/STALLED' cat "$W/harness/remind.sh"
check "offline_monitor.py reports the stall" 'STALLED' sh -c "cd '$W' && python3 harness/offline_monitor.py"

# boss.sh unstall reopens the run with a fresh clock
check "boss.sh unstall reopens a stalled run" 'stall cleared' sh -c "cd '$W' && harness/boss.sh unstall"
no_stall "state/STALLED is gone"
check "the stall is kept in the records" . ls "$W"/records/stalled.*.json
check "the door works again" '^1$' as h1 team sql "SELECT 1 AS one"
check "work lands again" 'ACCEPTED' land h2 b "right b" ok
( cd "$W" && harness/boss.sh unstall ) >/dev/null 2>&1 && no "unstall refuses a run that has not stalled" || ok "unstall refuses a run that has not stalled"

# a run that was never launched, and a complete run, never stall
mk_workdir lead h1; setcfg stall_min 0.05; setup_wd; start_gateway
sleep 3
no_stall "a gateway before the launch does not stall"
stop_gateway; setcfg stall_min 0.5; launch >/dev/null 2>&1; start_gateway
land h1 a >/dev/null 2>&1; land h1 b >/dev/null 2>&1
check "the run completes" 'RUN COMPLETE' land h1 c
python3 -c "import time; open('$W/state/stall_from','w').write(str(time.time()-1000))"
sleep 3
no_stall "a complete run never stalls"

# a run that is out of time does not stall: time is up first
mk_workdir lead h1; setcfg stall_min 0.05; setup_wd; launch >/dev/null 2>&1; start_gateway
( cd "$W" && harness/boss.sh end ) >/dev/null 2>&1
sleep 3
no_stall "a run out of time does not stall"
check "wait-run.sh says TIME UP" '^TIME UP' sh -c "cd '$W' && harness/wait-run.sh 1 | head -1"

# time down before a resume does not count: the crash comes just after a merge, and the run
# was down for ten minutes, far past stall_min
mk_workdir lead h1; setcfg stall_min 0.2; setup_wd; launch >/dev/null 2>&1; start_gateway
check "a merge lands before the crash" 'ACCEPTED' land h1 a
stop_gateway; rm -f "$STUB_DIR/session"
python3 -c "import time; t = time.time() - 600; open('$W/state/heartbeat','w').write(str(t)); open('$W/state/stall_from','w').write(str(t - 2))"
check "./launch.sh --resume continues the run" 'resuming' launch --resume
check "the resume moves the stall clock by the time down" '^ok$' python3 -c "
a = $(age "$W/state/stall_from"); print('ok' if 0 <= a < 10 else a)"
start_gateway; sleep 3
no_stall "time down before a resume does not count as a stall"
# a crash while paused: the resume gives nothing back; clearing the pause gives back both
stop_gateway; rm -f "$STUB_DIR/session"
python3 -c "
import json, time; now = time.time()
open('$W/state/heartbeat','w').write(str(now - 600)); open('$W/state/stall_from','w').write(str(now - 702))
json.dump(dict(ts=now - 700, agent='h1', reason='test'), open('$W/state/HALT','w'))"
launch --resume >/dev/null 2>&1; start_gateway; sleep 3
no_stall "a run that crashed while paused does not stall after the resume"
check "clearing the pause" 'pause cleared' sh -c "cd '$W' && harness/boss.sh resume"
check "gives the paused and the down time back to the stall clock" '^ok$' python3 -c "
a = $(age "$W/state/stall_from"); print('ok' if 0 <= a < 10 else a)"
sleep 2
no_stall "so neither counts as a stall"

# settings: setup.sh refuses a bad value; an absent stall_min is off
mk_workdir lead h1; setcfg stall_min -1
( cd "$W" && ./setup.sh ) >/dev/null 2>&1 && no "setup.sh refuses a negative stall_min" || ok "setup.sh refuses a negative stall_min"
setcfg stall_min '"ten"'
( cd "$W" && ./setup.sh ) >/dev/null 2>&1 && no "setup.sh refuses a stall_min that is not a number" || ok "setup.sh refuses a stall_min that is not a number"
python3 -c "import json; p='$W/config.json'; c=json.load(open(p)); del c['stall_min']; json.dump(c, open(p,'w'))"
setup_wd && ok "setup.sh accepts a config without stall_min" || no "setup.sh accepts a config without stall_min"
launch >/dev/null 2>&1; start_gateway
python3 -c "import time; open('$W/state/stall_from','w').write(str(time.time()-100000))"
sleep 3
no_stall "without stall_min the run never stalls"
check "the template ships a stall limit" '^ok$' python3 -c "
import json; v = json.load(open('$REPO/template/config.json'))['stall_min']; print('ok' if v > 0 else v)"
finish
