#!/bin/bash
# Regression: what the template did before must still work. It runs the template's own
# pre-launch test and then a whole run of a toy task, with scripted "agents" in place of
# Claude Code sessions.
. "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

bad=""
for f in template/*.sh template/harness/*.sh; do bash -n "$f" 2>/dev/null || bad="$bad $f"; done
for f in template/harness/*.py template/bin/team; do
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" 2>/dev/null || bad="$bad $f"
done
[ -z "$bad" ] && ok "every script parses" || no "every script parses" "$bad"

mk_workdir lead h1 h2 h3
setup_wd && ok "setup.sh completes" || no "setup.sh completes"
out=$(cd "$W" && harness/test_gateway.sh 2>&1)
while IFS= read -r label; do
  grep -qF "PASS  $label" <<<"$out" && ok "pre-launch: $label" || no "pre-launch: $label" "$out"
done <<'LABELS'
the lead is seen as lead
the lead can create a table
a helper's rows carry the helper's name
a helper cannot delete rows
a helper cannot create tables
a helper cannot drop the lead's table
nobody can attach another database file
a runaway statement is cancelled
a failed request changes nothing
two simultaneous claims produce one winner
a change outside the allowed paths is rejected
the task's wrong answer is rejected
the task's right answer is accepted
a direct push is refused
requests are logged under the sender's name
LABELS
refute "pre-launch: nothing fails" '^FAIL' echo "$out"

check "launch.sh starts the session"        'tmux new-session'  sh -c "cd '$W' && ./launch.sh >/dev/null 2>&1; cat '$STUB_DIR/calls.log'"
for a in lead h1 h2 h3; do check "launch.sh opens a window for $a" "new-window .*-n $a " cat "$STUB_DIR/calls.log"; done
check "the clock is set to the budget"      '^ok$' python3 -c "
import time; d = float(open('$W/state/deadline').read()) - time.time(); print('ok' if 1700 < d <= 1800 else d)"
start_gateway
check "an agent sees the run state"          'done on main \(0/3\)'        as h1 team status
check "a right answer lands"                 'ACCEPTED: merged into main'  land h1 a
check "a second agent lands another"         'ACCEPTED: merged into main'  land h2 b
check "the status counts them"               'done on main \(2/3\)'        as h3 team status
check "a wrong answer is rejected"           'REJECTED by the check'       land h3 c "wrong c" no
refute "an unfinished run is not complete"   .                             sh -c "ls '$W/state/DONE' 2>/dev/null"
check "an agent may not stop yet"            '"decision": "block"'         sh -c "echo '{}' | python3 '$W/harness/keepgoing.py' h1"
check "the last answer completes the run"    'RUN COMPLETE'                land h3 c "right c" ok
check "wait-run.sh reports DONE"             '^DONE'                       sh -c "cd '$W' && harness/wait-run.sh 1 | head -1"
check "an agent may stop now"                '^$'                          sh -c "echo '{}' | python3 '$W/harness/keepgoing.py' h1"
check "verify.py passes on a fresh checkout" '3 of 3 statements pass'      sh -c "cd '$W' && python3 harness/verify.py"
check "boss.sh status shows the finish"      'RUN COMPLETE'                sh -c "cd '$W' && harness/boss.sh status"
check "the records list three merges"        'merges landed: 3'            sh -c "cd '$W' && python3 harness/offline_monitor.py"
check "the monitor blocks reading the harness" 'BLOCKED by the action monitor' sh -c "
  echo '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$W/harness/gateway.py\"},\"cwd\":\"$W/ws/h1\"}' | python3 '$W/harness/hook.py' h1"
check "a pause refuses the door"             'TEAM PAUSED'                 as h2 team status
check "resume clears the pause"              'pause cleared'               sh -c "cd '$W' && harness/boss.sh resume"
check "teardown.sh --purge deletes the run"  'runtime files deleted'       sh -c "cd '$W' && ./teardown.sh --purge"
refute "nothing of the run is left"          .                             sh -c "ls -d '$W/ws' '$W/state' '$W/central.git' 2>/dev/null"

# a new board, many agents: every agent's door must open at every start
mk_workdir lead a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11; mkdir -p "$W/state" "$W/records"; lost=0
for i in $(seq 15); do
  rm -f "$W"/state/board.db*
  python3 -u "$W/harness/gateway.py" > "$TOP/gw.log" 2>&1 & p=$!
  sleep 0.5; kill $p 2>/dev/null; wait $p 2>/dev/null
  grep -q Traceback "$TOP/gw.log" && lost=$((lost+1))
done
[ $lost -eq 0 ] && ok "every agent's door opens on a new board, 15 starts in a row" || no "every agent's door opens on a new board, 15 starts in a row" "$lost of 15 starts lost an agent: $(grep -m1 Error "$TOP/gw.log")"
finish
