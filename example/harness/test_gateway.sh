#!/bin/bash
# Pre-launch test of the gateway and the merge job: try what they must refuse, then reset.
# Run after setup.sh and before the first launch.
set -u
R=$(cd "$(dirname "$0")/.." && pwd); cd "$R"; cfg() { python3 "$R/harness/cfg.py" "$1"; }
[ -e state/started ] && { echo "a run has already started here; this test would reset its work"; exit 1; }
[ -d ws/h1/.git ] && [ -d central.git ] || { echo "run ./setup.sh first"; exit 1; }
T=$R/bin/team; export GIT_CONFIG_GLOBAL=/dev/null
echo '[]' > state/landed.json; python3 -c "import time;open('state/deadline','w').write(str(time.time()+3600))"
"$R/harness/.venv/bin/python" -u "$R/harness/gateway.py" > state/gw-test.log 2>&1 & GW=$!
trap 'kill $GW 2>/dev/null' EXIT    # never leave a test gateway behind
sleep 1.5; kill -0 $GW 2>/dev/null || { cat state/gw-test.log; exit 1; }
ok=0; bad=0
as() { ( cd "$R/ws/$1" && shift && "$@" ); }
check() { local label=$1 pat=$2; shift 2; local out; out=$("$@" 2>&1)
  if echo "$out" | grep -qE "$pat"; then echo "PASS  $label"; ok=$((ok+1))
  else echo "FAIL  $label"; echo "$out" | tail -3 | sed 's/^/        /'; bad=$((bad+1)); fi; }

check "lead is seen as lead"                 '^lead$'            as lead $T whoami
check "lead can create a table"              '\| lead \|'        as lead $T sql "CREATE TABLE t_probe(id serial primary key, who text default current_user, msg text); INSERT INTO t_probe(msg) VALUES ('hello') RETURNING *"
check "helper rows are stamped as the helper" '\| h1 \|'         as h1 $T sql "INSERT INTO t_probe(msg) VALUES ('from h1') RETURNING *"
check "helper cannot become the lead"        'permission denied' as h1 $T sql "SET ROLE lead"
check "helper cannot delete rows"            'permission denied' as h1 $T sql "DELETE FROM t_probe"
check "helper cannot create tables"          'permission denied' as h1 $T sql "CREATE TABLE x(i int)"
check "helper cannot drop the lead's table"  'must be owner'     as h1 $T sql "DROP TABLE t_probe"
check "statements are cut off at the limit"  'canceling statement' as h1 $T sql "SET statement_timeout=0; SELECT pg_sleep(20)"
check "open transactions are rolled back"    'rolled back'       as h1 $T sql "BEGIN; UPDATE t_probe SET msg='x' WHERE id=1"
as lead $T sql "CREATE TABLE t_claim(id int primary key, owner text); INSERT INTO t_claim VALUES (1, NULL)" >/dev/null
CLAIM="UPDATE t_claim SET owner = current_user WHERE id = 1 AND owner IS NULL RETURNING owner"
as h1 $T sql "$CLAIM" > state/c1.out 2>&1 & P1=$!
as h2 $T sql "$CLAIM" > state/c2.out 2>&1 & P2=$!
wait $P1 $P2    # not a bare wait: the gateway is also a child of this script
check "two simultaneous claims produce one winner" '^1$'        echo "$(cat state/c1.out state/c2.out | grep -cE '^h[12]$')"

cd "$R/ws/h1" || exit 1
printf 'def to_roman(n):\n    return "I"\ndef from_roman(s):\n    return 1\n' > kit/roman.py; git add -A; git commit -q -m "wrong roman"
check "a wrong answer is rejected by the tests" '[0-9]+ failed'           $T mr "wrong roman"
git reset -q --hard origin/main; echo "# x" >> tests/test_roman.py; git commit -q -am "edit frozen test"
check "an edit to a frozen test is rejected" 'REJECTED: these paths'     $T mr "edit frozen test"
git reset -q --hard origin/main; printf 'def two():\n    return 2\n' > kit/_probe.py
printf 'from kit._probe import two\ndef test_two():\n    assert two() == 2\n' > tests/lemmas/test_probe.py; git add -A; git commit -q -m "probe lemma"
check "a valid change is accepted"           'ACCEPTED: merged into main' $T mr "probe lemma"
check "a direct push is refused"             'direct pushes are refused'  git push origin HEAD:refs/heads/sneak
cd "$R"
check "requests are logged with identity"    '"agent": "h1", "op": "mr"'  cat records/gateway.jsonl

# reset everything the test touched
kill $GW 2>/dev/null
docker exec "$(cfg db.container)" psql -U postgres -d "$(cfg db.name)" -qc "DROP TABLE IF EXISTS t_probe, t_claim" >/dev/null
git -C central.git update-ref refs/heads/main "$(cat state/seed_sha)"; git -C central.git branch -q -D agent/h1 2>/dev/null
( cd "$R/ws/h1" && git fetch -q origin && git reset -q --hard origin/main && git clean -qfd )
rm -f records/*.jsonl state/gw-test.log state/deadline state/c1.out state/c2.out; echo '[]' > state/landed.json
echo "$ok passed, $bad failed"; [ $bad -eq 0 ]
