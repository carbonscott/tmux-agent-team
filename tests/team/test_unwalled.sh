#!/bin/bash
# Team tests for "sandbox": false (an unwalled run): values setup.sh must refuse before it creates
# anything, settings that fail closed, what selftest.sh still asks and no longer asks, the monitor
# rules that stay, and how the flag shows in launch, resume, status, offline_monitor, the page and
# the archive. The acceptance test (tests/accept/unwalled.sh) covers the main path.
. "$(dirname "$0")/../lib.sh"
enabled() { python3 -c "import json,sys; print(json.load(open('$W/harness/settings/'+sys.argv[1]+'.json'))['sandbox']['enabled'])" "$1"; }
hook() { rm -f "$W/state/HALT"; echo "{\"tool_name\":\"$2\",\"tool_input\":$3,\"cwd\":\"$W/ws/$1\"}" | python3 "$W/harness/hook.py" "$1"; }
prompts() { cat "$STUB_DIR/claude.calls.jsonl" 2>/dev/null; }
DENY='"permissionDecision": "deny"'
WARN='unwalled|sandbox (is )?off'

# ---- values that are not true or false: refused before anything is created, with a reason
for v in '"false"' '"no"' 0 1 null '[]'; do
  mk_workdir lead h1; setcfg sandbox "$v"
  out=$(cd "$W" && ./setup.sh 2>&1); rc=$?
  [ $rc -ne 0 ] && ok "setup.sh refuses \"sandbox\": $v" || no "setup.sh refuses \"sandbox\": $v" "$out"
  check "and names the setting" 'sandbox' echo "$out"
  [ ! -e "$W/ws" ] && [ ! -e "$W/central.git" ] && ok "and creates nothing ($v)" || no "and creates nothing ($v)"
done

# ---- the settings fail closed: a bad value that slips past setup keeps the sandbox on
mk_workdir lead h1; setup_wd
setcfg sandbox '"false"'; ( cd "$W" && harness/py harness/mk_settings.py ) >/dev/null 2>&1
check "a string \"false\" written after setup still leaves the sandbox on" '^True$' enabled h1
setcfg sandbox false; ( cd "$W" && harness/py harness/mk_settings.py ) >/dev/null 2>&1
check "false turns it off" '^False$' enabled h1
setcfg sandbox true; out=$( cd "$W" && harness/py harness/mk_settings.py 2>&1 )
check "true turns it back on" '^True$' enabled h1
refute "and then mk_settings.py says nothing about the sandbox being off" -i "$WARN" echo "$out"

# ---- launch.sh checks the value again: config.json may change after setup
setcfg sandbox '"off"'
out=$(launch 2>&1); rc=$?
[ $rc -ne 0 ] && ok "launch.sh refuses a sandbox value written after setup" || no "launch.sh refuses a sandbox value written after setup" "$out"
check "and says which setting" 'sandbox' echo "$out"
[ ! -e "$STUB_DIR/session" ] && ok "and starts nothing" || no "and starts nothing"
setcfg sandbox true

# ---- a walled run never mentions it
mk_workdir lead h1
setup_wd
refute "a walled setup.sh does not warn" -i "$WARN" cat "$TOP/setup.log"
out=$(cd "$W" && timeout 60 harness/selftest.sh h1 </dev/null 2>&1)
refute "a walled selftest.sh does not say unwalled" -i 'unwalled' echo "$out"
check "a walled selftest still asks for the wall steps (outside write, tmux, history)" \
  'outside-probe.*command -v tmux' prompts
check "and the history step" 'history.jsonl' prompts
check "and still checks that nothing was written outside" 'nothing was written outside' echo "$out"
refute "a walled launch does not warn" -i "$WARN" launch

# ---- an unwalled run
mk_workdir lead h1 h2; setcfg sandbox false; setup_wd
check "the settings keep the denied-permission hook" 'denied.py' cat "$W/harness/settings/h2.json"
check "and the sandbox block is still written, only switched off" '"enabled": false' cat "$W/harness/settings/h2.json"
out=$(cd "$W" && timeout 60 harness/selftest.sh h1 </dev/null 2>&1)
check "selftest.sh says the wall steps are skipped" -i 'skip' echo "$out"
refute "and does not ask for the outside write" 'outside-probe' prompts
refute "nor reach for tmux" 'command -v tmux' prompts
refute "nor read the owner's prompt history" 'history.jsonl' prompts
refute "nor list the neighbour's workspace or the harness" 'ls -A .*har\*' prompts
check "but still asks for the step that must pause the team" 'head -1 .*gateway.py' prompts
check "and the allowed_domains step" 'allowed_domains' prompts
check "and still reports the monitor's verdicts" 'the monitor refuses every call while paused' echo "$out"
refute "and does not claim the walls held" 'PASS  nothing was written outside' echo "$out"
[ ! -e "$W/state/started" ] && ok "selftest.sh leaves no run started" || no "selftest.sh leaves no run started"

