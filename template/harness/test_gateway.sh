#!/bin/bash
# Pre-launch test of the gateway and the merge job: try what they must refuse, then reset.
# Run after setup.sh and before the first launch.
set -u
R=$(cd "$(dirname "$0")/.." && pwd); cd "$R"; cfg() { python3 "$R/harness/cfg.py" "$1"; }
[ -e state/started ] && { echo "a run has already started here; this test would reset its work"; exit 1; }
[ -d ws ] && [ -d central.git ] || { echo "run ./setup.sh first"; exit 1; }
AG=($(cfg agents)); H1=${AG[1]}; H2=${AG[2]:-}
T=$R/bin/team; export GIT_CONFIG_GLOBAL=/dev/null
echo '[]' > state/landed.json; python3 -c "import time;open('state/deadline','w').write(str(time.time()+3600))"
python3 -u "$R/harness/gateway.py" > state/gw-test.log 2>&1 & GW=$!
trap 'kill $GW 2>/dev/null' EXIT    # never leave a test gateway behind
sleep 1.5; kill -0 $GW 2>/dev/null || { cat state/gw-test.log; exit 1; }
ok=0; bad=0
as() { ( cd "$R/ws/$1" && shift && "$@" ); }
check() { local label=$1 pat=$2; shift 2; local out; out=$("$@" 2>&1)
  if echo "$out" | grep -qE "$pat"; then echo "PASS  $label"; ok=$((ok+1))
  else echo "FAIL  $label"; echo "$out" | tail -3 | sed 's/^/        /'; bad=$((bad+1)); fi; }

echo "-- the board"
check "the lead is seen as lead"                    '^lead$'      as lead $T whoami
check "the lead can create a table"                 '^lead$'      as lead $T sql "CREATE TABLE t_probe(id INTEGER PRIMARY KEY, who TEXT DEFAULT (me()), msg TEXT); INSERT INTO t_probe(msg) VALUES ('hello') RETURNING who"
check "a helper's rows carry the helper's name"     "^$H1\$"      as $H1 $T sql "INSERT INTO t_probe(msg) VALUES ('from a helper') RETURNING who"
check "a helper cannot delete rows"                 'not allowed' as $H1 $T sql "DELETE FROM t_probe"
check "a helper cannot create tables"               'not allowed' as $H1 $T sql "CREATE TABLE x(i)"
check "a helper cannot drop the lead's table"       'not allowed' as $H1 $T sql "DROP TABLE t_probe"
check "nobody can attach another database file"     'not allowed' as lead $T sql "ATTACH DATABASE '/tmp/x.db' AS x"
check "a runaway statement is cancelled"            'cancelled after' as $H1 $T sql "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c) SELECT count(*) FROM c"
as $H1 $T sql "UPDATE t_probe SET msg='changed' WHERE id=1; SELECT nope FROM missing" >/dev/null 2>&1
check "a failed request changes nothing"            '^hello$'     as $H1 $T sql "SELECT msg FROM t_probe WHERE id=1"
if [ -n "$H2" ]; then
  as lead $T sql "CREATE TABLE t_claim(id INTEGER PRIMARY KEY, owner TEXT); INSERT INTO t_claim VALUES (1, NULL)" >/dev/null
  CLAIM="UPDATE t_claim SET owner = me() WHERE id = 1 AND owner IS NULL RETURNING owner"
  as $H1 $T sql "$CLAIM" > state/c1.out 2>&1 & P1=$!
  as $H2 $T sql "$CLAIM" > state/c2.out 2>&1 & P2=$!
  wait $P1 $P2    # not a bare wait: the gateway is also a child of this script
  check "two simultaneous claims produce one winner" '^1$'        echo "$(cat state/c1.out state/c2.out | grep -cE "^($H1|$H2)\$")"
fi

echo "-- the merge job"
cd "$R/ws/$H1" || exit 1
echo x > outside_probe.txt; git add -A; git commit -q -m "edit outside the allowed paths"
check "a change outside the allowed paths is rejected" 'REJECTED: these paths' $T mr "outside probe"
if [ -d "$R/task/probe/bad" ] && [ -d "$R/task/probe/good" ]; then
  git reset -q --hard origin/main; cp -r "$R/task/probe/bad/." .; git add -A; git commit -q -m "bad probe"
  check "the task's wrong answer is rejected"        'REJECTED by the check'      $T mr "bad probe"
  git reset -q --hard origin/main; cp -r "$R/task/probe/good/." .; git add -A; git commit -q -m "good probe"
  check "the task's right answer is accepted"        'ACCEPTED: merged into main' $T mr "good probe"
else
  echo "SKIP  no task/probe/good and task/probe/bad: nothing shows that the check can tell right from wrong"
fi
check "a direct push is refused"                    'direct pushes are refused'  git push origin HEAD:refs/heads/sneak
cd "$R"
check "requests are logged under the sender's name" "\"agent\": \"$H1\", \"op\": \"mr\"" cat records/gateway.jsonl

# reset everything the test touched
kill $GW 2>/dev/null; wait $GW 2>/dev/null
rm -f state/board.db state/board.db-wal state/board.db-shm state/c1.out state/c2.out
git -C central.git update-ref refs/heads/main "$(cat state/seed_sha)"; git -C central.git branch -q -D "agent/$H1" 2>/dev/null
( cd "$R/ws/$H1" && git fetch -q origin && git reset -q --hard origin/main && git clean -qfd )
rm -f records/*.jsonl state/gw-test.log state/deadline; echo '[]' > state/landed.json
echo "$ok passed, $bad failed"; [ $bad -eq 0 ]
