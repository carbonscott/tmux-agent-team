#!/bin/bash
# Team tests for `wildcard`: team precheck, the merge job's verdict without landing.
# See references/decisions/team-choice.md for why it was chosen.
. "$(dirname "$0")/../lib.sh"
# commit out/<s>.txt on top of main, without landing it
prep() { as "$1" sh -c 'git fetch -q origin main && git reset -q --hard origin/main
  mkdir -p out && echo "$2" > "out/$1.txt" && git add -A out && git commit -q -m "$1"' sh "$2" "${3:-ok}"; }
main_sha() { git -C "$W/central.git" rev-parse refs/heads/main; }
merges() { cat "$W/records/merges.jsonl" 2>/dev/null | wc -l; }

mk_workdir lead h1 h2; setup_wd; launch >/dev/null 2>&1; start_gateway
M0=$(main_sha)

# a right answer: the verdict is given, nothing lands
prep h1 a
out=$(as h1 team precheck 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q 'PRECHECK PASSED' <<<"$out" && ok "precheck passes a right answer" || no "precheck passes a right answer" "$rc $out"
check "it says what would be done" 'done on main would be: a' echo "$out"
refute "it does not claim to have merged" 'ACCEPTED: merged' echo "$out"
[ "$(main_sha)" = "$M0" ] && ok "main does not move" || no "main does not move"
check "nothing is counted as landed" '^\[\]$' cat "$W/state/landed.json"
check "no merge is recorded" '^0$' merges
refute "no branch is written in the central repository" 'agent/h1' git -C "$W/central.git" branch --list
as h1 sh -c 'echo scratch > notes.txt'
check "uncommitted changes are named as left out" 'uncommitted changes are not part of it' as h1 team precheck
as h1 rm -f notes.txt
check "team status still shows nothing done" 'done on main \(0/3\)' as h2 team status
refute "the private clone is cleaned up" 'pre-' ls "$W/state/ci"
check "the same HEAD then lands with team mr" 'ACCEPTED: merged into main' as h1 team mr "land a"
check "and that is the only merge recorded" '^1$' merges

# what the merge job would refuse, precheck refuses with the reason
out=$(as h1 team precheck 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'Nothing new' <<<"$out" && ok "precheck of what is already on main says nothing is new" || no "precheck of what is already on main says nothing is new" "$rc $out"
prep h2 b no
out=$(as h2 team precheck 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'PRECHECK FAILED' <<<"$out" && ok "precheck fails a wrong answer" || no "precheck fails a wrong answer" "$rc $out"
check "and says the check fails, naming the statement" 'check fails.*`b`' echo "$out"
as h2 sh -c 'git reset -q --hard origin/main && echo x > frozen.txt && git add frozen.txt && git commit -q -m frozen'
check "precheck names a frozen path" 'may not be changed:' as h2 team precheck
check "precheck names the frozen file" 'frozen.txt' as h2 team precheck

# a conflict with what landed after the branch was made
prep h2 c "maybe"
land h1 c >/dev/null 2>&1
out=$(as h2 team precheck 2>&1)
check "precheck names the conflicting file" 'Merge conflict with main in: out/c.txt' echo "$out"
check "and says how to fix it" 'git merge origin/main' echo "$out"
check "--quick finds the conflict too" 'Merge conflict with main in: out/c.txt' as h2 team precheck --quick
as h2 sh -c 'git merge -q origin/main >/dev/null 2>&1; echo ok > out/c.txt; git add out/c.txt; git commit -q -m resolved; echo ok > out/b.txt; git add out/b.txt; git commit -q -m b'
check "after the fix it passes" 'PRECHECK PASSED' as h2 team precheck
check "--quick says it merges cleanly, and that the checks were not run" 'merges cleanly.*not run' as h2 team precheck --quick
as h2 sh -c 'echo no > out/b.txt; git commit -qam "wrong b"'
check "--quick does not run the checks" 'PRECHECK \(quick\) PASSED' as h2 team precheck --quick
check "the full precheck does" 'PRECHECK FAILED' as h2 team precheck
as h2 sh -c 'git reset -q --hard HEAD~1'
check "the run is still not complete" 'done on main \(2/3\)' as h2 team status
refute "precheck never completes a run" . sh -c "ls '$W/state/DONE' 2>/dev/null"
check "every precheck is logged under the sender's name" '"agent": "h2", "op": "precheck"' cat "$W/records/gateway.jsonl"
check "team help lists precheck" 'team precheck' as h1 team help
refute "no private clone is left behind" 'pre-' ls "$W/state/ci"

# the door's rules apply: pause, removal, time up
echo '{"ts": 0, "agent": "h1", "reason": "test"}' > "$W/state/HALT"
check "a paused team gets no precheck" 'TEAM PAUSED' as h2 team precheck
rm -f "$W/state/HALT"
( cd "$W" && harness/boss.sh remove h1 ) >/dev/null 2>&1
check "a removed agent gets no precheck" 'removed' as h1 team precheck
( cd "$W" && harness/boss.sh end ) >/dev/null 2>&1
check "after time is up there is no precheck" 'TIME IS UP' as h2 team precheck

check "the helper brief describes team precheck" 'team precheck' cat "$W/docs/helper.md"
check "the lead brief describes team precheck" 'team precheck' cat "$W/docs/lead.md"
check "SKILL.md documents team precheck" 'team precheck' cat "$REPO/SKILL.md"
check "the decision record names the choice" 'precheck' cat "$REPO/references/decisions/team-choice.md"
finish
