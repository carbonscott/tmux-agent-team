#!/bin/bash
# Acceptance: the `remote` profile, network from the shell in an unwalled run  (see STATEMENTS.md, statement `remote`)
. "$(dirname "$0")/../lib.sh"
tools_of() {   # the tool names an agent's session is started with, sorted, on one line
  rm -f "$STUB_DIR/claude.argv.json"
  ( cd "$W" && timeout 30 bash harness/run-agent.sh "$1" </dev/null >/dev/null 2>&1 )
  python3 - "$STUB_DIR/claude.argv.json" <<'PY'
import json, re, sys
try:
    argv = json.load(open(sys.argv[1]))
except OSError:
    sys.exit("claude was not started")
out = []
if "--tools" in argv:
    for a in argv[argv.index("--tools") + 1:]:
        if a.startswith("--"):
            break
        out += [t for t in re.split(r"[,\s]+", a) if t]
print(" ".join(sorted(out)), "| slash-commands-off" if "--disable-slash-commands" in argv else "| slash-commands-on")
PY
}
hook() { rm -f "$W/state/HALT"; echo "{\"tool_name\":\"$2\",\"tool_input\":$3,\"cwd\":\"$W/ws/$1\"}" | python3 "$W/harness/hook.py" "$1"; }
bash_() { hook "$1" Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$2")"; }
DENY='"permissionDecision": "deny"'
may() {   # PASS only if the monitor ran, passed the command and recorded it as passed
  local label=$1 out rc; out=$(bash_ "$2" "$3" 2>&1); rc=$?
  if [ $rc = 0 ] && ! grep -qF "$DENY" <<<"$out" && tail -1 "$W/records/actions.jsonl" 2>/dev/null | grep -qF '"decision": "pass"'; then ok "$label"
  else no "$label" "exit $rc: $out"; fi; }

# remote needs the sandbox off
mk_workdir lead h1; setcfg agent_profiles '{"h1": "remote"}'
out=$(cd "$W" && ./setup.sh 2>&1) && no "setup.sh refuses the remote profile while the sandbox is on" "$out" \
  || ok "setup.sh refuses the remote profile while the sandbox is on"
check "and says why" -i 'sandbox' echo "$out"

mk_workdir lead h1 h2; setcfg sandbox false; setcfg agent_profiles '{"h1": "remote", "h2": "open"}'; setup_wd; launch >/dev/null 2>&1
t=$(tools_of h1)
check "remote has everything open has" 'Agent.*Bash.*Skill.*WebFetch.*WebSearch' echo "$t"
check "remote has slash commands on" 'slash-commands-on' echo "$t"
check "boss.sh status states h1=remote" 'h1=remote' sh -c "cd '$W' && harness/boss.sh status"

may "remote may ssh" h1 'ssh sdfiana025 hostname'
may "remote may scp" h1 'scp out/a.txt sdfiana025:/tmp/a.txt'
may "remote may rsync" h1 'rsync -a out/ sdfiana025:/tmp/out/'
may "remote may curl" h1 'curl -sS https://example.com'
may "remote may wget" h1 'wget -q -O- https://example.com'

check  "open still may not ssh"            "$DENY" bash_ h2 'ssh sdfiana025 hostname'
check  "open still may not curl"           "$DENY" bash_ h2 'curl -sS https://example.com'

check  "remote still may not start tmux"   "$DENY" bash_ h1 'tmux ls'
check  "remote still may not start claude" "$DENY" bash_ h1 'claude -p hi'
check  "remote still may not sudo"         "$DENY" bash_ h1 'sudo true'
check  "remote still may not push directly" "$DENY" bash_ h1 'git push origin HEAD:main'
check  "remote still may not touch the board file" "$DENY" bash_ h1 'sqlite3 ../../state/board.db .tables'
check  "remote still may not touch .ssh"   "$DENY" bash_ h1 'cat ~/.ssh/id_rsa'
check  "remote still may not reach another workspace" "$DENY" bash_ h1 'ls ../h2'
echo '{"ts": 0, "agent": "h2", "reason": "test"}' > "$W/state/HALT"
check  "a pause refuses remote's ssh too" "$DENY" sh -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ssh x true\"},\"cwd\":\"$W/ws/h1\"}' | python3 '$W/harness/hook.py' h1"
rm -f "$W/state/HALT"

check "SKILL.md documents the remote profile" '`remote`' cat "$REPO/SKILL.md"
finish
