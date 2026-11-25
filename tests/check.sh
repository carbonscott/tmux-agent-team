#!/bin/bash
# The check for one piece of work on the template.  usage: tests/check.sh <name>
# Passes only if all of these hold:
#   1. tests/regress.sh: everything the template did before still works
#   2. tests/accept/<name>.sh, when there is one: the agreed behaviour of this piece
#   3. tests/team/test_<name>.sh: the tests written with the piece
# The regression result is remembered per content of template/ and tests/ in .check-cache/.
set -u
cd "$(dirname "$0")/.." || exit 1
name=${1:?usage: tests/check.sh <name>}
case "$name" in *[!a-z0-9_]*) echo "bad name"; exit 1;; esac
run() { local label=$1 limit=$2 script=$3 log=.check-cache/$1.log
  if timeout "$limit" bash "$script" > "$log" 2>&1; then echo "check: $label passed ($(tail -1 "$log"))"; return 0; fi
  echo "check: $label FAILED (bash $script)"; grep -A6 '^FAIL' "$log" | head -40; echo "  ... last lines:"; tail -8 "$log"; return 1; }
mkdir -p .check-cache
key=$(find template tests -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 sha1sum | sha1sum | cut -c1-16)
if [ ! -e ".check-cache/regress.$key" ]; then
  run regress 170 tests/regress.sh || exit 1
  rm -f .check-cache/regress.*; touch ".check-cache/regress.$key"
fi
[ -f "tests/team/test_$name.sh" ] || { echo "check: tests/team/test_$name.sh is missing"; exit 1; }
if [ -f "tests/accept/$name.sh" ]; then run "accept-$name" 110 "tests/accept/$name.sh" || exit 1; fi
if [ "$name" = wildcard ]; then
  [ -s references/decisions/team-choice.md ] || { echo "check: references/decisions/team-choice.md is missing"; exit 1; }
fi
run "team-$name" 110 "tests/team/test_$name.sh" || exit 1
echo "check: $name ok"
