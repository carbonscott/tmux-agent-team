#!/bin/bash
# Team tests for `knobs`: what tests/accept/knobs.sh does not cover. The preset table, every
# knob alone, named profiles in every place a profile is given, the second lock on shell_net,
# the monitor's fail-closed path for each kind of bad value, the brief, the run's page and
# --list, and that no consumer keeps its own copy of the lookup.
. "$(dirname "$0")/../lib.sh"
hook() { rm -f "$W/state/HALT"; echo "{\"tool_name\":\"$2\",\"tool_input\":$3,\"cwd\":\"$W/ws/$1\"}" | python3 "$W/harness/hook.py" "$1"; }
bash_() { hook "$1" Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$2")"; }
DENY='"permissionDecision": "deny"'
prof() { ( cd "$W" && python3 harness/profiles.py "$1" ); }
refused() { ( cd "$W" && python3 harness/profiles.py --check ) >"$TOP/out.log" 2>&1 && no "$1" "$(cat "$TOP/out.log")" || ok "$1"; }

# 1. The presets start exactly the same session as before (label, tools in order, slash)
mk_workdir lead h1 h2 h3 h4; setcfg sandbox false
setcfg agent_profiles '{"lead": "sealed", "h1": "research", "h2": "allied", "h3": "open", "h4": "remote"}'; setup_wd
check "sealed"   '^sealed Bash,Edit,Read,Write,Glob,Grep slash-off$' prof lead
check "research" '^research Bash,Edit,Read,Write,Glob,Grep,WebSearch,WebFetch slash-off$' prof h1
check "allied"   '^allied Bash,Edit,Read,Write,Glob,Grep,WebSearch,WebFetch,Agent slash-off$' prof h2
check "open"     '^open Bash,Edit,Read,Write,Glob,Grep,WebSearch,WebFetch,Agent,Skill slash-on$' prof h3
check "remote"   '^remote Bash,Edit,Read,Write,Glob,Grep,WebSearch,WebFetch,Agent,Skill slash-on$' prof h4
check "--list shows preset names as before" '^lead=sealed h1=research h2=allied h3=open h4=remote$' \
  sh -c "cd '$W' && python3 harness/profiles.py --list"

# 2. Each knob alone, as an object, and an object spelling out a preset gets the custom label
mk_workdir lead h1 h2 h3 h4; setcfg sandbox false
setcfg agent_profiles '{"lead": {}, "h1": {"skills": true}, "h2": {"base": "remote", "shell_net": false}, "h3": {"web": true, "subagents": true}, "h4": {"base": "sealed", "web": false}}'
setup_wd || no "setup.sh accepts these objects"
check "an empty object is custom() with sealed's tools" '^custom\(\) Bash,Edit,Read,Write,Glob,Grep slash-off$' prof lead
check "skills alone: Skill and slash on" '^custom\(skills\) Bash,Edit,Read,Write,Glob,Grep,Skill slash-on$' prof h1
check "remote minus shell_net is open's session, labelled custom" '^custom\(web,subagents,skills\) Bash,Edit,Read,Write,Glob,Grep,WebSearch,WebFetch,Agent,Skill slash-on$' prof h2
check "web+subagents spelled out is allied's tools, labelled custom" '^custom\(web,subagents\) Bash,Edit,Read,Write,Glob,Grep,WebSearch,WebFetch,Agent slash-off$' prof h3
check "a knob set false on a base that has it off is harmless" '^custom\(\) ' prof h4
check "the monitor passes Skill for skills alone" '^$' hook h1 Skill '{"skill":"loop"}'
check "and refuses Agent there" "$DENY" hook h1 Agent '{"prompt":"x","description":"y"}'
check "remote minus shell_net keeps ssh blocked even unwalled" "$DENY" bash_ h2 'ssh other-host true'
rm -f "$W/state/HALT"
check "SubagentHandback passes inside a subagent where subagents is on" '^$' \
  sh -c "echo '{\"tool_name\":\"SubagentHandback\",\"tool_input\":{},\"agent_id\":\"a1\",\"cwd\":\"$W/ws/h3\"}' | python3 '$W/harness/hook.py' h3"
check "but not where subagents is off" "$DENY" \
  sh -c "echo '{\"tool_name\":\"SubagentHandback\",\"tool_input\":{},\"agent_id\":\"a1\",\"cwd\":\"$W/ws/h1\"}' | python3 '$W/harness/hook.py' h1"
rm -f "$W/state/HALT"
check "the refusal names the agent's label" 'custom\(skills\)' hook h1 Agent '{"prompt":"x","description":"y"}'

# 3. Named custom profiles: as the default, per agent, with shell_net, and as a base of an object
mk_workdir lead h1 h2 h3; setcfg sandbox false
setcfg profiles '{"reader": {"web": true}, "netter": {"shell_net": true}, "r2": {"base": "netter", "base2": 1}}'
refused "an unknown key in a named profile is refused"
check "and the message names it" 'base2' cat "$TOP/out.log"
setcfg profiles '{"reader": {"web": true}, "netter": {"base": "reader", "shell_net": true}, "x-1_b": {"base": "open"}}'
setcfg profile '"reader"'; setcfg agent_profiles '{"h1": "netter", "h2": {"base": "reader", "skills": true}, "h3": "x-1_b"}'
setup_wd || no "setup.sh accepts named profiles with -, _ and digits"
check "the default is the named profile" '^reader\(web\) ' prof lead
check "a named profile with shell_net" '^netter\(web,shell_net\) Bash,Edit,Read,Write,Glob,Grep,WebSearch,WebFetch slash-off$' prof h1
check "an object whose base is a custom name is custom" '^custom\(web,skills\) ' prof h2
check "a named alias of a preset shows its own name" '^x-1_b\(web,subagents,skills\) ' prof h3
check "the monitor passes ssh for the named shell_net profile" '^$' bash_ h1 'ssh other-host true'
check "and refuses curl for the others" "$DENY" bash_ h2 'curl https://example.com/'
check "--list" '^lead=reader\(web\) h1=netter\(web,shell_net\) h2=custom\(web,skills\) h3=x-1_b\(web,subagents,skills\)$' \
  sh -c "cd '$W' && python3 harness/profiles.py --list"
