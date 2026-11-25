#!/bin/bash
# Acceptance: a make-goal contract becomes the team's task  (see STATEMENTS.md, statement `goal`)
. "$(dirname "$0")/../lib.sh"
FIX=$REPO/tests/accept/fixtures/contract.json

mk_workdir lead h1 h2
cp "$W/config.json" "$TOP/config.before"
plan=$(cd "$W" && python3 harness/from-goal.py "$FIX" 2>/dev/null)
check "from-goal.py prints a plan: one statement per item that names a command" '^ok$' python3 -c "
import json, re, sys
p = json.loads(sys.argv[1]); s = p['statements']
assert len(s) == 2, s
assert 'grep -x ok out/alpha.txt' in s[0]['check'] and 'grep -x ok out/beta.txt' in s[1]['check'], s
assert all(re.fullmatch('[a-z0-9_]+', x['name']) for x in s) and s[0]['name'] != s[1]['name'], s
assert 'out/alpha.txt' in s[0]['text'], s
assert len(p['skipped']) == 2, p['skipped']
print('ok')" "$plan"
cmp -s "$W/config.json" "$TOP/config.before" && ok "without --apply nothing is written" || no "without --apply nothing is written"

( cd "$W" && python3 harness/from-goal.py "$FIX" --apply --allowed 'out/[a-z]+\.txt' ) >/dev/null 2>&1 \
  && ok "from-goal.py --apply --allowed <regex> succeeds" || no "from-goal.py --apply --allowed <regex> succeeds"
check "config.json holds the statements, a check for each, and the allowed paths" '^ok$' python3 -c "
import json, sys
p = json.loads(sys.argv[1]); t = json.load(open('$W/config.json'))['task']
names = [x['name'] for x in p['statements']]
assert t['statements'] == names, t['statements']
assert all(x['check'] == t['checks'][x['name']] for x in p['statements']), t.get('checks')
assert t['allowed_paths'] == ['out/[a-z]+\\\\.txt'], t['allowed_paths']
assert 'attempted_if' not in t, t
print('ok')" "$plan"
N1=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['statements'][0]['name'])" "$plan" 2>/dev/null)
N2=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['statements'][1]['name'])" "$plan" 2>/dev/null)
check "STATEMENTS.md is written from the contract" "${N1:-missing}" cat "$W/task/seed/STATEMENTS.md"
check "and carries the text of each item" 'out/beta.txt' cat "$W/task/seed/STATEMENTS.md"
check "and the guardrails" 'Do not modify any file outside out/' cat "$W/task/seed/STATEMENTS.md"

rm -rf "$W/task/probe"; setup_wd && ok "setup.sh accepts the generated task" || no "setup.sh accepts the generated task"
launch >/dev/null 2>&1; start_gateway
check "the first statement lands through the merge job" 'ACCEPTED' land h1 alpha
check "and is counted under its name" "done on main \(1/2\): ${N1:-missing}" as h2 team status
check "a wrong answer does not count" "done on main: ${N1:-missing}\$" land h2 beta "wrong beta" no
check "the second statement completes the run" 'RUN COMPLETE' land h2 beta "right beta" ok
check "verify.py uses the per-statement checks" '2 of 2 statements pass' sh -c "cd '$W' && python3 harness/verify.py"
check "the briefs render with per-statement checks" . sh -c "cd '$W' && python3 harness/render.py h1"

( cd "$W" && python3 harness/from-goal.py "$FIX" --apply --allowed 'out/.*' ) >/dev/null 2>&1 \
  && no "--apply refuses once setup.sh has run" || ok "--apply refuses once setup.sh has run"
python3 -c "
import json; c = json.load(open('$FIX')); c['type'] = 'exploratory'; json.dump(c, open('$TOP/exploratory.json', 'w'))
c['type'] = 'deterministic'; c['done_when'] = c['done_when'][2:]; json.dump(c, open('$TOP/nocheck.json', 'w'))"
mk_workdir lead h1
( cd "$W" && python3 harness/from-goal.py "$TOP/../$(basename "${TOPS[0]}")/exploratory.json" ) >/dev/null 2>&1 \
  && no "an exploratory contract is refused" || ok "an exploratory contract is refused"
( cd "$W" && python3 harness/from-goal.py "${TOPS[0]}/nocheck.json" ) >/dev/null 2>&1 \
  && no "a contract with no checkable item is refused" || ok "a contract with no checkable item is refused"

check "references/goal.md explains running the boss under /goal" 'verify\.py' cat "$REPO/references/goal.md"
check "SKILL.md documents from-goal.py" 'from-goal' cat "$REPO/SKILL.md"
finish
