#!/bin/bash
# Team tests for `knob_doc`: what tests/accept/knob_doc.sh does not cover. The docs must agree
# with what the code does: the preset table against profiles.PRESETS, the tool order, the labels
# against profiles.py's own output, and no text left over from the fixed list of profiles.
. "$(dirname "$0")/../lib.sh"
S=$REPO/SKILL.md
prof=$(awk '/^#+ .*Profiles/{on=1; print; next} on && /^#{1,3} /{on=0} on' "$S")

# the preset table in SKILL.md says exactly the knobs profiles.py gives each preset
for p in sealed research allied open remote; do
  doc=$(grep -E "^\| \`$p\`" <<<"$prof" | head -1 | cut -d'|' -f3 | grep -oE '`(web|subagents|skills|shell_net)`|all four|none' | tr -d '`' | paste -sd, -)
  code=$(cd "$REPO/template/harness" && python3 -c "
import profiles, sys; k = [x for x in profiles.KNOBS if x in profiles.PRESETS[sys.argv[1]]]
print('all four' if len(k) == 4 else (','.join(k) or 'none'))" "$p")
  [ -n "$doc" ] && [ "$doc" = "$code" ] && ok "SKILL.md's preset table gives $p the knobs profiles.py does ($code)" \
    || no "SKILL.md's preset table gives $p the knobs profiles.py does" "doc: $doc / code: $code"
done
check "the knob table names each knob's tools as profiles.py grants them" 'WebSearch`, `WebFetch' echo "$prof"
check "SKILL.md shows the knob order of the labels" 'web,subagents,skills,shell_net' echo "$prof"
check "SKILL.md shows the label of a named custom profile" '<name>\(<knobs on>\)|reader\(web\)' echo "$prof"
check "SKILL.md shows custom() for an object with no knob on" 'custom\(\)' echo "$prof"
check "SKILL.md says an unresolvable profile grants nothing" -i 'no tool at all|grants nothing' echo "$prof"
check "SKILL.md says why the sandbox is not per agent (what one unwalled agent could reach)" -i 'central\.git' echo "$prof"
check "the profile row of the settings table takes a knob object" '^\| `profile`, `agent_profiles` .*knob object' cat "$S"
check "the profiles row gives the name rule" '^\| `profiles` .*lower-case' cat "$S"
check "boss.sh slash in the command table names the skills knob" '`skills` knob' grep 'slash <id>' "$S"

# what SKILL.md shows boss.sh status printing is what profiles.py prints for the same config
mk_workdir lead h1 h2 h3
setcfg profiles '{"reader": {"web": true}, "delegator": {"base": "reader", "subagents": true}}'
setcfg agent_profiles '{"h1": "reader", "h2": {"base": "open", "web": false}, "h3": {}}'
setup_wd || no "setup.sh accepts the documented example"
check "profiles.py lists lead=sealed, as documented" '(^| )lead=sealed( |$)' sh -c "cd '$W' && python3 harness/profiles.py --list"
check "profiles.py lists h1=reader(web), as documented" 'h1=reader\(web\)' sh -c "cd '$W' && python3 harness/profiles.py --list"
check "{\"base\": \"open\", \"web\": false} is subagents+skills, as documented" 'h2=custom\(subagents,skills\)' sh -c "cd '$W' && python3 harness/profiles.py --list"
check "an empty object is custom(), as documented" 'h3=custom\(\)' sh -c "cd '$W' && python3 harness/profiles.py --list"
# the example in SKILL.md is valid config
ex=$(grep -E '^ +"profiles": \{"reader"' "$S"; grep -E '^ +"agent_profiles": \{"h1": "reader"' "$S")
mk_workdir lead h1 h2 h3
python3 - "$W/config.json" "$ex" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c.update(json.loads("{" + sys.argv[2].strip().replace("\n", "") + "}"))
json.dump(c, open(sys.argv[1], "w"))
PY
check "SKILL.md's config example passes profiles.py --check" '^$' sh -c "cd '$W' && python3 harness/profiles.py --check"
check "and labels its agents as SKILL.md says" 'h1=reader\(web\) h2=delegator\(web,subagents\) h3=custom\(skills\)' sh -c "cd '$W' && python3 harness/profiles.py --list"

# nothing left from the fixed list of five
for f in "$S" "$REPO/README.md" "$REPO/references/design.md" "$REPO/references/goal.md" "$REPO/references/claude-code.md"; do
  refute "$(basename "$f") has no text left from the fixed list of profiles" -i 'fixed list of five|custom profile in `config.json` was left out|every profile but `remote`|profile\s+is not `open`' cat "$f"
done
check "design.md links the audit record" 'decisions/knobs\.md' cat "$REPO/references/design.md"
finish
