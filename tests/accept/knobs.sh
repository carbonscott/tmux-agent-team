#!/bin/bash
# Acceptance: composable profile knobs  (see STATEMENTS.md, statement `knobs`)
. "$(dirname "$0")/../lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
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
passes() {   # PASS only if the monitor ran, passed the call and recorded it as passed:  passes <label> <hook args ...>
  local label=$1 out rc; shift; rm -f "$W/records/actions.jsonl"; out=$("$@" 2>&1); rc=$?
  if [ $rc = 0 ] && ! grep -qF "$DENY" <<<"$out" && tail -1 "$W/records/actions.jsonl" 2>/dev/null | grep -qF '"decision": "pass"'; then ok "$label"
  else no "$label" "exit $rc: $out"; fi; }
refused() { local cfgkey=$1 val=$2 label=$3
  mk_workdir lead h1; setcfg "$cfgkey" "$val"
  out=$(cd "$W" && ./setup.sh 2>&1) && no "setup.sh refuses $label" "$out" || ok "setup.sh refuses $label"
  out=$(cd "$W" && python3 harness/profiles.py --check 2>&1) && no "profiles.py --check refuses $label" "$out" || ok "profiles.py --check refuses $label"; }

# 1. The presets behave exactly as before: the earlier acceptance tests still pass unchanged.
for t in profiles remote unwalled; do
  out=$(timeout 100 bash "$HERE/$t.sh" 2>&1) && ok "the $t acceptance test still passes" || no "the $t acceptance test still passes" "$(grep '^FAIL' <<<"$out")"
done

# 2. An inline knob object, on top of a base
mk_workdir lead h1 h2 h3 h4
setcfg agent_profiles '{"h1": {"web": true}, "h2": {"subagents": true}, "h3": {"base": "research", "skills": true}, "h4": {"base": "open", "web": false}}'
setup_wd || no "setup.sh accepts knob objects"
launch >/dev/null 2>&1
check "an empty base is sealed: web alone gives exactly sealed plus the web tools" '^Bash Edit Glob Grep Read WebFetch WebSearch Write \| slash-commands-off$' tools_of h1
check "subagents without web: sealed plus Agent only" '^Agent Bash Edit Glob Grep Read Write \| slash-commands-off$' tools_of h2
check "research plus skills: web and Skill, slash on, no Agent" '^Bash Edit Glob Grep Read Skill WebFetch WebSearch Write \| slash-commands-on$' tools_of h3
check "open minus web: Agent and Skill, no web tools" '^Agent Bash Edit Glob Grep Read Skill Write \| slash-commands-on$' tools_of h4
passes "the monitor passes WebFetch where web is on" hook h1 WebFetch '{"url":"https://example.com/","prompt":"x"}'
check  "the monitor refuses Agent where only web is on" "$DENY" hook h1 Agent '{"prompt":"x","description":"y"}'
passes "the monitor passes Agent for subagents-only" hook h2 Agent '{"prompt":"x","description":"y"}'
check  "the monitor refuses WebFetch for subagents-only" "$DENY" hook h2 WebFetch '{"url":"https://example.com/","prompt":"x"}'
check  "and refuses it from inside a subagent too"     "$DENY" sh -c "echo '{\"tool_name\":\"WebFetch\",\"tool_input\":{\"url\":\"https://example.com/\",\"prompt\":\"x\"},\"agent_id\":\"a1\",\"agent_type\":\"web-fetch\",\"cwd\":\"$W/ws/h2\"}' | python3 '$W/harness/hook.py' h2"
rm -f "$W/state/HALT"
passes "the monitor passes Skill for research+skills" hook h3 Skill '{"skill":"loop"}'
check  "the monitor refuses WebSearch for open minus web" "$DENY" hook h4 WebSearch '{"query":"x"}'
check  "the shell stays offline for every knob object" '^\[\] \[\] \[\] \[\] \[\]$' python3 -c "
import json; print(*[json.load(open('$W/harness/settings/%s.json' % a))['sandbox']['network']['allowedDomains'] for a in ('lead', 'h1', 'h2', 'h3', 'h4')])"
check  "ssh is still a violation without shell_net" "$DENY" bash_ h3 'ssh other-host true'
out=$(cd "$W" && harness/boss.sh status 2>&1)
check "boss.sh status lists an inline object as custom(<knobs on>)" 'h1=custom\(web\)' echo "$out"
check "and lists the knobs in a fixed order" 'h3=custom\(web,skills\)' echo "$out"
check "and an empty object of a preset with a knob off" 'h4=custom\(subagents,skills\)' echo "$out"
check "and a preset by its name" 'lead=sealed' echo "$out"
check "offline_monitor.py lists the same labels" 'h3=custom\(web,skills\)' sh -c "cd '$W' && python3 harness/offline_monitor.py"
check "boss.sh slash is allowed where skills is on" 'typed into h3' sh -c "cd '$W' && harness/boss.sh slash h3 '/loop 5m x'"
check "boss.sh slash is refused where skills is off" 'refused: h2' sh -c "cd '$W' && harness/boss.sh slash h2 '/loop 5m x'"
out=$(cd "$W" && python3 harness/profiles.py h3)
check "profiles.py <agent> keeps its three-field output" '^custom\(web,skills\) Bash,Edit,Read,Write,Glob,Grep,WebSearch,WebFetch,Skill slash-on$' echo "$out"

