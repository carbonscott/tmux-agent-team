#!/bin/bash
# Team tests for `profiles`: what tests/accept/profiles.sh does not cover. Tricky URLs for
# WebFetch, which refusals pause the team, connectors off in every profile, precedence of the
# settings, bad settings, removal, subagent records, and the shell rules in the widest profile.
. "$(dirname "$0")/../lib.sh"
hook() { rm -f "$W/state/HALT"; echo "{\"tool_name\":\"$2\",\"tool_input\":$3,\"cwd\":\"$W/ws/$1\"}" | python3 "$W/harness/hook.py" "$1"; }
argv_of() { rm -f "$STUB_DIR/claude.argv.json"; ( cd "$W" && timeout 30 bash harness/run-agent.sh "$1" </dev/null >/dev/null 2>&1 )
  cat "$STUB_DIR/claude.argv.json" 2>/dev/null; }
DENY='"permissionDecision": "deny"'
fetch() { hook h1 WebFetch "{\"url\":\"$1\",\"prompt\":\"x\"}"; }
halted() { [ -e "$W/state/HALT" ]; }

mk_workdir lead h1 h2 h3; setcfg agent_profiles '{"h1": "research", "h2": "allied", "h3": "open"}'; setup_wd

# WebFetch: every way of writing "this machine" or "the private network" is refused
for u in "http://2130706433/" "http://127.1/" "http://0x7f.0.0.1/" "http://[::1]/" "http://0.0.0.0:8000/" \
         "http://10.1.2.3/" "http://192.168.1.1/" "http://172.16.0.9/" "http://100.100.100.100/" \
         "http://[::ffff:127.0.0.1]/" "http://[fe80::1]/" "http://foo.localhost/" "http://printer.local/" \
         "http://metadata.google.internal/" "http://$(hostname)/" "http://LOCALHOST./" \
         "http://example.com@127.0.0.1/" "ftp://example.com/" "data:text/html,hi" "gopher://example.com/" \
         "/etc/passwd" "https://example.com\\\\@127.0.0.1/"; do
  check "WebFetch refuses $u" "$DENY" fetch "$u"
done
check "WebFetch passes a plain https URL"    '^$' fetch "https://docs.python.org/3/library/ipaddress.html"
check "WebFetch passes an upper-case scheme" '^$' fetch "HTTPS://example.com/"
check "WebFetch passes a public address"     '^$' fetch "http://93.184.215.14/"

# which refusals pause the team: reaching this machine does; a tool missing from the profile does not
fetch "http://169.254.169.254/latest/" >/dev/null; halted && ok "a WebFetch of the metadata address pauses the team" || no "a WebFetch of the metadata address pauses the team"
fetch "file:///etc/passwd" >/dev/null; halted && ok "a WebFetch of a file pauses the team" || no "a WebFetch of a file pauses the team"
hook lead WebFetch '{"url":"https://example.com/","prompt":"x"}' >/dev/null
halted && no "a web tool outside the profile is refused without a pause" || ok "a web tool outside the profile is refused without a pause"
check "the refusal names the profile" 'sealed profile' hook lead WebSearch '{"query":"x"}'
check "the refusal is recorded" '"tool": "WebSearch".*"decision": "refuse"' tail -1 "$W/records/actions.jsonl"
hook h1 Agent '{"prompt":"x","description":"y"}' >/dev/null; halted && no "a subagent outside the profile does not pause" || ok "a subagent outside the profile does not pause"

# the widest profile keeps every shell and file rule
check "open: tmux is still blocked"              'BLOCKED by the action monitor' hook h3 Bash '{"command":"tmux ls"}'
check "open: starting claude is still blocked"   'BLOCKED by the action monitor' hook h3 Bash '{"command":"claude -p hi"}'
check "open: reading the harness is still blocked" 'BLOCKED by the action monitor' hook h3 Read "{\"file_path\":\"$W/harness/hook.py\"}"
check "open: the team skill is refused"          "$DENY" hook h3 Skill '{"skill":"tmux-agent-team"}'
check "open: other skills pass"                  '^$'    hook h3 Skill '{"skill":"loop","args":"5m team status"}'
check "open: NotebookEdit is in no profile"      "$DENY" hook h3 NotebookEdit "{\"notebook_path\":\"$W/ws/h3/x.ipynb\",\"new_source\":\"x\"}"
check "allied: file tools still work in the workspace" '^$' hook h2 Write "{\"file_path\":\"$W/ws/h2/x.txt\",\"content\":\"x\"}"

