#!/bin/bash
# H7 and on of references/decisions/knobs.md: the fail-closed holes the audit found in the first
# resolver, each now closed. Sourced by tests/team/test_knob_audit.sh after tests/lib.sh; it uses
# only lib.sh's helpers and its own (prefixed k7_), and prints PASS/FAIL lines labelled H<n>:.
#
# Each hole is checked in two places: setup.sh (through profiles.py --check) refuses the config,
# and the monitor (hook.py) grants the agent nothing, not even Read, if such a config is in place.

k7_deny='"permissionDecision": "deny"'
k7_raw() {   # replace $W/config.json with the output of a python snippet that gets c = the current config
  python3 - "$W/config.json" "$1" <<'PY'
import json, sys
path, code = sys.argv[1], sys.argv[2]
c = json.load(open(path))
env = {"c": c, "json": json}
exec(code, env)
open(path, "w").write(env.get("text") or json.dumps(c, indent=2))
PY
}
k7_read_denied() { rm -f "$W/state/HALT"
  echo "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$W/ws/h1/STATEMENTS.md\"},\"cwd\":\"$W/ws/h1\"}" \
    | python3 "$W/harness/hook.py" h1 2>&1 | grep -qF "$k7_deny"; }
k7_case() {   # k7_case <H label> <what> <python that edits c or sets text> [skip-monitor]
  local h=$1 what=$2 code=$3 out
  mk_workdir lead h1; setup_wd >/dev/null 2>&1; k7_raw "$code"
  if out=$(cd "$W" && ./setup.sh 2>&1); then no "$h: setup.sh refuses $what" "$out"
  else ok "$h: setup.sh refuses $what"
    if grep -q Traceback <<<"$out"; then no "$h: with a message, not a traceback" "$out"; else ok "$h: with a message, not a traceback"; fi
  fi
  [ -n "${4:-}" ] && return
  k7_read_denied && ok "$h: and the monitor grants nothing for $what, not even Read" \
    || no "$h: and the monitor grants nothing for $what, not even Read"; }

# H7: a custom name with a trailing newline passed NAME_RE.match (the "$" matches before a final "\n")
k7_case H7 'a custom profile name with a trailing newline' \
  'c["profiles"] = {"reader\n": {"web": True}}; c["agent_profiles"] = {"h1": "reader\n"}'
out=$(cd "$W" && python3 harness/profiles.py --list 2>&1)
refute "H7: and no label carries the newline (reader<newline>(web))" 'reader\(' echo "$out"

# H8: a key given twice: json keeps the last one silently, so {"web": false, "web": true} turned web on
k7_case H8 'a knob given twice ({"web": false, "web": true})' \
  'text = json.dumps(c, indent=2)[:-2] + ",\n  \"agent_profiles\": {\"h1\": {\"web\": false, \"web\": true}}\n}"'
check "H8: and the message names the key given twice" 'web' sh -c "cd '$W' && python3 harness/profiles.py --check"
k7_case H8 'an agent given two profiles ("h1": "sealed", "h1": "open")' \
  'text = json.dumps(c, indent=2)[:-2] + ",\n  \"agent_profiles\": {\"h1\": \"sealed\", \"h1\": \"open\"}\n}"'
k7_case H8 'the team default given twice' \
  'c.pop("profile", None); text = json.dumps(c, indent=2)[:-2] + ",\n  \"profile\": \"sealed\",\n  \"profile\": \"open\"\n}"'

# H9: a chain of bases deep enough to exhaust Python's recursion: a traceback, not a message
k7_case H9 'a chain of 3000 bases' \
  'c["profiles"] = {"p%d" % i: {"base": "p%d" % (i + 1)} for i in range(3000)}; c["profiles"]["p3000"] = {"web": True}; c["agent_profiles"] = {"h1": "p0"}'

# H10: names a label uses for something else: "custom" would read like an inline object
k7_case H10 'a custom profile named custom' 'c["profiles"] = {"custom": {"web": True}}; c["agent_profiles"] = {"h1": "custom"}'
k7_case H10 'a custom profile named invalid' 'c["profiles"] = {"invalid": {"web": True}}; c["agent_profiles"] = {"h1": "invalid"}'

# H11: agent_profiles or profiles that is not an object: setup refuses it, and the monitor must not
# fall back to the team default (sealed grants Read) for an agent the config was meant to name
k7_case H11 'agent_profiles given as a list' 'c["agent_profiles"] = ["open"]'
k7_case H11 'profiles given as a list' 'c["profiles"] = [{"web": True}]; c["agent_profiles"] = {"h1": "sealed"}'