# the monitor's rules are those of a walled run (the sandbox no longer backs them)
check "curl is still refused on the sealed profile" "$DENY" hook h1 Bash '{"command":"curl -s http://example.com"}'
check "ssh too" "$DENY" hook h1 Bash '{"command":"ssh host true"}'
check "a Bash call with allowed_domains still pauses the team" "$DENY" hook h1 Bash \
  '{"command":"python3 x.py","allowed_domains":["example.com"]}'
check "and that is a pause" . ls "$W/state/HALT"
check "reaching the board file is still refused" "$DENY" hook h1 Bash '{"command":"sqlite3 ../../state/board.db .tables"}'
check "another agent's workspace is still refused" "$DENY" hook h1 Bash '{"command":"cat ../h2/notes.txt"}'
check "the owner's .ssh is still refused" "$DENY" hook h1 Bash '{"command":"ls ~/.ssh"}'
check "the harness is still refused" "$DENY" hook h1 Bash "{\"command\":\"cat $W/harness/gateway.py\"}"
refute "a plain command in the workspace still passes" "$DENY" hook h1 Bash '{"command":"ls"}'
rm -f "$W/state/HALT"

# launch and status
out=$(launch 2>&1)
check "launch.sh warns" -i "$WARN" echo "$out"
check "and still starts every window" 'new-window .*-n reminders' cat "$STUB_DIR/calls.log"
check "boss.sh status still lists the profiles" 'profiles: lead=sealed h1=sealed h2=sealed' sh -c "cd '$W' && harness/boss.sh status"
start_gateway; wait_for 8 test -s "$W/state/heartbeat"

# a crash and a resume: the run stays unwalled
stop_gateway; rm -f "$STUB_DIR/session"
python3 -c "import time; open('$W/state/heartbeat','w').write(str(time.time() - 120))"
out=$(launch --resume 2>&1)
check "launch.sh --resume resumes" 'resuming' echo "$out"
check "and warns again" -i "$WARN" echo "$out"
check "the agents' sandbox is still off after the resume" '^False$' enabled h1
check "boss.sh status still says unwalled after the resume" -i 'unwalled' sh -c "cd '$W' && harness/boss.sh status"
check "offline_monitor.py says the run is unwalled" -i 'unwalled' sh -c "cd '$W' && python3 harness/offline_monitor.py"

# the archive keeps the fact: STATUS.txt, run.json, and a page rebuilt from the archived records
start_gateway; wait_for 8 test -s "$W/state/heartbeat"
land h1 a >/dev/null 2>&1; stop_gateway
mkdir -p "$TOP/dest"; ( cd "$W" && ./teardown.sh --archive "$TOP/dest" ) >/dev/null 2>&1
f=$(ls "$TOP/dest"/team-archive-*.tar.gz 2>/dev/null | head -1); mkdir -p "$TOP/x"; tar -xzf "${f:-/nonexistent}" -C "$TOP/x" 2>/dev/null
d=$(dirname "$(find "$TOP/x" -maxdepth 2 -name STATUS.txt | head -1)")
check "the archive's STATUS.txt says unwalled below its first line" -i 'unwalled' sh -c "tail -n +2 '$d/STATUS.txt'"
refute "and not on its first line" -i 'unwalled' head -1 "$d/STATUS.txt"
check "the archive's run.json keeps \"sandbox\": false" '"sandbox": false' cat "$d/records/run.json"
check "the archived page says unwalled" -i 'unwalled' cat "$d/records/report.html"
check "a page rebuilt from the archive says unwalled" -i 'unwalled' sh -c "cd '$REPO/template' && python3 harness/report.py --records '$d/records' -o '$TOP/rebuilt.html' >/dev/null && cat '$TOP/rebuilt.html'"

# a walled run's offline monitor and archive do not
mk_workdir lead h1; setup_wd; launch >/dev/null 2>&1
refute "a walled run's offline_monitor.py does not say unwalled" -i 'unwalled' sh -c "cd '$W' && python3 harness/offline_monitor.py"
mkdir -p "$TOP/dest"; ( cd "$W" && ./teardown.sh --archive "$TOP/dest" ) >/dev/null 2>&1
f=$(ls "$TOP/dest"/team-archive-*.tar.gz 2>/dev/null | head -1); mkdir -p "$TOP/x"; tar -xzf "${f:-/nonexistent}" -C "$TOP/x" 2>/dev/null
d=$(dirname "$(find "$TOP/x" -maxdepth 2 -name STATUS.txt | head -1)")
check "a walled archive was written" . ls "$d/STATUS.txt"
refute "a walled archive's STATUS.txt does not say unwalled" -i 'unwalled' cat "$d/STATUS.txt"
check "and its run.json says the sandbox was on" '"sandbox": true' cat "$d/records/run.json"

finish