# 3. Named custom profiles in config.json "profiles"
mk_workdir lead h1 h2
setcfg profiles '{"reader": {"web": true}, "delegator": {"base": "reader", "subagents": true}}'
setcfg profile '"reader"'; setcfg agent_profiles '{"h2": "delegator"}'
setup_wd || no "setup.sh accepts named custom profiles"
launch >/dev/null 2>&1
check "a named custom profile can be the team default" '^Bash Edit Glob Grep Read WebFetch WebSearch Write \| slash-commands-off$' tools_of lead
check "a custom profile can build on another one" '^Agent Bash Edit Glob Grep Read WebFetch WebSearch Write \| slash-commands-off$' tools_of h2
out=$(cd "$W" && harness/boss.sh status 2>&1)
check "boss.sh status lists a named custom profile as <name>(<knobs on>)" 'h1=reader\(web\)' echo "$out"
check "and its descendant" 'h2=delegator\(web,subagents\)' echo "$out"

# 4. shell_net composes only in an unwalled run, and only for the agent that has it
mk_workdir lead h1 h2; setcfg sandbox false; setcfg agent_profiles '{"h1": {"shell_net": true}}'
setup_wd || no "setup.sh accepts shell_net with the sandbox off"
launch >/dev/null 2>&1
check  "shell_net alone adds no tool" '^Bash Edit Glob Grep Read Write \| slash-commands-off$' tools_of h1
passes "the monitor passes ssh for shell_net" bash_ h1 'ssh other-host true'
check  "but not aimed at this machine"       "$DENY" bash_ h1 'ssh localhost tmux ls'
check  "and not for an agent without it"     "$DENY" bash_ h2 'curl https://example.com/'
check  "boss.sh status lists it" 'h1=custom\(shell_net\)' sh -c "cd '$W' && harness/boss.sh status"

# 5. Fail closed: every malformed profile stops setup.sh, with a message naming the problem
refused agent_profiles '{"h1": {"webb": true}}' "an unknown knob"
check "and names the knob" 'webb' echo "$out"
refused agent_profiles '{"h1": {"web": "yes"}}' "a knob that is not true or false"
refused agent_profiles '{"h1": {"web": 1}}' "a knob given as a number"
refused agent_profiles '{"h1": {"base": "nonsense"}}' "an unknown base"
refused agent_profiles '{"h1": {"shell_net": true}}' "shell_net while the sandbox is on"
check "and says why" -i 'sandbox' echo "$out"
refused agent_profiles '{"h1": {"sandbox": false}}' "a sandbox knob inside a profile (the sandbox is team-wide)"
check "and points to the team-wide setting" -i 'team|config' echo "$out"
refused profiles '{"a": {"base": "b"}, "b": {"base": "a"}}' "a cycle of bases"
refused profiles '{"sealed": {"web": true}}' "a custom profile that reuses a preset's name"
refused profiles '{"Bad Name": {"web": true}}' "a profile name that is not lower-case letters, digits, - and _"
refused profile '["web"]' "a profile that is neither a name nor an object"

# 6. The monitor fails closed on its own too: a bad profile grants nothing
mk_workdir lead h1; setup_wd; setcfg agent_profiles '{"h1": {"web": "yes"}}'
check "the monitor refuses even Read for an agent whose profile is malformed" "$DENY" hook h1 Read "{\"file_path\":\"$W/ws/h1/STATEMENTS.md\"}"
finish
