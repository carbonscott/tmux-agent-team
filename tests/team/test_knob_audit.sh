#!/bin/bash
# Team tests for `knob_audit`: the experiments of references/decisions/knobs.md, made repeatable.
# Each PASS label starts with the hypothesis (H<n>:) and asserts the verdict the record states.
# Nothing here starts a session: the monitor (hook.py) is fed the hook input Claude Code sends,
# and run-agent.sh starts the stub claude, whose argv shows the --tools a session gets.
. "$(dirname "$0")/../lib.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
DENY='"permissionDecision": "deny"'

argv_tools() {   # the tools and slash setting an agent's session is started with: "A,B,C slash-on|slash-off"
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
        if a.startswith("--") or a == "--":
            break
        out += [t for t in re.split(r"[,\s]+", a) if t]
print(",".join(sorted(out)), "slash-off" if "--disable-slash-commands" in argv else "slash-on")
PY
}
# decide <agent> <tool> <tool_input json> [extra top-level json fields, e.g. ,"agent_id":"a1"]
# prints pass, refuse (deny, no pause) or block (deny and pause), as the monitor recorded it
decide() {
  rm -f "$W/state/HALT" "$W/records/actions.jsonl"
  local out; out=$(echo "{\"tool_name\":\"$2\",\"tool_input\":$3,\"cwd\":\"$W/ws/$1\"${4:-}}" | python3 "$W/harness/hook.py" "$1" 2>&1)
  if [ -s "$W/records/actions.jsonl" ]; then
    python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["decision"])' "$W/records/actions.jsonl"
  else echo "error: $out"; fi
  rm -f "$W/state/HALT"
}
cmd() { python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1"; }
input_of() {   # a harmless input for each tool, so that only the tool rule can refuse it
  case $2 in
    Bash) echo '{"command":"true"}';;
    Edit) echo "{\"file_path\":\"$W/ws/$1/a.txt\",\"old_string\":\"a\",\"new_string\":\"b\"}";;
    Write) echo "{\"file_path\":\"$W/ws/$1/a.txt\",\"content\":\"x\"}";;
    Read) echo "{\"file_path\":\"$W/ws/$1/STATEMENTS.md\"}";;
    Glob|Grep) echo '{"pattern":"x"}';;
    WebSearch) echo '{"query":"x"}';;
    WebFetch) echo '{"url":"https://example.com/","prompt":"x"}';;
    Agent) echo '{"prompt":"x","description":"y"}';;
    Skill) echo '{"skill":"loop"}';;
    NotebookEdit) echo "{\"notebook_path\":\"$W/ws/$1/a.ipynb\",\"new_source\":\"x\"}";;
    SendMessage) echo '{"to":"h2","message":"x"}';;
    SubagentHandback) echo '{"message":"x"}';;
    *) echo '{}';;
  esac
}
ALL_TOOLS="Bash Edit Read Write Glob Grep WebSearch WebFetch Agent Skill NotebookEdit SendMessage SubagentHandback EndConversation mcp__easel__chart mcp__srv__run TodoWrite"
KNOBS=(web subagents skills shell_net)
obj() {   # the knob object for combination number n (bit i = KNOBS[i])
  local n=$1 i s=""; for i in 0 1 2 3; do s+="\"${KNOBS[$i]}\": $( (( n >> i & 1 )) && echo true || echo false),"; done; echo "{${s%,}}"; }
on_of() { local n=$1 i s=""; for i in 0 1 2 3; do (( n >> i & 1 )) && s+="${KNOBS[$i]},"; done; echo "${s%,}"; }

