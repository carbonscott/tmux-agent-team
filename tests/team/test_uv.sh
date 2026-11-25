#!/bin/bash
# Team tests for `uv`: every Python call of the template goes through uv. setup.sh puts one
# interpreter in tools/py; the scripts, the gateway, the monitor and team run on it; nothing
# calls a python3 from PATH.
. "$(dirname "$0")/../lib.sh"

mk_workdir lead h1 h2
# From here on a python or python3 found on PATH is a trap: it records the call and fails.
TRAP=$TOP/trap; mkdir -p "$TRAP"
for n in python python3; do
  printf '#!/bin/sh\necho "$0 $*" >> "%s/calls"\nexit 97\n' "$TRAP" > "$TRAP/$n"; chmod +x "$TRAP/$n"
done
: > "$TRAP/calls"
trapped() { ( export PATH="$TRAP:$PATH"; "$@" ); }

trapped setup_wd && ok "setup.sh succeeds with no usable python3 on PATH" || no "setup.sh succeeds with no usable python3 on PATH" "$(cat "$TOP/setup.log")"
check "setup.sh puts the work directory's Python in tools/py" '^3\.[0-9]+' "$W/tools/py/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])'
check "tools/py is a uv environment" '^uv = ' cat "$W/tools/py/pyvenv.cfg"
check "the agents' python3 is that Python (tools/bin is on their PATH)" "$W/tools/py/bin/python" cat "$W/tools/bin/python3"
check "the monitor is started with that Python" "\"command\": \"$W/tools/py/bin/python $W/harness/hook.py h1\"" cat "$W/harness/settings/h1.json"
check "setup.sh asks for uv, not python3" 'for t in tmux git uv bwrap claude' cat "$W/setup.sh"
check "setup.sh stops with a clear message when uv is missing" 'missing: uv' sh -c "cd '$W' && PATH=$TOP/nouv:/usr/bin:/bin ./setup.sh 2>&1; true"

trapped launch > "$TOP/launch.out" 2>&1 && ok "launch.sh succeeds" || no "launch.sh succeeds" "$(cat "$TOP/launch.out")"
check "the gateway window is started through harness/py" "$W/harness/py -u $W/harness/gateway.py" cat "$STUB_DIR/calls.log"
( cd "$W" && PATH="$TRAP:$PATH" exec "$W/harness/py" -u "$W/harness/gateway.py" ) >> "$TOP/gw.log" 2>&1 & GWPID=$!
sleep 1; kill -0 "$GWPID" 2>/dev/null && ok "the gateway runs" || no "the gateway runs" "$(cat "$TOP/gw.log")"
check "team runs on the work directory's Python" '^h1$' trapped as h1 team whoami
check "a right answer lands" 'ACCEPTED' trapped land h1 a
check "boss.sh status works" 'done on main: a' trapped "$W/harness/boss.sh" status
check "the monitor answers" '^$' sh -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"cwd\":\"$W/ws/h1\"}' | PATH='$TRAP':\$PATH '$W/tools/py/bin/python' '$W/harness/hook.py' h1"
check "verify.py works through harness/py" '1 of 3|of 3 statements' trapped "$W/harness/py" "$W/harness/verify.py"
check "report.py works through harness/py" '^report: ' trapped "$W/harness/py" "$W/harness/report.py" -o "$TOP/r.html"
trapped sh -c "cd '$W' && ./teardown.sh" > "$TOP/td.out" 2>&1; GWPID=
check "teardown.sh works" 'nothing from this run is still running' cat "$TOP/td.out"
# uv itself tries each python on PATH while looking for an interpreter (get_interpreter_info): that
# is uv choosing, not a script of the template calling python3
ours() { grep -v get_interpreter_info "$TRAP/calls"; true; }
refute "no script called a python or python3 from PATH" . ours

# before setup.sh, and after --purge, harness/py falls back to a Python that uv finds or fetches
( cd "$W" && ./teardown.sh --purge ) > /dev/null 2>&1
[ -e "$W/tools" ] && no "--purge deletes tools/" || ok "--purge deletes tools/"
check "harness/py still runs Python once tools/ is gone (uv run)" '^fallback-ok$' trapped "$W/harness/py" -c 'print("fallback-ok")'
: > "$TRAP/calls"; trapped "$W/harness/py" "$W/harness/profiles.py" --list > "$TOP/p.out" 2>&1
check "profiles.py runs before setup" 'lead=sealed' cat "$TOP/p.out"
refute "and still calls no python3 from PATH" . ours

# the sources: no script names python3, apart from the two commands the self-test asks an agent to type
left=$(grep -rnE '(^|[^[:alnum:]_./-])python3?([[:space:]]|$)' "$REPO/template" --include='*.sh' --include='*.py' --include=team --include=py \
  | grep -v -e '/task/seed/' -e '/task/probe/' -e "agents' python3" -e 'system python3' -e 'for n in python python3' \
            -e 'selftest.sh:.*urllib.request' -e 'harness/py:' | grep -v ':[[:space:]]*#')
[ -z "$left" ] && ok "no template script calls python or python3 by name" || no "no template script calls python or python3 by name" "$left"
refute "no template script starts with a python3 shebang" . sh -c "grep -rlE '^#!.*python' '$REPO/template' --include='*.sh' --include='*.py' --include=team | grep -v /task/"
check "SKILL.md lists uv as a requirement" 'Linux with `tmux`, `git`, `uv`' cat "$REPO/SKILL.md"
refute "SKILL.md no longer tells the boss to type python3" 'python3 harness/' cat "$REPO/SKILL.md"
check "SKILL.md says where the Python comes from" -i 'tools/py' cat "$REPO/SKILL.md"
finish
