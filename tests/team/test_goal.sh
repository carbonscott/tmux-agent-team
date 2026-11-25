#!/bin/bash
# Team tests for `goal`: edge cases of from-goal.py and of task.checks that the acceptance
# test does not cover.
. "$(dirname "$0")/../lib.sh"
FIX=$REPO/tests/accept/fixtures/contract.json

mk_workdir lead h1 h2
C=$TOP/contracts; mkdir -p "$C"
python3 - "$C" <<'PY'
import json, sys
d = sys.argv[1]
base = {"goal": "g", "type": "deterministic", "guardrails": ["Only out/ may change."]}
def put(name, items, **kw):
    json.dump(dict(base, done_when=items, **kw), open("%s/%s.json" % (d, name), "w"))
put("names", [
    "The file out/alpha.txt holds ok, proven by printing the output of `grep -x ok out/alpha.txt`.",
    "The file out/alpha.txt has no trailing blank line, proven by printing the output of `test -z \"$(tail -c1 out/alpha.txt | tr -d '\\n')\"`.",
    "The test suite passes, proven by printing the final line of `sh run-tests.sh`.",
    "`make` builds bin/tool, proven by printing the output of `test -x bin/tool`.",
    "The claims file is complete, proven by printing the output of `cat .goal/x.claims.json`.",
    {"not": "a sentence"},
])
put("printonly", ["Every file in src is short, proven by printing the output of `wc -l src/a.py`."])
put("notype", ["out/a.txt holds ok, proven by printing the output of `grep -qx ok out/a.txt`."])
del base["type"]
put("untyped", ["out/a.txt holds ok, proven by printing the output of `grep -qx ok out/a.txt`."])
PY
plan() { ( cd "$W" && python3 harness/from-goal.py "$@" ); }
check "names come from the path an item names" '^ok$' python3 -c "
import json, re, sys
p = json.loads(sys.argv[1]); n = [s['name'] for s in p['statements']]
assert n[0] == 'alpha' and n[1] == 'alpha_2', n
assert all(re.fullmatch('[a-z0-9_]+', x) for x in n) and len(set(n)) == len(n), n
print('ok')" "$(plan "$C/names.json" 2>/dev/null)"
check "an item without a path is named from its words" '"name": "test_suite"' plan "$C/names.json"
check "the command after \"proven by\" is the check" '"check": "test -x bin/tool"' plan "$C/names.json"
check "and that item is named after its path" '"name": "tool"' plan "$C/names.json"
check "an item about the contract's own .goal/ files is skipped" '^ok$' python3 -c "
import json, sys
p = json.loads(sys.argv[1])
assert not any('.goal/' in s['check'] for s in p['statements']), p['statements']
assert any('.goal/' in s['text'] for s in p['skipped']), p['skipped']
assert len(p['skipped']) == 2, p['skipped']
print('ok')" "$(plan "$C/names.json" 2>/dev/null)"
check "a check that exits 0 whatever it prints is warned about" 'WARNING: .*wc -l src/a.py.*exit' plan "$C/printonly.json"
plan "$C/printonly.json" >/dev/null 2>&1 && ok "but the plan is still printed" || no "but the plan is still printed"
plan "$C/untyped.json" >/dev/null 2>&1 && ok "a contract without a type is taken as deterministic" \
  || no "a contract without a type is taken as deterministic"
check "the plan carries the contract's guardrails" 'Do not modify any file outside out/' plan "$FIX"

cp "$W/config.json" "$TOP/config.before"; cp "$W/task/seed/STATEMENTS.md" "$TOP/statements.before"
refuses() { local label=$1; shift; if plan "$@" >/dev/null 2>&1; then no "$label"; else
  cmp -s "$W/config.json" "$TOP/config.before" && cmp -s "$W/task/seed/STATEMENTS.md" "$TOP/statements.before" \
    && ok "$label" || no "$label" "config.json or STATEMENTS.md changed"; fi; }
refuses "--apply without --allowed is refused and writes nothing" "$FIX" --apply
refuses "--allowed without --apply is refused" "$FIX" --allowed 'out/.*'
refuses "an --allowed that is not a regular expression is refused" "$FIX" --apply --allowed 'out/(['
refuses "a contract that is not JSON is refused" "$REPO/STATEMENTS.md"
refuses "a missing contract is refused" "$C/nothing-here.json"
check "a refusal says why" 'not a regular expression' plan "$FIX" --apply --allowed 'out/(['
check "an allowed pattern that frees STATEMENTS.md is warned about" 'WARNING: .*STATEMENTS.md' \
  plan "$FIX" --apply --allowed '.*'
check "--apply points out the example task's leftovers" 'note: ' plan "$FIX" --apply --allowed 'out/[a-z]+\.txt'
check "a statement with no own check can never pass" '^ok$' python3 -c "
import json, subprocess
c = json.load(open('$W/config.json'))['task']
assert 'attempted_if' not in c, c
r = subprocess.run(['sh', '-c', c['check'].format(name='zeta')], capture_output=True, text=True)
assert r.returncode != 0 and 'zeta' in r.stderr, r
print('ok')"
check "STATEMENTS.md lists each check and the allowed paths" '^ok$' python3 -c "
s = open('$W/task/seed/STATEMENTS.md').read()
assert 'Check: \`grep -x ok out/alpha.txt\`' in s and 'Check: \`grep -x ok out/beta.txt\`' in s, s
assert 'out/[a-z]+\\\\.txt' in s, s
print('ok')"

# A mixed task: b has its own check (with shell braces, used as written), a and c use task.check.
mk_workdir lead h1 h2
setcfg task.checks '{"b": "test \"$(cat out/b.txt)\" = yes && awk '"'"'{ n++ } END { exit n == 1 ? 0 : 1 }'"'"' out/b.txt"}'
check "the brief keeps one command when there is no task.checks" '`grep -qx ok out/<name>.txt`' \
  sh -c "cd '$W' && python3 harness/render.py h1"
setup_wd && ok "setup.sh accepts a task.checks map" || no "setup.sh accepts a task.checks map"
out=$(cd "$W" && python3 harness/render.py h1)
check "the brief lists a statement's own check" '`b`: `test "\$\(cat out/b.txt\)" = yes' echo "$out"
check "and the check of every other statement" 'every other statement: `grep -qx ok out/<name>.txt`' echo "$out"
refute "and leaves no placeholder behind" '\{CHECK\}|\{name\}' echo "$out"
check "the lead's brief lists them too" '## Checks' sh -c "cd '$W' && python3 harness/render.py lead"
launch >/dev/null 2>&1; start_gateway
check "a statement's own check rejects what task.check would accept" 'REJECTED by the check' land h1 b "b says ok" ok
check "and accepts its own right answer" 'ACCEPTED' land h1 b "b says yes" yes
check "the other statements keep task.check" 'ACCEPTED' land h2 a
check "and both count" 'done on main \(2/3\): (a b|b a)' as h2 team status
v=$(cd "$W" && python3 harness/verify.py 2>&1)
check "verify.py shows the command it ran for b" 'check: test "\$\(cat out/b.txt\)" = yes' echo "$v"
refute "and only for statements with their own check" 'check: grep' echo "$v"
check "verify.py fails the open statement" 'FAIL  c' echo "$v"
check "from-goal.py refuses this work directory now that setup.sh has run" 'setup.sh has already run' \
  sh -c "cd '$W' && python3 harness/from-goal.py '$FIX' --apply --allowed 'out/.*'"
finish