# ---------------------------------------------------------------------------------------------
# H1, union: for all 16 combinations, the session's tools are exactly the tools the monitor passes
for walled in yes no; do
  mk_workdir lead h0 h1 h2 h3 h4 h5 h6 h7
  [ $walled = no ] && setcfg sandbox false
  ap="{"; for j in 0 1 2 3 4 5 6 7; do n=$j; [ $walled = no ] && n=$((j + 8)); ap+="\"h$j\": $(obj $n),"; done
  setcfg agent_profiles "${ap%,}}"
  setup_wd || { no "H1: setup.sh accepts every combination (sandbox $walled)"; continue; }
  launch >/dev/null 2>&1
  for j in 0 1 2 3 4 5 6 7; do
    n=$j; [ $walled = no ] && n=$((j + 8)); on=$(on_of $n)
    read -r started slash <<<"$(argv_tools h$j)"
    passed=""; for t in $ALL_TOOLS; do [ "$(decide h$j $t "$(input_of h$j $t)")" = pass ] && passed+="$t,"; done
    passed=$(tr ',' '\n' <<<"${passed%,}" | sort | paste -sd, -)
    [ -n "$started" ] && [ "$started" = "$passed" ] && ok "H1: {$on}: the session's tools are exactly what the monitor passes ($started)" \
      || no "H1: {$on}: the session's tools are exactly what the monitor passes" "started: $started / passed: $passed"
    want_slash=slash-off; [[ ",$on," == *,skills,* ]] && want_slash=slash-on
    [ "$slash" = "$want_slash" ] && ok "H1: {$on}: slash commands follow skills ($slash)" || no "H1: {$on}: slash commands follow skills" "$slash"
    wrong=""; for t in SendMessage NotebookEdit mcp__easel__chart mcp__srv__run EndConversation TodoWrite SubagentHandback; do
      [ "$(decide h$j $t "$(input_of h$j $t)")" = refuse ] || wrong+="$t "; done
    [ -z "$wrong" ] && ok "H1: {$on}: tools no profile grants are refused (SendMessage, NotebookEdit, MCP, EndConversation, TodoWrite, SubagentHandback outside a subagent)" \
      || no "H1: {$on}: tools no profile grants are refused" "not refused: $wrong"
    net=$(decide h$j Bash "$(cmd 'ssh other-host true')")
    if [[ ",$on," == *,shell_net,* ]]; then [ "$net" = pass ] && ok "H1: {$on}: the monitor passes ssh" || no "H1: {$on}: the monitor passes ssh" "$net"
    else [ "$net" = block ] && ok "H1: {$on}: ssh pauses the team" || no "H1: {$on}: ssh pauses the team" "$net"; fi
  done
done

# ---------------------------------------------------------------------------------------------
# H2, presets unchanged: each preset gives the tools and slash setting of the code before knobs
for p in sealed research allied open remote; do
  out=$(cd "$REPO/template/harness" && python3 - "$p" "$HERE/knob_audit/profiles_before.py" <<'PY'
import importlib.util, sys
import profiles
spec = importlib.util.spec_from_file_location("before", sys.argv[2]); before = importlib.util.module_from_spec(spec)
spec.loader.exec_module(before)
p = sys.argv[1]
cfg = {"agents": ["lead"], "profile": p, "sandbox": p != "remote"}
r = profiles.resolve(cfg, "lead")
old_tools, old_slash = before.PROFILES[p]
print("same" if (r["tools"], r["slash"]) == (old_tools, old_slash) else "differs: %r %r / before %r %r" % (r["tools"], r["slash"], old_tools, old_slash))
print("net-same" if before.NET_CMDS == profiles.NET_CMDS else "net-differs")
PY
)
  check "H2: preset $p resolves to exactly the tools and slash setting of before" '^same$' echo "$out"
done
check "H2: NET_CMDS is unchanged" '^net-same$' echo "$out"
mk_workdir lead h1 h2 h3; setcfg agent_profiles '{"h1": "research", "h2": "allied", "h3": "open"}'; setup_wd; launch >/dev/null 2>&1
check "H2: the sealed session's argv is unchanged" '^Bash,Edit,Glob,Grep,Read,Write slash-off$' argv_tools lead
check "H2: the research session's argv is unchanged" '^Bash,Edit,Glob,Grep,Read,WebFetch,WebSearch,Write slash-off$' argv_tools h1
check "H2: the allied session's argv is unchanged" '^Agent,Bash,Edit,Glob,Grep,Read,WebFetch,WebSearch,Write slash-off$' argv_tools h2
check "H2: the open session's argv is unchanged" '^Agent,Bash,Edit,Glob,Grep,Read,Skill,WebFetch,WebSearch,Write slash-on$' argv_tools h3
check "H2: presets keep their plain labels" '^lead=sealed h1=research h2=allied h3=open$' sh -c "cd '$W' && python3 harness/profiles.py --list"

# ---------------------------------------------------------------------------------------------
# H3, subagents do not bring the web: subagents on, web off
mk_workdir lead h1; setcfg agent_profiles '{"h1": {"subagents": true}}'; setup_wd
SUB=',"agent_id":"a1b2","agent_type":"web-fetch"'
check "H3: the Agent call that starts a web-fetch subagent passes (the subagent itself is not the web)" '^pass$' \
  decide h1 Agent '{"prompt":"fetch https://example.com/","description":"fetch","subagent_type":"web-fetch"}'
