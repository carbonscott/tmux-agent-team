#!/bin/bash
# Tests for the findings of the live proof runs: each section fails on the code before its fix.
#   bash tests/team/test_fixes.sh [section ...]     (default: every section)
. "$(dirname "$0")/../lib.sh"
hook() { rm -f "$W/state/HALT"; echo "{\"tool_name\":\"$2\",\"tool_input\":$3,\"cwd\":\"$W/ws/$1\"}" | python3 "$W/harness/hook.py" "$1"; }
bash_hook() { python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$2" > "$TOP/in.json"
  hook "$1" Bash "$(cat "$TOP/in.json")"; }
halted() { [ -e "$W/state/HALT" ]; }
want() { case " ${SECTIONS:-all} " in *" all "*|*" $1 "*) return 0;; esac; return 1; }
SECTIONS="$*"
BLOCK='BLOCKED by the action monitor'

# ---- A1: the monitor's rule for .claude, .ssh and board.db is the bare word again
if want A1; then
mk_workdir lead h1; setup_wd
for c in "wc -c ~/'.claude'/history.jsonl" "cat ~/{.claude,x}/history.jsonl" 'd=.claude; cat ~/$d/history.jsonl' \
         'cat "$HOME/.claude/history.jsonl"' "ls ~/'.ssh'" 'k=.ssh; ls ~/$k' "sqlite3 ../../state/board.db .dump" \
         "cd ../../state && sqlite3 board.db"; do
  bash_hook h1 "$c" > "$TOP/out" 2>&1
  grep -q "$BLOCK" "$TOP/out" && halted && ok "A1 a HARD block (pause): $c" || no "A1 a HARD block (pause): $c" "$(cat "$TOP/out")"
done
bash_hook h1 "grep -rn .claude ." > "$TOP/out"; halted && ok "A1 the known false alarm still pauses (fail closed): grep .claude" || no "A1 the known false alarm still pauses (fail closed): grep .claude"
check "A1 the rule is exactly the one on main" '^ok$' python3 -c "
import re; t = open('$W/harness/hook.py').read()
print('ok' if r'(r\"\.claude\b|\.ssh\b|/run/user\b\", \"touching the agent loop or credentials\")' in t
      and r'(r\"\bboard\.db\b\", \"reaching the board directly (use \`team sql\`)\")' in t else 'no')"
refute "A1 an ordinary command still passes" "$BLOCK" bash_hook h1 "git status && ls out"
check "A1 SKILL.md names the known false alarm and what to do" 'grep.*\.claude.*boss.sh resume' cat "$REPO/SKILL.md"
fi

# ---- A2: the sandbox hides every entry of ~/.claude but shell-snapshots, and every dot-entry in ~ but a few
if want A2; then
mk_workdir lead h1; setup_wd
H=$TOP     # a fake home directory that holds the work directory ($TOP/wd)
mkdir -p "$H/.claude/shell-snapshots" "$H/.claude/projects" "$H/.aws" "$H/.somethingnew" "$H/.local/bin" "$H/.local/share/keys" "$H/.local/share/uv" "$H/.cache/uv" "$H/.cache/gh"
touch "$H/.gitconfig"
echo secret > "$H/.claude/history.jsonl"; echo ': ok' > "$H/.claude/shell-snapshots/x.sh"; touch "$H/.bashrc" "$H/.profile" "$H/.claude.json"
deny_of() { python3 -c "import json,sys; print('\n'.join(json.load(open(sys.argv[1]))['sandbox']['filesystem']['denyRead']))" "$W/harness/settings/h1.json"; }
( cd "$W" && env -u CLAUDE_CONFIG_DIR HOME="$H" python3 harness/mk_settings.py ) >/dev/null
d=$(deny_of)
for p in .claude/history.jsonl .claude/projects .aws .somethingnew .claude.json .gitconfig .local/share/keys .cache/gh stub; do
  grep -qxF "$H/$p" <<<"$d" && ok "A2 hidden: ~/$p" || no "A2 hidden: ~/$p" "$d"
done
for p in .claude/shell-snapshots .claude .bashrc .profile .local .local/bin .local/share .local/share/uv .cache .cache/uv wd; do
  grep -qxF "$H/$p" <<<"$d" && no "A2 left readable: ~/$p" "$d" || ok "A2 left readable: ~/$p"