# a removed agent and a paused team get nothing, whatever the profile
touch "$W/state/removed/h3"
check "a removed agent on open is refused a skill" "$DENY" hook h3 Skill '{"skill":"loop"}'
check "and a web search"                           "$DENY" hook h3 WebSearch '{"query":"x"}'
rm -f "$W/state/removed/h3"
echo '{"ts": 0, "agent": "h2", "reason": "test"}' > "$W/state/HALT"
check "a pause refuses a subagent" "$DENY" sh -c "echo '{\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"x\"},\"cwd\":\"$W/ws/h2\"}' | python3 '$W/harness/hook.py' h2"
rm -f "$W/state/HALT"

# calls from inside a subagent are recorded as such
echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"cwd\":\"$W/ws/h2\",\"agent_id\":\"a1\",\"agent_type\":\"general-purpose\"}" \
  | python3 "$W/harness/hook.py" h2 >/dev/null
check "a call made inside a subagent is recorded with its type" '"subagent": "general-purpose"' tail -1 "$W/records/actions.jsonl"
check "offline_monitor.py counts calls made inside subagents" 'inside subagents: h2 1' sh -c "cd '$W' && python3 harness/offline_monitor.py"

# the session flags: connectors off and the same sandbox in every profile
for a in lead h1 h2 h3; do check "$a is started with connectors off" 'strict-mcp-config' argv_of $a; done
check "the brief is still the last argument, after --" '"--", "You are' argv_of h3
check "every profile gets the same sandbox" '^1$' python3 -c "
import json; s = [json.load(open('$W/harness/settings/%s.json' % a))['sandbox'] for a in ('h1', 'h2', 'h3')]
for x in s: x['filesystem']['denyRead'] = sorted(p for p in x['filesystem']['denyRead'] if '/ws/' not in p); x['filesystem'].pop('denyWrite')
print(len(set(json.dumps(x, sort_keys=True) for x in s)))"
check "profiles.py lists every agent" '^lead=sealed h1=research h2=allied h3=open$' sh -c "cd '$W' && python3 harness/profiles.py --list"

# precedence and bad settings
mk_workdir lead h1; setcfg profile '"allied"'; setcfg agent_profiles '{"lead": "sealed"}'; setup_wd
check "agent_profiles overrides the team default" '"Bash,Edit,Read,Write,Glob,Grep"' argv_of lead
check "the team default applies to the rest" 'Agent' argv_of h1
check "an agent can be given sealed explicitly" "$DENY" hook lead WebSearch '{"query":"x"}'
mk_workdir lead h1; setcfg profile '"wide-open"'
out=$(cd "$W" && ./setup.sh 2>&1); rc=$?
[ $rc -ne 0 ] && ok "setup.sh refuses an unknown team profile" || no "setup.sh refuses an unknown team profile" "$out"
check "and says which setting is wrong" "profile.*[\"']wide-open[\"']" echo "$out"
check "and stops before it creates anything" '^$' sh -c "ls -d '$W/ws' '$W/central.git' 2>/dev/null"
mk_workdir lead h1; setcfg agent_profiles '{"h9": "research"}'
check "setup.sh refuses a profile for an agent that is not on the team" "not in agents" sh -c "cd '$W' && ./setup.sh"
mk_workdir lead h1; setup_wd
python3 - "$W/config.json" <<'PY'
import json, sys; c = json.load(open(sys.argv[1])); c["agent_profiles"] = {"h1": "nonsense"}; json.dump(c, open(sys.argv[1], "w"))
PY
check "an unknown profile set after setup grants nothing, not even Bash" "$DENY" hook h1 Bash '{"command":"ls"}'
check "and run-agent.sh does not start the session" '^$' argv_of h1
finish