check "H3: WebFetch from inside the web-fetch subagent is refused" '^refuse$' decide h1 WebFetch '{"url":"https://example.com/","prompt":"x"}' "$SUB"
check "H3: WebSearch from inside a subagent is refused" '^refuse$' decide h1 WebSearch '{"query":"x"}' ',"agent_id":"a1","agent_type":"general-purpose"'
check "H3: curl from inside a subagent pauses the team" '^block$' decide h1 Bash "$(cmd 'curl -s https://example.com/')" "$SUB"
check "H3: allowed_domains from inside a subagent pauses the team" '^block$' decide h1 Bash '{"command":"true","allowed_domains":["example.com"]}' "$SUB"
check "H3: an MCP fetch tool from inside a subagent is refused" '^refuse$' decide h1 mcp__fetch__fetch '{"url":"https://example.com/"}' "$SUB"
check "H3: a nested Agent from inside a subagent passes, and its calls meet the same monitor" '^pass$' decide h1 Agent '{"prompt":"x","description":"y"}' "$SUB"
check "H3: the subagent's report (SubagentHandback) passes" '^pass$' decide h1 SubagentHandback '{"message":"x"}' "$SUB"
check "H3: the shell's sandbox allows no domain for that agent" '^\[\]$' python3 -c "import json; print(json.load(open('$W/harness/settings/h1.json'))['sandbox']['network']['allowedDomains'])"
launch >/dev/null 2>&1
check "H3: the session gets no web tool to hand down" '^Agent,Bash,Edit,Glob,Grep,Read,Write slash-off$' argv_tools h1

# ---------------------------------------------------------------------------------------------
# H4, skills do not widen the tools: skills on, the others off
mk_workdir lead h1; setcfg agent_profiles '{"h1": {"skills": true}}'; setup_wd
check "H4: the Skill call passes" '^pass$' decide h1 Skill '{"skill":"some-skill","args":"x"}'
check "H4: the team skill itself is refused" '^refuse$' decide h1 Skill '{"skill":"tmux-agent-team"}'
# A skill runs in the session's own turn: its tool calls carry the plain hook input. A skill with
# "context: fork" runs as a subagent, so its calls carry agent_id/agent_type. Fields a skill might
# add (none is documented) change nothing: the monitor reads only tool_name for this rule.
for extra in '' ',"agent_id":"s1","agent_type":"some-skill"' ',"skill":"some-skill","allowed_tools":["WebFetch","Agent"]' ',"permission_mode":"bypassPermissions"'; do
  lbl=${extra:-, plain input}
  for t in WebFetch WebSearch Agent NotebookEdit mcp__srv__run; do
    check "H4: a $t call while a skill runs is refused ($lbl)" '^refuse$' decide h1 $t "$(input_of h1 $t)" "$extra"
  done
  check "H4: a network command while a skill runs pauses the team ($lbl)" '^block$' decide h1 Bash "$(cmd 'wget -q https://example.com')" "$extra"
done
check "H4: an Edit outside the workspace while a skill runs is still refused" '^(refuse|block)$' decide h1 Edit "{\"file_path\":\"$TOP/elsewhere.txt\",\"old_string\":\"a\",\"new_string\":\"b\"}" ',"skill":"some-skill"'

# ---------------------------------------------------------------------------------------------
# H5, the sandbox cannot safely be a per-agent knob. Commands the monitor passes (its rules read
# text) that reach what the walls protect; nothing here runs them: the decision is the experiment.
mk_workdir lead h1 h2; setcfg sandbox false; setup_wd
for c in 'ls ../../st*' 'cat ../../ws/h2/STATEMENTS.md' 'rm -f ../../stat?/HALT' 'sed -n 1p ../../harnes?/hook.py' \
         'python3 -c "import sqlite3; sqlite3.connect(\"../../st\"+\"ate/bo\"+\"ard.db\")"' \
         'git --git-dir=../../central.git update-ref refs/heads/main HEAD' 'cp evil.py ../../harnes?/hook.py'; do
  check "H5: the monitor passes, in an unwalled run: $c" '^pass$' decide h1 Bash "$(cmd "$c")"
done
# ... and in a walled run the same agent's sandbox is what stops them
mk_workdir lead h1 h2; setup_wd
out=$(python3 - "$W" <<'PY'
import json, os, sys
W = os.path.realpath(sys.argv[1]); s = json.load(open(W + "/harness/settings/h1.json"))["sandbox"]
deny = [os.path.realpath(p) for p in s["filesystem"]["denyRead"]]
ws = W + "/ws/h1"
for target in ("state", "ws/h2", "harness", "records"):
    p = os.path.realpath(os.path.join(ws, "../..", target))
    print(target, "hidden" if any(p == d or p.startswith(d + "/") for d in deny) else "VISIBLE")
print("enabled", s["enabled"], "allowWrite", s["filesystem"].get("allowWrite", "absent: writes only in the workspace"))
PY
)
for t in state ws/h2 harness records; do check "H5: a walled h1 cannot read ../../$t (denyRead)" "^$t hidden$" echo "$out"; done
check "H5: a walled shell writes only in its workspace, so not central.git" '^enabled True allowWrite absent' echo "$out"
check "H5: the sandbox flag is one value for every agent (mk_settings.py)" 'enabled": WALLED' cat "$W/harness/mk_settings.py"
mk_workdir lead h1; setcfg agent_profiles '{"h1": {"base": "open", "sandbox": false}}'
check "H5: a profile cannot carry its own sandbox setting" -i 'team-wide' sh -c "cd '$W' && python3 harness/profiles.py --check"

