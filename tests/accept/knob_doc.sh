#!/bin/bash
# Acceptance: the knobs documented for the boss  (see STATEMENTS.md, statement `knob_doc`)
. "$(dirname "$0")/../lib.sh"
S=$REPO/SKILL.md
# the Profiles section, down to the next heading of level 1 to 3 (it takes in "Unwalled runs" too)
prof=$(awk '/^#+ .*Profiles/{on=1; print; next} on && /^#{1,3} /{on=0} on' "$S")
[ -n "$prof" ] && ok "SKILL.md still has a Profiles section" || no "SKILL.md still has a Profiles section"
for k in web subagents skills shell_net; do check "the Profiles section names the knob \`$k\`" "\`$k\`" echo "$prof"; done
check "it shows the object form with a base" '"base"' echo "$prof"
check "it shows named custom profiles in config.json \"profiles\"" '"profiles"' echo "$prof"
check "it calls the named profiles presets or shortcuts" -i 'preset|shortcut' echo "$prof"
for p in sealed research allied open remote; do check "it still lists the preset \`$p\`" "\`$p\`" echo "$prof"; done
check "it says sealed is the default" -i 'sealed.{0,40}default|default.{0,40}sealed' echo "$prof"
check "it says the sandbox stays team-wide" -i 'team-wide|whole team|whole run|every agent' echo "$prof"
check "it says how status labels a custom profile" 'custom\(' echo "$prof"
check "the settings table mentions profiles" '^\| `profiles`' cat "$S"
check "README.md mentions the knobs" -i 'knob' cat "$REPO/README.md"
check "design.md describes the knobs" -i 'knob' cat "$REPO/references/design.md"
finish
