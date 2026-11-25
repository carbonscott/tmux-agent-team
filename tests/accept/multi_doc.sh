#!/bin/bash
# Acceptance: SKILL.md tells a boss how to run more than one team  (see STATEMENTS.md, statement `multi_doc`)
. "$(dirname "$0")/../lib.sh"
sec=$(awk '/^#+ Running more than one team/{on=1; print; next} on && /^#/{exit} on' "$REPO/SKILL.md")
[ -n "$sec" ] && ok "SKILL.md has a section 'Running more than one team'" || no "SKILL.md has a section 'Running more than one team'"
for w in "absolute path" "session" "wait-run.sh" "boss.sh" "[<session>]" "launch.sh"; do
  grep -qiF -- "$w" <<<"$sec" && ok "the section mentions '$w'" || no "the section mentions '$w'" "$sec"
done
check "step 6 shows the tag on wait-run.sh's first line" '\[<session>\]' sh -c "grep -F 'wait-run.sh\` prints' '$REPO/SKILL.md'"
check "the README mentions running more than one team" -i 'more than one team' cat "$REPO/README.md"
finish