# ---------------------------------------------------------------------------------------------
# H6, fail closed: malformed profiles are refused by setup.sh, and the monitor grants nothing
h6() {   # h6 <label> <config key> <json> [sealed]: setup.sh refuses it; the monitor grants h1 nothing,
         # or (sealed: the value is not h1's own, so h1 keeps the default) nothing beyond sealed
  mk_workdir lead h1; setcfg "$2" "$3"
  if ( cd "$W" && ./setup.sh ) >"$TOP/h6.log" 2>&1; then no "H6: setup.sh refuses $1" "$(cat "$TOP/h6.log")"
  else ok "H6: setup.sh refuses $1"; fi
  mkdir -p "$W/records" "$W/state" "$W/ws/h1"
  local got="" t; for t in Read WebSearch WebFetch Agent Skill; do [ "$(decide h1 $t "$(input_of h1 $t)")" = pass ] && got+="$t "; done
  [ "$(decide h1 Bash "$(cmd 'ssh other-host true')")" = pass ] && got+="ssh "
  if [ "${4:-}" = sealed ]; then [ "$got" = "Read " ] && ok "H6: and the monitor grants nothing beyond sealed for $1" \
      || no "H6: and the monitor grants nothing beyond sealed for $1" "passed: $got"
  else [ -z "$got" ] && ok "H6: and the monitor grants nothing, not even Read, for $1" \
      || no "H6: and the monitor grants nothing, not even Read, for $1" "passed: $got"; fi
}
h6 'a knob in the wrong case ("Web")' agent_profiles '{"h1": {"Web": true}}'
h6 'a null profile' agent_profiles '{"h1": null}'
h6 'a null team default' profile 'null'
h6 'the string "false" as a profile' agent_profiles '{"h1": "false"}'
h6 'the string "true" as a knob' agent_profiles '{"h1": {"web": "true"}}'
h6 'a null knob' agent_profiles '{"h1": {"web": null}}'
h6 'an empty name' agent_profiles '{"h1": ""}'
h6 'a preset name in upper case' agent_profiles '{"h1": "OPEN"}'
h6 'a preset name with a space' agent_profiles '{"h1": " open"}'
h6 'a base that is an object' agent_profiles '{"h1": {"base": {"web": true}}}'
h6 'a null base' agent_profiles '{"h1": {"base": null}}'
h6 'a list of knobs' agent_profiles '{"h1": ["web"]}'
h6 'true as a profile' agent_profiles '{"h1": true}'
h6 'a number as a profile' agent_profiles '{"h1": 0}'
h6 'a "tools" key that names a tool' agent_profiles '{"h1": {"web": true, "tools": ["NotebookEdit"]}}'
h6 'a self-referencing base' profiles '{"r": {"base": "r"}}' sealed
h6 'a name with a non-ASCII letter' profiles '{"ré": {"web": true}}' sealed
h6 '"profiles" that is a list' profiles '["reader"]'
h6 'agent_profiles that is a string' agent_profiles '"open"'
h6 'shell_net through a base while the sandbox is on' profiles '{"net": {"shell_net": true}, "x": {"base": "net", "shell_net": false}, "y": {"base": "net"}}' sealed
# H11: a map that is not an object (agent_profiles, profiles) used to fall back to the team default
h11() { mk_workdir lead h1; setcfg profile '"open"'; setcfg "$2" "$3"
  if ( cd "$W" && ./setup.sh ) >"$TOP/h11.log" 2>&1; then no "H11: setup.sh refuses $1"; else ok "H11: setup.sh refuses $1"; fi
  mkdir -p "$W/records" "$W/state" "$W/ws/h1"
  local got="" t; for t in Read WebSearch Agent Skill; do [ "$(decide h1 $t "$(input_of h1 $t)")" = pass ] && got+="$t "; done
  [ -z "$got" ] && ok "H11: the monitor grants nothing, not the team default (open), for $1" \
    || no "H11: the monitor grants nothing, not the team default (open), for $1" "passed: $got"; }
h11 'agent_profiles given as a list' agent_profiles '["h1"]'
h11 'agent_profiles given as a string' agent_profiles '"sealed"'
h11 'agent_profiles given as null' agent_profiles 'null'
h11 'profiles given as a list' profiles '["reader"]'

# H7 and on: the fail-closed gaps the audit found, asserted as fixed (tests/team/knob_audit/h7.sh)
[ -f "$HERE/knob_audit/h7.sh" ] && . "$HERE/knob_audit/h7.sh"
finish
