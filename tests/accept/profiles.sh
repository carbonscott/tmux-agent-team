#!/bin/bash
# Acceptance: capability profiles  (see STATEMENTS.md, statement `profiles`)
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
DENY='"permissionDecision": "deny"'

mk_workdir lead h1 h2 h3; setcfg agent_profiles '{"h1": "research", "h2": "allied", "h3": "open"}'; setup_wd; launch >/dev/null 2>&1
check "sealed is the default: exactly the six tools, slash commands off" '^Bash Edit Glob Grep Read Write \| slash-commands-off$' tools_of lead
t=$(tools_of h1)
check "research adds the web tools" 'WebFetch.*WebSearch' echo "$t"
check "research keeps the six" 'Bash Edit Glob Grep Read' echo "$t"
refute "research does not add subagents" 'Agent' echo "$t"
t=$(tools_of h2)
check "allied adds subagents" 'Agent' echo "$t"
check "allied includes the web tools" 'WebFetch.*WebSearch' echo "$t"
check "allied keeps slash commands off" 'slash-commands-off' echo "$t"
t=$(tools_of h3)
check "open switches slash commands and skills on" 'slash-commands-on' echo "$t"
check "open includes everything allied has" 'Agent.*Bash.*WebFetch.*WebSearch' echo "$t"

check  "the monitor refuses a web tool to a sealed agent"   "$DENY" hook lead WebFetch '{"url":"https://example.com/","prompt":"x"}'
refute "the monitor passes WebFetch for research"            "$DENY" hook h1 WebFetch '{"url":"https://example.com/","prompt":"x"}'
check  "and records it as passed" '"tool": "WebFetch".*"decision": "pass"' tail -1 "$W/records/actions.jsonl"
refute "the monitor passes WebSearch for research"           "$DENY" hook h1 WebSearch '{"query":"x"}'
check  "the monitor refuses subagents to research"           "$DENY" hook h1 Agent '{"prompt":"x","description":"y"}'
refute "the monitor passes subagents for allied"             "$DENY" hook h2 Agent '{"prompt":"x","description":"y"}'
check  "the monitor refuses skills to allied"                "$DENY" hook h2 Skill '{"skill":"loop"}'
refute "the monitor passes skills for open"                  "$DENY" hook h3 Skill '{"skill":"loop"}'
check  "WebFetch may not reach this machine (localhost)"     "$DENY" hook h1 WebFetch '{"url":"http://localhost:8000/x","prompt":"x"}'
check  "WebFetch may not reach this machine (127.0.0.1)"     "$DENY" hook h1 WebFetch '{"url":"http://127.0.0.1/","prompt":"x"}'
check  "WebFetch may not reach the metadata address"         "$DENY" hook h1 WebFetch '{"url":"http://169.254.169.254/latest/","prompt":"x"}'
check  "WebFetch may not read files"                         "$DENY" hook h1 WebFetch '{"url":"file:///etc/passwd","prompt":"x"}'
check  "a tool no profile grants is still refused"           "$DENY" hook h2 SendMessage '{"to":"x","message":"y"}'
echo '{"ts": 0, "agent": "h1", "reason": "test"}' > "$W/state/HALT"
for a in h1 h2 h3; do
  check "a pause refuses every tool, whatever the profile ($a)" "$DENY" sh -c "echo '{\"tool_name\":\"WebSearch\",\"tool_input\":{\"query\":\"x\"},\"cwd\":\"$W/ws/$a\"}' | python3 '$W/harness/hook.py' $a"
done
check "and a skill too" "$DENY" sh -c "echo '{\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"loop\"},\"cwd\":\"$W/ws/h3\"}' | python3 '$W/harness/hook.py' h3"
rm -f "$W/state/HALT"
check "the shell stays offline in every profile" '^\[\] \[\] \[\] \[\]$' python3 -c "
import json; print(*[json.load(open('$W/harness/settings/%s.json' % a))['sandbox']['network']['allowedDomains'] for a in ('lead', 'h1', 'h2', 'h3')])"
out=$(cd "$W" && harness/boss.sh status 2>&1)
for p in lead=sealed h1=research h2=allied h3=open; do check "boss.sh status states $p" "$p" echo "$out"; done
check "offline_monitor.py states the profiles" 'h1=research' sh -c "cd '$W' && python3 harness/offline_monitor.py"

mk_workdir lead h1; setcfg profile '"research"'; setup_wd
check "profile sets the default for the whole team" 'WebFetch.*WebSearch' tools_of lead
mk_workdir lead h1; setcfg agent_profiles '{"h1": "nonsense"}'
( cd "$W" && ./setup.sh ) >/dev/null 2>&1 && no "setup.sh refuses an unknown profile" || ok "setup.sh refuses an unknown profile"

check "SKILL.md documents the profiles" 'research' cat "$REPO/SKILL.md"
check "SKILL.md documents the profiles (allied)" 'allied' cat "$REPO/SKILL.md"
check "SKILL.md documents the profiles (open)" '`open`' cat "$REPO/SKILL.md"
finish