done
check "A2 Git is pointed at an empty global config, since ~/.gitconfig is hidden" '"GIT_CONFIG_GLOBAL": "/dev/null"' cat "$W/harness/settings/h1.json"
setcfg extra_readable_home_paths '[".cache/gh"]'
( cd "$W" && env -u CLAUDE_CONFIG_DIR HOME="$H" python3 harness/mk_settings.py ) >/dev/null
grep -qxF "$H/.cache/gh" <<<"$(deny_of)" && no "A2 extra_readable_home_paths opens a path" "$(deny_of)" || ok "A2 extra_readable_home_paths opens a path"
refute "A2 the home directory itself is not hidden" "^$H\$" echo "$d"
# CLAUDE_CONFIG_DIR: that folder is treated like ~/.claude, and ~/.claude is then hidden whole
mkdir -p "$H/.claude-alt/shell-snapshots"; echo secret > "$H/.claude-alt/history.jsonl"
( cd "$W" && HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude-alt" python3 harness/mk_settings.py ) >/dev/null
d=$(deny_of)
grep -qxF "$H/.claude-alt/history.jsonl" <<<"$d" && ok "A2 CLAUDE_CONFIG_DIR: its history is hidden" || no "A2 CLAUDE_CONFIG_DIR: its history is hidden" "$d"
grep -qxF "$H/.claude-alt/shell-snapshots" <<<"$d" && no "A2 CLAUDE_CONFIG_DIR: its shell-snapshots stay readable" "$d" || ok "A2 CLAUDE_CONFIG_DIR: its shell-snapshots stay readable"
grep -qxF "$H/.claude" <<<"$d" && ok "A2 CLAUDE_CONFIG_DIR: ~/.claude is hidden whole" || no "A2 CLAUDE_CONFIG_DIR: ~/.claude is hidden whole" "$d"
# a work directory outside the home directory: everything in it but the shell's dot-files is hidden
mkdir -p "$TOP/home2/codes" "$TOP/home2/.claude/shell-snapshots"; touch "$TOP/home2/.bashrc" "$TOP/home2/notes.txt"
( cd "$W" && env -u CLAUDE_CONFIG_DIR HOME="$TOP/home2" python3 harness/mk_settings.py ) >/dev/null
d=$(deny_of)
grep -qxF "$TOP/home2/codes" <<<"$d" && grep -qxF "$TOP/home2/notes.txt" <<<"$d" && ok "A2 a work directory outside ~ still hides the home directory's folders" || no "A2 a work directory outside ~ still hides the home directory's folders" "$d"
check "A2 references/claude-code.md lists what stays readable" 'shell-snapshots' cat "$REPO/references/claude-code.md"
check "A2 launch.sh writes the settings again, so entries made after setup.sh are hidden too" 'mk_settings.py' cat "$W/launch.sh"
fi

# ---- selftest.sh, driven by a fake claude that sends each numbered step through the real monitor
# (A3: a second session shows ~/.claude's history is hidden; J: step 14; M: the tested agent's profile)
fake_claude() { mkdir -p "$TOP/fake"; cat > "$TOP/fake/claude" <<'PY'
#!/usr/bin/python3
import json, os, re, subprocess, sys
a = sys.argv[1:]; prompt = a[a.index("--") + 1] if "--" in a else ""
ws = os.getcwd(); R = os.path.dirname(os.path.dirname(ws)); agent = os.path.basename(ws)
log = open(os.environ["STUB_DIR"] + "/selftest.calls", "a")
log.write(json.dumps({"argv": a[:a.index("--")] if "--" in a else a, "halt_at_start": os.path.exists(R + "/state/HALT")}) + "\n")
for n, cmd in re.findall(r"^(\d+)\. (.*)$", prompt, re.M):
    ti = {"command": cmd, "description": "step " + n}
    if "allowed_domains" in cmd:
        ti = {"command": cmd.split("   (")[0], "description": "step " + n, "allowed_domains": ["example.com"]}
    calls = [("Bash", ti, {})]
    if "Agent tool" in cmd:      # the subagent runs the command and hands its result back
        calls = [("Agent", {"prompt": cmd, "description": "step " + n, "subagent_type": "general-purpose"}, {}),
                 ("Bash", {"command": "echo handback-ok"}, {"agent_id": "s1", "agent_type": "general-purpose"}),
                 ("SubagentHandback", {"message": "handback-ok"}, {"agent_id": "s1", "agent_type": "general-purpose"})]
    out = ""
    for tool, ti, more in calls:
        out += subprocess.run([sys.executable, R + "/harness/hook.py", agent], input=json.dumps(
            dict({"tool_name": tool, "tool_input": ti, "cwd": ws}, **more)), capture_output=True, text=True).stdout
    log.write(json.dumps({"step": int(n), "command": cmd, "decision": "deny" if "deny" in out else "pass",
                          "why": out[:300]}) + "\n")
PY
  chmod +x "$TOP/fake/claude"; }
selftest() { : > "$STUB_DIR/selftest.calls"; ( cd "$W" && PATH="$TOP/fake:$PATH" timeout 60 harness/selftest.sh "$@" ) 2>&1; }
calls() { python3 -c "import json,sys; [print(json.dumps(json.loads(l))) for l in open(sys.argv[1])]" "$STUB_DIR/selftest.calls"; }

if want A3; then
mk_workdir lead h1 h2; setup_wd; fake_claude
out=$(selftest)
check "A3 selftest: the pause of step 11 is seen" 'PASS  the violation in step 11 paused the team' echo "$out"
check "A3 selftest: the door refuses while paused" 'PASS  the door refuses requests while paused' echo "$out"
check "A3 selftest: the monitor refuses while paused" 'PASS  the monitor refuses every call while paused' echo "$out"
check "A3 selftest: a second session runs" '^2$' sh -c "grep -c argv '$STUB_DIR/selftest.calls'"
check "A3 selftest: the second session starts with the pause cleared" '"halt_at_start": false' sh -c "grep argv '$STUB_DIR/selftest.calls' | tail -1"
check "A3 selftest: step 13 reads the history file without naming .claude" '"step": 13, "command": "c=.cla; wc -c < ~/\$\{c\}ude/history.jsonl", "decision": "pass"' calls
check "A3 selftest: the expectations name step 13" '13  prints 0 or an error' echo "$out"
refute "A3 selftest: it cleans up after itself" . sh -c "ls '$W/state/HALT' '$W/state/selftest.json' 2>/dev/null"
fi

# ---- J: a Bash call that asks for network (allowed_domains) or carries a parameter the monitor does not know
if want J; then
mk_workdir lead h1 h2 h3; setcfg agent_profiles '{"h1": "research", "h2": "allied", "h3": "open"}'; setup_wd
NET='{"command":"python3 -c \"import urllib.request\"","description":"fetch","allowed_domains":["example.com"]}'
for a in lead h1 h2 h3; do
  hook $a Bash "$NET" > "$TOP/out" 2>&1
  grep -q "$BLOCK" "$TOP/out" && halted && ok "J allowed_domains is a HARD block (pause) for $a" || no "J allowed_domains is a HARD block (pause) for $a" "$(cat "$TOP/out")"
done
check "J the HALT names allowed_domains" 'allowed_domains' cat "$W/state/HALT"
check "J and the record says block" '"allowed_domains": \["example.com"\]}, "decision": "block"' tail -1 "$W/records/actions.jsonl"
for extra in '"dangerouslyDisableSandbox":true' '"dangerouslyDisableSandbox":false' '"sandbox":"off"' '"network":true'; do
  hook h1 Bash "{\"command\":\"ls\",$extra}" > "$TOP/out" 2>&1
  grep -q "$BLOCK" "$TOP/out" && halted && ok "J an unknown Bash parameter is a HARD block: $extra" || no "J an unknown Bash parameter is a HARD block: $extra" "$(cat "$TOP/out")"
done
for ti in '{"command":"ls"}' '{"command":"ls","description":"list"}' '{"command":"ls","description":"list","timeout":60000}' \
          '{"command":"ls","run_in_background":true}' '{"command":"ls","allowed_domains":[]}'; do
  hook h1 Bash "$ti" > "$TOP/out" 2>&1
  [ ! -s "$TOP/out" ] && ! halted && ok "J a normal Bash call passes: $ti" || no "J a normal Bash call passes: $ti" "$(cat "$TOP/out")"
done
fake_claude; out=$(selftest lead)
check "J selftest: step 14 asks for allowed_domains and is blocked" '"step": 14, .*"decision": "deny"' calls
check "J selftest: and says so" 'PASS  a Bash call with allowed_domains \(step 14\) paused the team' echo "$out"
check "J selftest: the expectations name step 14" '14  BLOCKED by the action monitor' echo "$out"
for f in SKILL.md references/design.md template/docs/helper.md template/docs/lead.md template/harness/profiles.py; do
  check "J $f says the monitor rule keeps the shell offline" 'allowed_domains' cat "$REPO/$f"
done
fi

# ---- K: a subagent can hand its result back on allied and open
if want K; then
mk_workdir lead h1 h2 h3; setcfg agent_profiles '{"h1": "research", "h2": "allied", "h3": "open"}'; setup_wd
sub() { rm -f "$W/state/HALT"; echo "{\"tool_name\":\"SubagentHandback\",\"tool_input\":{\"message\":\"done\"},\"cwd\":\"$W/ws/$1\"$2}" | python3 "$W/harness/hook.py" "$1"; }
IN=',"agent_id":"a1","agent_type":"web-fetch"'
DENY='"permissionDecision": "deny"'
refute "K allied: a subagent's SubagentHandback passes" "$DENY" sub h2 "$IN"
check  "K and is recorded as passed, inside the subagent" '"tool": "SubagentHandback".*"decision": "pass".*"subagent": "web-fetch"' tail -1 "$W/records/actions.jsonl"
refute "K open: a subagent's SubagentHandback passes" "$DENY" sub h3 "$IN"
check  "K research (no Agent): refused" "$DENY" sub h1 "$IN"
check  "K sealed: refused" "$DENY" sub lead "$IN"
check  "K a SubagentHandback from the main session (no subagent) is refused" "$DENY" sub h2 ""
halted && no "K a refused SubagentHandback does not pause the team" || ok "K a refused SubagentHandback does not pause the team"
echo '{"ts": 0, "agent": "h2", "reason": "test"}' > "$W/state/HALT"
check "K a pause refuses it too" "$DENY" sh -c "echo '{\"tool_name\":\"SubagentHandback\",\"tool_input\":{\"message\":\"x\"},\"cwd\":\"$W/ws/h2\"$IN}' | python3 '$W/harness/hook.py' h2"
rm -f "$W/state/HALT"
check "K references/claude-code.md names SubagentHandback" 'SubagentHandback' cat "$REPO/references/claude-code.md"
fi

# ---- M: selftest.sh starts its sessions with the tested agent's profile, as run-agent.sh would
if want M; then
mk_workdir lead h1 h2 h3; setcfg agent_profiles '{"h1": "research", "h2": "allied", "h3": "open"}'; setup_wd; fake_claude
argv_tools() { python3 -c "
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if 'argv' in d:
        a = d['argv']; print(a[a.index('--tools') + 1], 'slash-off' if '--disable-slash-commands' in a else 'slash-on')" "$STUB_DIR/selftest.calls" | sort -u; }
want_tools() { read -r _ t s <<<"$(cd "$W" && python3 harness/profiles.py "$1")"; echo "$t $s"; }
for a in lead h1 h2 h3; do
  out=$(selftest $a)
  [ "$(argv_tools)" = "$(want_tools $a)" ] && ok "M selftest.sh $a: both sessions get $a's tools and slash setting" || no "M selftest.sh $a: both sessions get $a's tools and slash setting" "$(argv_tools) / $(want_tools $a)"
  check "M selftest.sh $a: the header names the profile" "Session under test: $a, profile $(cd "$W" && python3 harness/profiles.py $a | cut -d' ' -f1)" echo "$out"
  check "M selftest.sh $a: the allowed_domains step pauses the team" 'PASS  a Bash call with allowed_domains' echo "$out"
done
out=$(selftest)
check "M without an argument the last agent is tested" 'Session under test: h3, profile open' echo "$out"
out=$(selftest h2)
check "M allied: the subagent step is expected" '14  handback-ok' echo "$out"
check "M allied: and the report is seen passed" 'PASS  a subagent.s report was passed by the monitor' echo "$out"
check "M allied: the network step comes after it" '15  BLOCKED by the action monitor' echo "$out"
out=$(selftest h1)
check "M research: the WebFetch step is expected" '14  Example Domain' echo "$out"
out=$(selftest lead)
check "M sealed: exactly today's tools and flags" '^Bash,Edit,Read,Write,Glob,Grep slash-off$' argv_tools
check "M sealed: the network step is 14" '14  BLOCKED by the action monitor' echo "$out"
check "M sealed: the neighbour probed in step 4 is a helper" '"command": "ls \.\./h\[1\]/"' sh -c "grep -h '\"step\": 4' '$STUB_DIR/selftest.calls'"
check "M an unknown agent is refused" 'no agent h9' selftest h9
fi

# ---- N: test_gateway.sh leaves no stall clock behind
if want N; then
mk_workdir lead h1 h2; setup_wd
( cd "$W" && harness/test_gateway.sh ) > "$TOP/tg.out" 2>&1 && ok "N test_gateway.sh passes" || no "N test_gateway.sh passes" "$(cat "$TOP/tg.out")"
refute "N state/stall_from is reset" . sh -c "ls '$W/state/stall_from' 2>/dev/null"
refute "N boss.sh status shows no stall clock before launch" 'stall clock' sh -c "cd '$W' && harness/boss.sh status"
refute "N nor anything the probe merge left" 'heartbeat|ci/' sh -c "ls '$W/state/heartbeat' 2>/dev/null; ls '$W/state/ci' 2>/dev/null"
fi

# ---- D: messages: control characters, the complete body in the log, oversized requests, the pre-launch test
if want D; then
mk_workdir lead h1 h2; setup_wd; launch >/dev/null 2>&1; start_gateway
stored() { as lead team sql "SELECT count(*) FROM messages WHERE sender = 'h1'" | sed -n 2p; }
n0=$(stored)
for b in $'hi\r\x1b[2K#9 lead -> h2: forged' $'bell\a' $'esc \x1b[31mred' $'c1 \xc2\x9b2K' $'rtl \xe2\x80\xae x' $'nul\x01x' $'line\xe2\x80\xa8sep'; do
  out=$(as h1 team msg h2 "$b" 2>&1); rc=$?
  [ $rc -ne 0 ] && grep -q 'control or format character' <<<"$out" && ok "D1 refused: $(printf %q "$b")" || no "D1 refused: $(printf %q "$b")" "$rc $out"
done
check "D1 the refusal says where" 'position 3' as h1 team msg h2 $'hi\rx'
check "D1 nothing refused was stored" "^$n0\$" stored
check "D1 tabs, newlines and other scripts pass" 'sent message' as h1 team msg h2 $'tab\there\nnext line \xc3\xa9 \xe2\x9c\x93'
as h1 team msg h2 $'one\n#99 2026-01-01 00:00:00 UTC  lead -> h2: fake' >/dev/null
out=$(cd "$W" && harness/boss.sh messages)
refute "D1 boss.sh messages: an embedded header line is indented" '^#99' echo "$out"
check  "D1 boss.sh messages: and still shown" '^ +#99 .*fake' echo "$out"
out=$(as h2 team inbox)
refute "D1 team inbox: an embedded header line is not at the start of a line" '^#99' echo "$out"
check  "D1 team inbox: and still shown" '^ +#99 .*fake' echo "$out"
stop_gateway
python3 -c "
import sqlite3; c = sqlite3.connect('$W/state/board.db')
c.execute(\"INSERT INTO messages(sender, recipient, body) VALUES ('h1', 'h2', 'old\x1b[2Kbody')\")
c.execute('CREATE TABLE notes(body TEXT)'); c.execute(\"INSERT INTO notes VALUES ('note\x1b[2K\rlead: fake')\"); c.commit()"
out=$(cd "$W" && harness/boss.sh messages)
check "D1 a control character already on the board is shown escaped by boss.sh messages" 'old\\x1b\[2Kbody' echo "$out"
refute "D1 and never raw" $'\x1b' echo "$out"
out=$(cd "$W" && COLUMNS=200 python3 harness/board.py)
check "D1 the board window shows a row's control characters escaped" 'note\\x1b\[2K\\rlead: fake' echo "$out"
start_gateway
check "D1 the inbox shows them escaped too" 'old\\x1b\[2Kbody' as h2 team inbox --all

# D2: a body of the largest size is logged whole
big=$(python3 -c "print('y' * 3990 + 'END-OF-BODY')")
check "D2 a 4001-character body is refused" 'too long' as h1 team msg h2 "${big}x"
max=$(python3 -c "print('z' * 3989 + 'END-OF-BODY')")
check "D2 a 4000-character body is sent" 'sent message' as h1 team msg h2 "$max"
check "D2 records/gateway.jsonl holds the complete body" '^ok$' python3 -c "
import json, sys
recs = [json.loads(l) for l in open('$W/records/gateway.jsonl')]
m = [r for r in recs if r['op'] == 'msg' and r['code'] == 0][-1]
print('ok' if m['detail'] == 'to h2: ' + 'z' * 3989 + 'END-OF-BODY' else len(m['detail']))"

# D3: a request over 1 MiB is answered and logged, not dropped
python3 -c "print('SELECT 1; --' + 'x' * (1 << 20))" > "$TOP/big.sql"
out=$(as h1 timeout 30 team sql -f "$TOP/big.sql" 2>&1); rc=$?
[ $rc -ne 0 ] && [ $rc -ne 75 ] && [ $rc -ne 124 ] && ok "D3 an oversized request gets an answer (exit $rc)" || no "D3 an oversized request gets an answer" "$rc $out"
check "D3 the answer says why" 'too large' echo "$out"
check "D3 and it is logged under the sender" '"agent": "h1", "op": "sql", "detail": "request of [0-9]+ bytes refused' cat "$W/records/gateway.jsonl"
printf '{"id": "abc", "op": ' > "$W/ws/h1/.gw/req/0123abcd.json"
wait_for 5 test -e "$W/ws/h1/.gw/resp/0123abcd.json" && ok "D3 a request that is not JSON is answered too" || no "D3 a request that is not JSON is answered too"
check "D3 with an error" '"code": 2' cat "$W/ws/h1/.gw/resp/0123abcd.json"
rm -f "$W/ws/h1/.gw/resp/0123abcd.json"
as h1 team status >/dev/null && ok "D3 the door still works afterwards" || no "D3 the door still works afterwards"
stop_gateway

# D4: the pre-launch test checks messages
mk_workdir lead h1 h2; setup_wd
out=$(cd "$W" && harness/test_gateway.sh 2>&1)
check "D4 test_gateway.sh: a message reaches its recipient" 'PASS  a message reaches its recipient, under the sender' echo "$out"
check "D4 test_gateway.sh: nobody can write the messages table" 'PASS  nobody can write the messages table' echo "$out"
check "D4 test_gateway.sh: a message with control characters is refused" 'PASS  a message with control characters is refused' echo "$out"
refute "D4 test_gateway.sh: nothing fails" '^FAIL' echo "$out"
fi

# ---- E: teardown.sh finds the gateway however it was started, and "nothing is still running" is certain
if want E; then
mk_workdir lead h1; setup_wd; launch >/dev/null 2>&1
( cd "$W/harness" && exec python3 -u gateway.py ) > "$TOP/gw-rel.log" 2>&1 & rel=$!
wait_for 8 test -s "$W/state/heartbeat"
check "E the gateway records its pid" "^$rel\$" cat "$W/state/gateway.pid"
out=$(cd "$W" && ./teardown.sh 2>&1)
sleep 0.5; kill -0 $rel 2>/dev/null && { no "E a gateway started with a relative path is stopped" "$out"; kill $rel; } || ok "E a gateway started with a relative path is stopped"
check "E and teardown says so" 'gateway stopped' echo "$out"
check "E then nothing is running" 'nothing from this run is still running' echo "$out"
wait $rel 2>/dev/null
# something else holds the gateway's lock: it is not killed, and teardown does not claim nothing runs
python3 -c "
import fcntl, sys, time; f = open(sys.argv[1]); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(60)" "$W/config.json" & holder=$!
sleep 0.5
out=$(cd "$W" && ./teardown.sh 2>&1)
refute "E while the lock on config.json is held, teardown does not say nothing is running" 'nothing from this run is still running' echo "$out"
check "E it names the holder" "config.json.*$holder|$holder.*config.json" echo "$out"
kill -0 $holder 2>/dev/null && ok "E a lock holder that is not a gateway is not killed" || no "E a lock holder that is not a gateway is not killed"
kill $holder; wait $holder 2>/dev/null
fi

# ---- F: launch.sh --resume trusts the gateway's lock, and falls back to the heartbeat only without it
if want F; then
mk_workdir lead h1; setup_wd; launch >/dev/null 2>&1; start_gateway
wait_for 8 test -s "$W/state/heartbeat"
stop_gateway; rm -f "$STUB_DIR/session"      # the gateway is gone, but it beat a moment ago
out=$(cd "$W" && ./launch.sh --resume 2>&1); rc=$?
[ $rc -eq 0 ] && ok "F a resume right after the gateway stopped goes ahead (its lock is free)" || no "F a resume right after the gateway stopped goes ahead (its lock is free)" "$out"
# a gateway that is alive but not beating (stopped with SIGSTOP), with an old heartbeat
rm -f "$STUB_DIR/session"; start_gateway; wait_for 8 test -s "$W/state/heartbeat"
rm -f "$STUB_DIR/session"; kill -STOP $GWPID
python3 -c "import time; open('$W/state/heartbeat','w').write(str(time.time() - 600))"
D0=$(cat "$W/state/deadline")
out=$(cd "$W" && ./launch.sh --resume 2>&1); rc=$?
[ $rc -ne 0 ] && ok "F a resume is refused while a gateway holds the lock, whatever the heartbeat says" || no "F a resume is refused while a gateway holds the lock, whatever the heartbeat says" "$out"
check "F the refusal names the lock and the pid" "config.json.*$GWPID|$GWPID.*config.json" echo "$out"
check "F and keeps the words the resume test looks for" 'gateway may still be serving' echo "$out"
check "F the refusal moves no clock" "^$D0\$" cat "$W/state/deadline"
kill -CONT $GWPID; stop_gateway
fi

# ---- G: while a run is down or paused, boss.sh status shows the clocks as they stopped
if want G; then
mk_workdir lead h1; setcfg stall_min 30; setup_wd; launch >/dev/null 2>&1; start_gateway
wait_for 8 test -s "$W/state/heartbeat"
stop_gateway; rm -f "$STUB_DIR/session"      # the crash
python3 -c "
import time; now = time.time()
open('$W/state/heartbeat', 'w').write(str(now - 600))      # down for ten minutes
open('$W/state/deadline', 'w').write(str(now + 300))       # 5 min left now, 15 at the last beat
open('$W/state/stall_from', 'w').write(str(now - 660))     # 1 min without a merge at the last beat, 11 now"
out=$(cd "$W" && harness/boss.sh status)
check "G INTERRUPTED: time left is shown as at the last heartbeat" 'time left: 1[45] min' echo "$out"
check "G with a note that --resume gives the time down back" 'time left: [0-9]+ min \(as at the last heartbeat .*launch\.sh --resume' echo "$out"
check "G the stall clock is frozen too" 'stall clock: 1 of 30 min.*\(stopped' echo "$out"
check "G the run is still reported as interrupted" 'INTERRUPTED' echo "$out"
# a live run that is paused: the clocks stop at the start of the pause
: > "$STUB_DIR/session"; python3 -c "
import json, time; now = time.time()
open('$W/state/heartbeat', 'w').write(str(now)); open('$W/state/deadline', 'w').write(str(now + 300))
open('$W/state/stall_from', 'w').write(str(now - 360))
json.dump(dict(ts=now - 300, agent='h1', reason='test'), open('$W/state/HALT', 'w'))"
out=$(cd "$W" && harness/boss.sh status)
check "G paused: time left is shown as at the start of the pause" 'time left: (9|10) min \(as at the start of the pause' echo "$out"
check "G paused: the stall clock stops at the pause" 'stall clock: 1 of 30 min' echo "$out"
rm -f "$W/state/HALT"
out=$(cd "$W" && harness/boss.sh status)
check "G a live run shows the live clock, with no note" 'time left: [45] min  done on main' echo "$out"
fi

# ---- B: boss.sh trust confirms that each session started after it answered the prompt
if want B; then
mk_workdir lead h1 h2 h3; setup_wd; : > "$STUB_DIR/session"
PROMPT_NO=$' Do you trust the files in this folder?\n Is this a project you created or one you trust?\n   1. Yes, I trust this folder\n \xe2\x9d\xaf 2. No, exit\n Enter to confirm'
PROMPT_YES=$' Do you trust the files in this folder?\n Is this a project you created or one you trust?\n \xe2\x9d\xaf 1. Yes, I trust this folder\n   2. No, exit\n Enter to confirm'
panes() { local a=$1 i=0; shift; mkdir -p "$STUB_DIR/panes/$a"; for p in "$@"; do i=$((i+1)); printf '%s\n' "$p" > "$STUB_DIR/panes/$a/$i"; done; }
panes lead "$PROMPT_YES" "$PROMPT_YES" ' > _\n team-lead · auto mode'
panes h1 "$PROMPT_NO" ' Claude Code\n team-h1 · auto mode'
panes h2 "$PROMPT_NO" '[claude exited; shell kept open so the window persists]'
panes h3 "$PROMPT_NO" 'loading...'
: > "$STUB_DIR/calls.log"
out=$(cd "$W" && harness/boss.sh trust 2>&1)
check "B a session seen running after the answer is reported started" '^h1: answered yes, started$' echo "$out"
check "B a session that exited is reported as not started" '^h2: answered, but the session did not start.*look at the window' echo "$out"
refute "B and never as answered yes" '^h2: answered yes' echo "$out"
check "B a session never seen running is reported so" '^h3: answered, but the session was not seen running.*look at the window' echo "$out"
check "B with the cursor on Yes, only Enter is sent" '^lead: answered yes, started$' echo "$out"
refute "B and no Down that would move it to No" 'send-keys -t =[^ ]*:lead Down' cat "$STUB_DIR/calls.log"
check "B with the cursor on No, Down is sent first" 'send-keys -t =[^ ]*:h1 Down' cat "$STUB_DIR/calls.log"
rm -rf "$STUB_DIR/panes"; printf ' team-h1 · auto mode\n' > "$STUB_DIR/pane"
check "B the stub's single pane still works: started without a prompt" 'started without a prompt' sh -c "cd '$W' && harness/boss.sh trust"
fi

# ---- L3: boss.sh slash types a slash command, as it is, into an open agent's window
if want L3; then
mk_workdir lead h1 h2 h3; setcfg agent_profiles '{"h1": "research", "h3": "open"}'; setup_wd; : > "$STUB_DIR/session"
: > "$STUB_DIR/calls.log"
check "L3 slash types the line into an open agent's window" 'typed into h3' sh -c "cd '$W' && harness/boss.sh slash h3 '/goal finish statement b, proven by its check'"
check "L3 with no prefix" 'send-keys -t =[^ ]*:h3 -l /goal finish statement b, proven by its check$' cat "$STUB_DIR/calls.log"
check "L3 and then Enter" 'send-keys -t =[^ ]*:h3 Enter' cat "$STUB_DIR/calls.log"
: > "$STUB_DIR/calls.log"
out=$(cd "$W" && harness/boss.sh slash h1 "/goal x" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'research' <<<"$out" && grep -q 'open' <<<"$out" && ok "L3 refused for an agent that is not on open, naming its profile" || no "L3 refused for an agent that is not on open, naming its profile" "$rc $out"
( cd "$W" && harness/boss.sh slash lead "/goal x" ) >/dev/null 2>&1 && no "L3 refused for a sealed agent" || ok "L3 refused for a sealed agent"
( cd "$W" && harness/boss.sh slash h3 "goal x" ) >/dev/null 2>&1 && no "L3 refused for a line that is not a slash command" || ok "L3 refused for a line that is not a slash command"
( cd "$W" && harness/boss.sh slash h3 $'/goal x\n/exit' ) >/dev/null 2>&1 && no "L3 refused for more than one line" || ok "L3 refused for more than one line"
( cd "$W" && harness/boss.sh slash h3 $'/goal \x1b[2K' ) >/dev/null 2>&1 && no "L3 refused for control characters" || ok "L3 refused for control characters"
( cd "$W" && harness/boss.sh slash all "/goal x" ) >/dev/null 2>&1 && no "L3 refused for all" || ok "L3 refused for all"
refute "L3 nothing was typed by a refusal" 'send-keys' cat "$STUB_DIR/calls.log"
( cd "$W" && harness/boss.sh remove h3 ) >/dev/null
( cd "$W" && harness/boss.sh slash h3 "/goal x" ) >/dev/null 2>&1 && no "L3 refused for a removed agent" || ok "L3 refused for a removed agent"
( cd "$W" && harness/boss.sh say h1 "hello" ) >/dev/null
check "L3 say still marks the boss's text" 'send-keys -t =[^ ]*:h1 -l \[boss\] hello' cat "$STUB_DIR/calls.log"
check "L3 SKILL.md documents boss.sh slash" 'boss.sh slash' cat "$REPO/SKILL.md"
check "L3 references/goal.md says how an open agent is put under /goal" 'boss.sh slash' cat "$REPO/references/goal.md"
fi

# ---- L1, L2, L4: what the live profiles run measured, written down
if want L; then
mk_workdir lead h1 h2 h3; setcfg agent_profiles '{"h1": "research", "h2": "allied", "h3": "open"}'; setup_wd
DENY='"permissionDecision": "deny"'
for a in lead h1 h2 h3; do
  check "L4 the monitor refuses EndConversation ($a)" "$DENY" hook $a EndConversation '{}'
  check "L4 the monitor refuses a plugin's tool, mcp__easel__chart ($a)" "$DENY" hook $a mcp__easel__chart '{"spec":"x"}'
done
halted && no "L4 and neither pauses the team" || ok "L4 and neither pauses the team"
check  "L4 claude-code.md says live sessions were offered both" 'EndConversation.*mcp__easel__chart|mcp__easel__chart.*EndConversation' sh -c "tr '\n' ' ' < '$REPO/references/claude-code.md'"
refute "L4 run-agent.sh no longer says only that no profile has MCP servers" 'No profile has MCP servers\.$' cat "$W/harness/run-agent.sh"
refute "L1 SKILL.md no longer says research may lack WebFetch" 'did not report `WebFetch`' cat "$REPO/SKILL.md"
check  "L1 SKILL.md: allied and open fetch through a web-fetch subagent" 'web-fetch' cat "$REPO/SKILL.md"
refute "L1 claude-code.md no longer says only allied and open can fetch pages" 'only `allied` and `open` can fetch pages' sh -c "tr '\n' ' ' < '$REPO/references/claude-code.md' | tr -s ' '"
for f in SKILL.md references/design.md references/goal.md references/claude-code.md; do
  refute "L2 $f no longer calls the hook inside subagents unproven" -i 'inside (a )?subagents? (is|are) unproven|whether (the monitor sees the tool calls|.?PreToolUse.? fires)|^\| Tool calls made inside a subagent[^|]*\| Unproven' sh -c "tr '\n' ' ' < '$REPO/$f' | tr -s ' ' | sed 's/| |/|\n|/g'"
done
check "L2 design.md: shown live, the hook and the sandbox apply inside subagents" 'Tool calls made inside a subagent.*Shown live' cat "$REPO/references/design.md"
fi

# ---- H: the team's decision record matches the run's records
if want H; then
D=$REPO/references/decisions/team-choice.md
refute "H no longer claims the first 45 minutes, before four statements were done" 'In the first 45 minutes' sh -c "tr '\\n' ' ' < '$D'"
check "H marks the correction as made after the run by review" 'Corrected after the run by review' cat "$D"
check "H the run took 33.3 minutes, four statements done at minute 14.7" '33\.3 minutes.*minute 14\.7' sh -c "tr '\n' ' ' < '$D'"
check "H 11 of 27 merge requests were rejected, all for conflicts" '27 merge requests, 16 were accepted and 11 rejected, every one of them for a merge conflict' sh -c "tr '\n' ' ' < '$D' | tr -s ' '"
check "H per agent: w2 3, w1 2, w4 2, w5 2, w3 1, w6 1" 'w2 three times.*w1 twice.*w4 twice.*w5 twice.*w3 once.*w6 once' sh -c "tr '\n' ' ' < '$D'"
check "H the cost was the wait in the merge queue: 714 s" 'cost was waiting.*714 s' sh -c "tr '\n' ' ' < '$D'"
check "H the table lists all 11 rejections" '^11$' sh -c "grep -cE '^\| [0-9]+\.[0-9] \| [0-9]+\.[0-9] \| w[1-6] ' '$D'"
check "H the decision is kept" 'team precheck' cat "$D"
fi

# ---- DONE: once every statement is on main, nothing more lands
if want DONE; then
mk_workdir lead h1 h2; setup_wd
setcfg task.check '"sleep 1; grep -qx ok out/{name}.txt"'
launch >/dev/null 2>&1; start_gateway
land h1 a >/dev/null 2>&1; land h1 b >/dev/null 2>&1
# h2 prepares an extra change; h1 completes the run while h2's request waits for the merge lock
as h2 sh -c 'git fetch -q origin main && git merge -q --no-edit origin/main >/dev/null 2>&1; mkdir -p out; echo ok > out/extra.txt; git add out; git commit -q -m extra'
( land h1 c > "$TOP/c.out" 2>&1 ) & pc=$!
sleep 0.5; as h2 team mr "late extra" > "$TOP/late.out" 2>&1; rc=$?
wait $pc
check "DONE the last statement completes the run" 'RUN COMPLETE' cat "$TOP/c.out"
[ $rc -ne 0 ] && grep -q 'RUN COMPLETE' "$TOP/late.out" && ok "DONE a merge that waited for the lock while the run completed is refused" || no "DONE a merge that waited for the lock while the run completed is refused" "$rc $(cat "$TOP/late.out")"
M=$(git -C "$W/central.git" rev-parse main); n=$(wc -l < "$W/records/merges.jsonl")
out=$(as h2 team mr "later still" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'main is closed' <<<"$out" && ok "DONE team mr after RUN COMPLETE is refused" || no "DONE team mr after RUN COMPLETE is refused" "$rc $out"
check "DONE team precheck after RUN COMPLETE is refused" 'RUN COMPLETE' as h2 team precheck
[ "$(git -C "$W/central.git" rev-parse main)" = "$M" ] && [ "$(wc -l < "$W/records/merges.jsonl")" = "$n" ] && ok "DONE main and the merge records do not move" || no "DONE main and the merge records do not move"
refute "DONE out/extra.txt never reached main" . sh -c "git -C '$W/central.git' show main:out/extra.txt 2>/dev/null"
check "DONE status still answers" 'RUN COMPLETE' as h2 team status
check "DONE the board still answers" '^1$' as h2 team sql "SELECT 1 AS one"
check "DONE design.md says main closes at RUN COMPLETE" 'is closed once the run is complete' cat "$REPO/references/design.md"
fi

# ---- R: the end of a run cannot be filtered away: team status and team wait exit non-zero, and wait returns at once
if want R; then
mk_workdir lead h1 h2; setup_wd; launch >/dev/null 2>&1; start_gateway
rc_of() { "$@" >/dev/null 2>&1; echo $?; }
check "R a running run: team status exits 0" '^0$' rc_of as h1 team status
check "R and team wait 1 exits 0" '^0$' rc_of as h1 team wait 1
echo '{"ts": 0, "agent": "h2", "reason": "test"}' > "$W/state/HALT"
t0=$(date +%s); rc=$(rc_of as h1 team wait 60); dt=$(( $(date +%s) - t0 ))
[ "$rc" = 3 ] && [ $dt -le 5 ] && ok "R paused: team wait returns at once with exit 3 ($dt s)" || no "R paused: team wait returns at once with exit 3" "rc=$rc after ${dt}s"
rm -f "$W/state/HALT"
( as h1 team wait 60 > "$TOP/w.out" 2> "$TOP/w.err"; echo $? > "$TOP/w.rc" ) & pw=$!
sleep 2; t0=$(date +%s)
echo '{"ts": 1, "stall_min": 30, "idle_s": 1800}' > "$W/state/STALLED"
wait $pw; dt=$(( $(date +%s) - t0 ))
[ "$(cat "$TOP/w.rc")" = 4 ] && [ $dt -le 4 ] && ok "R a stall during team wait ends the wait at once with exit 4 ($dt s)" || no "R a stall during team wait ends the wait at once with exit 4" "rc=$(cat "$TOP/w.rc") after ${dt}s"
check "R the reason is on stdout" 'STALLED' cat "$TOP/w.out"
check "R and on stderr" 'STALLED' cat "$TOP/w.err"
t0=$(date +%s); out=$(as h1 sh -c 'team wait 100 | grep -v STALLED' 2>&1); dt=$(( $(date +%s) - t0 ))
[ $dt -le 4 ] && grep -q STALLED <<<"$out" && ok "R team wait 100 | grep -v STALLED: returns at once, and the stall still shows" || no "R team wait 100 | grep -v STALLED: returns at once, and the stall still shows" "${dt}s: $out"
check "R stalled: team status exits 4" '^4$' rc_of as h1 team status
rm -f "$W/state/STALLED"
cp "$W/state/deadline" "$TOP/deadline"; ( cd "$W" && harness/boss.sh end ) >/dev/null
check "R time up: team status exits 4" '^4$' rc_of as h1 team status
check "R time up: team wait exits 4" '^4$' rc_of as h1 team wait 30
cp "$TOP/deadline" "$W/state/deadline"
( cd "$W" && harness/boss.sh remove h2 ) >/dev/null
check "R removed: team status exits 4" '^4$' rc_of as h2 team status
land h1 a >/dev/null 2>&1; land h1 b >/dev/null 2>&1; land h1 c >/dev/null 2>&1
check "R complete: team status exits 4" '^4$' rc_of as h1 team status
check "R complete: and says so on stderr" 'RUN COMPLETE' sh -c "cd '$W/ws/h1' && PATH='$W/bin:$PATH' team status 2>&1 >/dev/null"
for a in lead h1; do
  check "R $a's brief says what a non-zero exit from team wait means" 'non-zero exit from `team wait`' sh -c "cd '$W' && python3 harness/render.py $a"
  check "R $a's rejoining brief says it too" 'non-zero exit from `team wait`' sh -c "cd '$W' && python3 harness/render.py $a --resume"
done
fi

# ---- S: boss.sh status exits 0 whether or not the team is paused
if want S; then
mk_workdir lead h1; setup_wd; launch >/dev/null 2>&1
( cd "$W" && harness/boss.sh status ) >/dev/null 2>&1 && ok "S boss.sh status exits 0 when the team is not paused" || no "S boss.sh status exits 0 when the team is not paused"
echo '{"ts": 0, "agent": "h1", "reason": "test"}' > "$W/state/HALT"
( cd "$W" && harness/boss.sh status ) >/dev/null 2>&1 && ok "S and when it is paused" || no "S and when it is paused"
fi

# ---- Q: the lead's reminders come back after boss.sh unstall
if want Q; then
mk_workdir lead h1; setup_wd; launch >/dev/null 2>&1
echo '{"ts": 1, "stall_min": 30}' > "$W/state/STALLED"; : > "$STUB_DIR/calls.log"
( cd "$W" && TEAM_REMIND_S=1 bash harness/remind.sh ) > "$TOP/remind.out" 2>&1 & pr=$!
sleep 2.5
kill -0 $pr 2>/dev/null && ok "Q the reminder loop keeps running while the run is stalled" || no "Q the reminder loop keeps running while the run is stalled" "$(cat "$TOP/remind.out")"
refute "Q and sends no reminder then" 'send-keys' cat "$STUB_DIR/calls.log"
( cd "$W" && harness/boss.sh unstall ) >/dev/null
wait_for 5 grep -q 'Time left' "$STUB_DIR/calls.log" && ok "Q after boss.sh unstall the reminders come back" || no "Q after boss.sh unstall the reminders come back" "$(cat "$TOP/remind.out")"
date +%s > "$W/state/DONE"
wait_for 5 sh -c "! kill -0 $pr 2>/dev/null" && ok "Q the loop ends when the run is complete" || { no "Q the loop ends when the run is complete"; kill $pr; }
fi

# ---- O: during a pause, the stall clock shows its value at the start of the pause
if want O; then
mk_workdir lead h1; setcfg stall_min 4; setup_wd; launch >/dev/null 2>&1
python3 -c "
import json, time; now = time.time()
open('$W/state/stall_from', 'w').write(str(now - 300))         # 5 min now
json.dump(dict(ts=now - 120, agent='h1', reason='test'), open('$W/state/HALT', 'w'))   # 3 min when the pause began"
out=$(cd "$W" && harness/boss.sh status)
check "O paused: the stall clock shows 3 of 4 min, not 5" 'stall clock: 3 of 4 min' echo "$out"
check "O and says it stopped at the pause" 'stall clock: 3 of 4 min.*stopped at the start of the pause' echo "$out"
fi

# ---- P: a stall reopened with boss.sh unstall stays in the run's story
if want P; then
mk_workdir lead h1; setcfg stall_min 30; setup_wd; launch >/dev/null 2>&1
stall() { python3 -c "
import json, time; now = time.time()
json.dump(dict(ts=now - $1, stall_min=30, idle_s=1800, since=now - $1 - 1800, landed=[]), open('$W/state/STALLED', 'w'))"; }
stall 120; ( cd "$W" && harness/boss.sh unstall ) >/dev/null
rep() { ( cd "$W" && python3 harness/report.py -o "$TOP/p.html" ) >/dev/null 2>&1; cat "$TOP/p.html"; }
p=$(rep)
check "P the report lists a reopened stall" 'STALLED</b> at [0-9:]+ .*reopened at [0-9:]+' echo "$p"
check "P and draws it on the timeline" 'class="rule stall"' echo "$p"
out=$(cd "$W" && python3 harness/offline_monitor.py)
check "P offline_monitor.py lists it, with when it was reopened" 'STALLED at [0-9:]+.*reopened at [0-9:]+' echo "$out"
stall 10
p=$(rep)
check "P a second stall: the report lists both" '^2$' sh -c "grep -o '<b>STALLED</b>' '$TOP/p.html' | wc -l"
out=$(cd "$W" && python3 harness/offline_monitor.py)
check "P offline_monitor.py lists both" '^2$' sh -c "echo \"\$1\" | grep -c 'STALLED at'" sh "$out"
out=$(cd "$W" && ./teardown.sh --archive "$TOP" 2>&1)
mkdir -p "$TOP/u"; tar -xzf "$(echo "$out" | sed -n 's/^archived: //p')" -C "$TOP/u"
check "P the archive's STATUS.txt counts the stalls, reopened ones included" '^stalls: +2 \(1 reopened' cat "$TOP"/u/*/STATUS.txt
fi

# ---- T: a task from a goal contract (no task.attempted_if) passes its own pre-launch test
FIX=$REPO/tests/accept/fixtures/contract.json
if want T; then
# (ii) the merge job's report without attempted_if names what passed and what failed
mk_workdir lead h1 h2; setup_wd
python3 -c "import json; p='$W/config.json'; c=json.load(open(p)); del c['task']['attempted_if']; json.dump(c, open(p,'w'))"
launch >/dev/null 2>&1; start_gateway
out=$(land h1 a)
check "T2 without attempted_if the report names each statement's result" 'checked: a ok; b FAILED; c FAILED' echo "$out"
check "T2 and says a failing statement is not done" 'not done' echo "$out"
out=$(land h2 b "wrong b" no)
check "T2 a wrong answer is merged but named as failing" 'ACCEPTED(.|\n)*b FAILED' sh -c 'echo "$1" | tr "\n" " "' sh "$out"
check "T2 and not counted" 'done on main: a$' echo "$out"
stop_gateway
mk_workdir lead h1 h2; setup_wd; launch >/dev/null 2>&1; start_gateway
check "T2 with attempted_if the report is as before" 'checked: a$' land h1 a
stop_gateway
# (i) test_gateway.sh on a task written by from-goal.py, with a probe for one of its statements
mk_workdir lead h1 h2
( cd "$W" && python3 harness/from-goal.py "$FIX" --apply --allowed 'out/[a-z]+\.txt' ) > "$TOP/fg.out" 2>&1
rm -rf "$W/task/probe"; mkdir -p "$W/task/probe/good/out" "$W/task/probe/bad/out"
echo ok > "$W/task/probe/good/out/alpha.txt"; echo no > "$W/task/probe/bad/out/alpha.txt"
setup_wd; out=$(cd "$W" && harness/test_gateway.sh 2>&1)
refute "T1 test_gateway.sh passes on a from-goal task" '^FAIL' echo "$out"
check "T1 the wrong answer is merged but not counted" "PASS  the task's wrong answer is merged but not counted as done" echo "$out"
check "T1 the right answer is counted" "PASS  the task's right answer is counted as done" echo "$out"
check "T1 test_gateway.sh resets main to the seed" "^$(cat "$W/state/seed_sha")\$" git -C "$W/central.git" rev-parse main
# a probe that answers no statement is caught
mk_workdir lead h1 h2
( cd "$W" && python3 harness/from-goal.py "$FIX" --apply --allowed 'out/[a-z]+\.txt' ) >/dev/null 2>&1
rm -rf "$W/task/probe"; mkdir -p "$W/task/probe/good/out" "$W/task/probe/bad/out"
echo ok > "$W/task/probe/good/out/zzz.txt"; echo no > "$W/task/probe/bad/out/zzz.txt"
setup_wd
check "T1 a probe that answers no statement fails the right-answer check" "FAIL  the task's right answer is counted as done" sh -c "cd '$W' && harness/test_gateway.sh"
# (iii) from-goal.py and the example probe
mk_workdir lead h1 h2; rm -rf "$W/task/probe"; cp -r "$REPO/template/task/probe" "$W/task/probe"   # the example's: kit/roman.py
out=$(cd "$W" && python3 harness/from-goal.py "$FIX" --apply --allowed 'out/[a-z]+\.txt' 2>&1)
refute "T3 a probe whose files the new task freezes is removed" . sh -c "ls -d '$W/task/probe' 2>/dev/null"
check "T3 and the boss is told to write one" -i 'removed task/probe/.*write' sh -c 'echo "$1" | tr "\n" " "' sh "$out"
mk_workdir lead h1 h2; rm -rf "$W/task/probe"; mkdir -p "$W/task/probe/good/kit" "$W/task/probe/bad/kit"
echo x > "$W/task/probe/good/kit/roman.py"; echo y > "$W/task/probe/bad/kit/roman.py"
out=$(cd "$W" && python3 harness/from-goal.py "$FIX" --apply --allowed 'kit/.*' 2>&1)
check "T3 a probe the new task allows is kept, and the boss told to confirm it" 'kept task/probe/' echo "$out"
check "T3 the probe is untouched" '^x$' cat "$W/task/probe/good/kit/roman.py"
mk_workdir lead h1 h2; rm -rf "$W/task/probe"
out=$(cd "$W" && python3 harness/from-goal.py "$FIX" --apply --allowed 'out/[a-z]+\.txt' 2>&1)
check "T3 with no probe the boss is told to write one" 'no task/probe/' echo "$out"
refute "T3 from-goal.py never writes a probe itself" . sh -c "ls -d '$W/task/probe' 2>/dev/null"
check "T references/goal.md says what to put in task/probe" 'merged but not counted' cat "$REPO/references/goal.md"
fi

# ---- U: from-goal.py --apply never drops an existing STATEMENTS.md silently
if want U; then
mk_workdir lead h1 h2
printf '# Statements\n\nThe kit spec: each line is stripped before it is read.\n\n```\n# a shell comment\n```\n' > "$W/task/seed/STATEMENTS.md"
out=$(cd "$W" && python3 harness/from-goal.py "$FIX" --apply --allowed 'out/[a-z]+\.txt' 2>&1)
S=$W/task/seed/STATEMENTS.md
check "U the generated statements come first" 'alpha' head -12 "$S"
check "U the earlier text is kept below them" 'each line is stripped before it is read' cat "$S"
check "U under a heading that says what it is" '^## Earlier text of this file' cat "$S"
check "U its headings are nested under it" '^### Statements' cat "$S"
check "U a comment inside a code block is left alone" '^# a shell comment' cat "$S"
check "U --apply says what it did with the earlier text" 'STATEMENTS.md.*kept' sh -c 'echo "$1" | tr "\n" " "' sh "$out"
( cd "$W" && python3 harness/from-goal.py "$FIX" --apply --allowed 'out/.*' ) >/dev/null 2>&1
check "U a second --apply keeps the earlier text once, not twice" '^1$' sh -c "grep -c 'each line is stripped' '$S'"
check "U and writes the new allowed paths" '`out/\.\*`' cat "$S"
out=$(cd "$W" && python3 harness/from-goal.py "$FIX" --apply --allowed 'out/.*' --replace-statements 2>&1)
refute "U --replace-statements drops the earlier text" 'each line is stripped' cat "$S"
check "U and says so" 'dropped' echo "$out"
( cd "$W" && python3 harness/from-goal.py "$FIX" --replace-statements ) >/dev/null 2>&1 && no "U --replace-statements without --apply is refused" || ok "U --replace-statements without --apply is refused"
fi

# ---- V: references/goal.md says what the live boss-under-/goal run showed
if want V; then
G=$REPO/references/goal.md
refute "V goal.md no longer says no boss has run under /goal" 'no boss has run under `/goal`' cat "$G"
check "V it reports the live run" 'Goal achieved' cat "$G"
check "V it advises an iteration floor of 1 for a boss contract" -i 'floor of (1|one)' cat "$G"
check "V it says the loop can be stopped by a safety classifier, so it is not unattended" -i 'classifier' cat "$G"
refute "V it no longer says the boss uses no subagents" 'the boss uses no subagents' sh -c "tr '\n' ' ' < '$G'"
check "V it tells the boss to pass DIR to teardown.sh --archive" 'teardown\.sh --archive <' cat "$G"
fi

finish