check "the shell_net agent's brief has the Remote machines section" '^## Remote machines' sh -c "cd '$W' && python3 harness/render.py h1"
refute "the others' briefs do not" 'Remote machines' sh -c "cd '$W' && python3 harness/render.py h2"
launch >/dev/null 2>&1
check "offline_monitor.py shows the labels" 'h1=netter\(web,shell_net\)' sh -c "cd '$W' && python3 harness/offline_monitor.py"
check "the run's page shows the labels" 'custom\(web,skills\)' sh -c "cd '$W' && python3 harness/report.py -o '$TOP/r.html' >/dev/null && cat '$TOP/r.html'"

# 4. The second lock: shell_net with the sandbox turned back on after setup passes nothing
setcfg sandbox true
check "with the sandbox on again, ssh is a violation even for shell_net" "$DENY" bash_ h1 'ssh other-host true'
rm -f "$W/state/HALT"

# 5. Fail closed in --check, for more shapes than the acceptance test
mk_workdir lead h1
for v in '{"Web": true}' '{"web": null}' '{"web": "false"}' '{"web": 0}' '{"base": {"web": true}}' '{"base": ""}' \
         '""' '7' 'true' '"Sealed"' '{"base": "remote", "shell_net": true}'; do
  setcfg agent_profiles "{\"h1\": $v}"; refused "--check refuses agent h1 given $v"
done
setcfg agent_profiles '{}'
for v in '{"": {"web": true}}' '{"1x": {}}' '{"open": {}}' '{"a": {"base": "a"}}' '{"a": {"sandbox": true}}'; do
  setcfg profiles "$v"; refused "--check refuses profiles $v"
done
setcfg profiles '[]'; refused "--check refuses profiles that is not an object"

# 6. The monitor grants nothing for any value that does not resolve, without a pause
mk_workdir lead h1; setup_wd
for v in '{"web": "yes"}' '"nonsense"' '{"base": "nope"}' '["web"]' '{"sandbox": false}' '{"web": null}'; do
  setcfg agent_profiles "{\"h1\": $v}"
  check "the monitor refuses Read for h1 given $v" "$DENY" hook h1 Read "{\"file_path\":\"$W/ws/h1/STATEMENTS.md\"}"
  [ -e "$W/state/HALT" ] && no "and does not pause the team ($v)" || ok "and does not pause the team ($v)"
  check "and the lead, whose profile resolves, still may Read ($v)" '^$' hook lead Read "{\"file_path\":\"$W/ws/lead/STATEMENTS.md\"}"
done
setcfg agent_profiles '{}'; setcfg profiles '{"a": {"base": "b"}, "b": {"base": "a"}}'; setcfg profile '"a"'
check "a cycle of bases grants nothing either" "$DENY" hook h1 Read "{\"file_path\":\"$W/ws/h1/STATEMENTS.md\"}"

# 7. One resolver: no consumer reads agent_profiles itself
refute "only profiles.py reads agent_profiles" '.' sh -c "cd '$REPO/template/harness' && grep -ln 'agent_profiles\"' *.py *.sh | grep -v '^profiles.py$'"
# 8. The gaps the audit found (knob_audit H7+): a trailing newline in a name, a key given twice,
# a chain of bases too deep for recursion, and the words labels use
mk_workdir lead h1; setup_wd
setcfg profiles '{"reader\n": {"web": true}}'; refused "--check refuses a name with a trailing newline"
setcfg profiles '{"custom": {"web": true}}'; refused "--check refuses a profile named custom"
setcfg profiles '{"invalid": {}}'; refused "--check refuses a profile named invalid"
python3 - "$W/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["profiles"] = {"p%d" % i: {"base": "p%d" % (i + 1)} for i in range(5000)}
c["profiles"]["p5000"] = {"web": True}; c["profile"] = "p0"; json.dump(c, open(sys.argv[1], "w"))
PY
refused "--check refuses a chain of bases too deep to resolve"
refute "without a traceback" 'Traceback' cat "$TOP/out.log"
check "the monitor grants nothing for it" "$DENY" hook h1 Read "{\"file_path\":\"$W/ws/h1/STATEMENTS.md\"}"
python3 - "$W/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c.pop("profiles", None); c.pop("profile", None)
s = json.dumps(c)[:-1] + ', "agent_profiles": {"h1": {"web": false, "web": true}}}'
open(sys.argv[1], "w").write(s)
PY
refused "--check refuses a knob given twice"
check "and names the key" '"web"' cat "$TOP/out.log"
check "the monitor grants nothing while a key is given twice" "$DENY" hook h1 Read "{\"file_path\":\"$W/ws/h1/STATEMENTS.md\"}"
check "profiles.py <agent> refuses it" 'does not resolve' prof h1
for v in '["open"]' '"open"' 'null'; do
  setcfg agent_profiles "$v"
  check "the monitor grants nothing when agent_profiles is $v" "$DENY" hook h1 Read "{\"file_path\":\"$W/ws/h1/STATEMENTS.md\"}"
done
setcfg agent_profiles '{}'; setcfg profiles '["x"]'
check "nor when profiles is not an object" "$DENY" hook h1 Read "{\"file_path\":\"$W/ws/h1/STATEMENTS.md\"}"
finish
