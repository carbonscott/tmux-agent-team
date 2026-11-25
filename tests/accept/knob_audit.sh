#!/bin/bash
# Acceptance: the hardening audit of composable knobs  (see STATEMENTS.md, statement `knob_audit`)
# The verdicts themselves are tested by tests/team/test_knob_audit.sh, which check.sh runs next.
. "$(dirname "$0")/../lib.sh"
D=$REPO/references/decisions/knobs.md
T=$REPO/tests/team/test_knob_audit.sh
[ -s "$D" ] && ok "references/decisions/knobs.md exists" || { no "references/decisions/knobs.md exists"; finish; exit 1; }
for h in 1 2 3 4 5 6; do
  sec=$(awk -v h="$h" '/^## /{on = ($0 ~ "^## H" h "([^0-9]|$)")} on' "$D")
  [ -n "$sec" ] && ok "H$h has its own section (## H$h ...)" || { no "H$h has its own section (## H$h ...)"; continue; }
  for f in Prediction Experiment Result; do
    grep -qE "^\*\*$f[:.]?\*\*|^$f:" <<<"$sec" && ok "H$h states its $f" || no "H$h states its $f"
  done
  check "H$h gives one verdict: supported, refuted or inconclusive" -i '^(\*\*)?Verdict:?(\*\*)?:? *(\*\*)?(supported|refuted|inconclusive)' echo "$sec"
  check "H$h's experiment is a test in test_knob_audit.sh (a PASS label that starts H$h:)" "[\"']H$h:" cat "$T"
done
check "the record has a section of experiments for the boss (real sessions)" '^## Boss experiments' cat "$D"
check "the boss experiments give commands to run" '(selftest\.sh|claude )' sh -c "awk '/^## Boss experiments/{on=1;next} /^## /{on=0} on' '$D'"
check "the record ends in a recommendation" '^## Recommendation' cat "$D"
check "the recommendation says whether the sandbox can be per agent" -i 'per[- ]agent' sh -c "awk '/^## Recommendation/{on=1;next} /^## /{on=0} on' '$D'"
check "SKILL.md or design.md links the record" 'decisions/knobs\.md' cat "$REPO/SKILL.md" "$REPO/references/design.md"
finish
