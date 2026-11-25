#!/bin/bash
# Team tests for `nogoal`: what tests/accept/nogoal.sh does not cover. The sections of
# test_fixes.sh that held the converter's tests, the parts of references/goal.md that go and
# stay, and the pointers in SKILL.md, design.md, claude-code.md and test_gateway.sh.
. "$(dirname "$0")/../lib.sh"
cd "$REPO" || exit 1

# test_fixes.sh: sections T, V and L3 pass, and nothing in it builds a task from a contract
out=$(bash tests/team/test_fixes.sh T V L3 2>&1); rc=$?
[ $rc -eq 0 ] && ok "test_fixes.sh T V L3 exits 0" || no "test_fixes.sh T V L3 exits 0" "$out"
refute "test_fixes.sh T V L3 has no FAIL line" '^FAIL' echo "$out"
check "test_fixes.sh T runs T1 and T2" 'PASS  T1 .*' echo "$out"
check "and T2" 'PASS  T2 .*' echo "$out"
check "and V and L3" 'PASS  L3 .*' echo "$out"
refute "test_fixes.sh has no T3 and no section U" '"T3 |"U |want U' cat tests/team/test_fixes.sh
refute "test_fixes.sh names no contract fixture" 'contract\.json|accept/fixtures' cat tests/team/test_fixes.sh

# references/goal.md: what goes and what stays
G=references/goal.md
check "goal.md's title is about running /goal with the team" '^# Running `/goal` with the team$' head -1 "$G"
refute "goal.md has no 'How the checks run' part" -i 'how the checks run' cat "$G"
refute "goal.md has no 'What the boss still owns' section" -i 'what the boss still owns' cat "$G"
refute "goal.md says nothing of the converter's probe handling" -i 'never writes `task/probe/`|replace-statements|earlier text' cat "$G"
check "goal.md keeps the table of the two ways" '^\| The boss under `/goal` \|' cat "$G"
check "and its second row" '^\| An agent under `/goal` \|' cat "$G"
check "goal.md says the boss may be driven by a contract it wrote itself" -i 'make-goal contract it wrote itself' cat "$G"
check "goal.md keeps 'What to watch for'" '^### [0-9]\. What to watch for' cat "$G"
check "goal.md keeps 'What stays forbidden'" '^## What stays forbidden' cat "$G"
check "goal.md keeps 'An agent under /goal'" '^## An agent under `/goal`' cat "$G"
check "goal.md's sections are numbered 1 and 2" '^### 1\..*### 2\.' sh -c "grep '^### ' '$G' | tr '\n' ' '"

# SKILL.md and the other docs
refute "SKILL.md's Commands table has no converter row" -i 'turns a make-goal contract' cat SKILL.md
check "SKILL.md still puts an agent under /goal with boss.sh slash" 'boss\.sh slash <id> "/goal' cat SKILL.md
check "SKILL.md's More entry for goal.md says how to run /goal" '^- `references/goal\.md`: how to run `/goal` with the team' cat SKILL.md
check "README.md's row for goal.md names running /goal" '^\| `references/goal\.md` \| Running `/goal` with the team' cat README.md
check "claude-code.md keeps a /goal row that points to goal.md" '^\| `/goal` \|.*`references/goal\.md` \|$' cat references/claude-code.md
check "design.md keeps the boss under /goal as requested only" '^\| The boss under `/goal`.*Requested only' cat references/design.md
refute "nothing says the converter was removed" -i 'no longer (converts|writes a task)|used to (convert|write)' cat SKILL.md README.md references/design.md references/goal.md references/claude-code.md

# test_gateway.sh: the comment, and its logic unchanged
check "test_gateway.sh's comment names a task without task.attempted_if" 'Without it \(a task without `task\.attempted_if`\)' cat template/harness/test_gateway.sh
check "test_gateway.sh still reads attempted_if" "get\('attempted_if'\)" cat template/harness/test_gateway.sh
finish
