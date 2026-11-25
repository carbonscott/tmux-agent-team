#!/bin/bash
# Acceptance: the make-goal converter is gone; /goal and task.checks stay  (see STATEMENTS.md, statement `nogoal`)
. "$(dirname "$0")/../lib.sh"
cd "$REPO" || exit 1

# 1. The converter, its tests and every pointer to it are gone.
for f in template/harness/from-goal.py tests/team/test_goal.sh tests/accept/goal.sh tests/accept/fixtures/contract.json; do
  [ -e "$f" ] && no "$f is deleted" || ok "$f is deleted"
done
hits=$(grep -rnE 'from-goal|from_goal|--replace-statements|done_when' SKILL.md README.md references template tests \
  --exclude-dir=decisions --exclude-dir=.check-cache --exclude-dir=__pycache__ \
  | grep -v '^tests/accept/nogoal\.sh:' | grep -v '^tests/team/test_nogoal\.sh:')
[ -z "$hits" ] && ok "nothing names from-goal.py or a contract's done_when" || no "nothing names from-goal.py or a contract's done_when" "$hits"
refute "SKILL.md has no 'From a make-goal contract' paragraph" -i 'from a make-goal contract' cat SKILL.md
refute "README.md no longer offers a make-goal contract as the team's task" -i "contract as the team's task|written from a make-goal contract" cat README.md
refute "design.md no longer lists a task written from a contract" -i 'task written from a (make-)?goal contract' cat references/design.md
refute "claude-code.md has no Goal contracts row" '^\| Goal contracts' cat references/claude-code.md

# 2. What stays: task.checks, boss.sh slash, and references/goal.md on running /goal.
check "SKILL.md still documents task.checks" '^\| `task.checks`' cat SKILL.md
check "SKILL.md still documents boss.sh slash" 'boss\.sh slash' cat SKILL.md
check "SKILL.md still points to references/goal.md" 'references/goal\.md' cat SKILL.md
G=references/goal.md
[ -s "$G" ] && ok "references/goal.md is kept" || no "references/goal.md is kept"
refute "its title is no longer about a make-goal contract" -i 'make-goal contract' head -1 "$G"
check "it explains the boss under /goal, proven by verify.py" 'verify\.py' cat "$G"
check "it explains an agent under /goal with boss.sh slash" 'boss\.sh slash <id> "/goal' cat "$G"
check "it keeps the two-loops warning" -i 'two loops' cat "$G"
check "it keeps the live run" 'Goal achieved' cat "$G"
refute "it no longer explains turning a contract into the task" -i 'turn the contract into|--apply|skipped item' cat "$G"

# 3. task.checks still works end to end (moved here from the deleted tests/team/test_goal.sh).
mk_workdir lead h1 h2
setcfg task.checks '{"b": "test \"$(cat out/b.txt)\" = yes && awk '"'"'{ n++ } END { exit n == 1 ? 0 : 1 }'"'"' out/b.txt"}'
setup_wd && ok "setup.sh accepts a task.checks map" || no "setup.sh accepts a task.checks map"
out=$(cd "$W" && python3 harness/render.py h1)
check "the brief lists a statement's own check" '`b`: `test "\$\(cat out/b.txt\)" = yes' echo "$out"
check "and the check of every other statement" 'every other statement: `grep -qx ok out/<name>.txt`' echo "$out"
launch >/dev/null 2>&1; start_gateway
check "a statement's own check rejects what task.check would accept" 'REJECTED by the check' land h1 b "b says ok" ok
check "and accepts its own right answer" 'ACCEPTED' land h1 b "b says yes" yes
check "the other statements keep task.check" 'ACCEPTED' land h2 a
v=$(cd "$W" && python3 harness/verify.py 2>&1)
check "verify.py shows the command it ran for b" 'check: test "\$\(cat out/b.txt\)" = yes' echo "$v"
stop_gateway

# 4. A task without task.attempted_if and with its own checks passes its pre-launch test.
mk_workdir lead h1 h2
python3 - "$W/config.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); t = c["task"]
t.pop("attempted_if", None)
t["statements"] = ["alpha", "beta"]
t["checks"] = {"alpha": "grep -x ok out/alpha.txt", "beta": "grep -x ok out/beta.txt"}
t["check"] = 'echo "statement {name} has no entry in task.checks" >&2; exit 1'
t["allowed_paths"] = ["out/[a-z]+\\.txt"]
json.dump(c, open(p, "w"))
PY
rm -rf "$W/task/probe"; mkdir -p "$W/task/probe/good/out" "$W/task/probe/bad/out"
echo ok > "$W/task/probe/good/out/alpha.txt"; echo no > "$W/task/probe/bad/out/alpha.txt"
setup_wd; out=$(cd "$W" && harness/test_gateway.sh 2>&1)
refute "test_gateway.sh passes on a task without attempted_if" '^FAIL' echo "$out"
check "the wrong answer is merged but not counted" "PASS  the task's wrong answer is merged but not counted as done" echo "$out"
check "the right answer is counted" "PASS  the task's right answer is counted as done" echo "$out"

# 5. The test files that held from-goal sections still pass where they touch goal and slash.
out=$(bash tests/team/test_fixes.sh T U V L3 2>&1); refute "test_fixes.sh sections T U V L3 pass" '^FAIL' echo "$out"
out=$(bash tests/team/test_knob_doc.sh 2>&1); refute "test_knob_doc.sh passes" '^FAIL' echo "$out"
finish
