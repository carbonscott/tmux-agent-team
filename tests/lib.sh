#!/bin/bash
# Shared helpers for the tests of the template. Source it:  . "$(dirname "$0")/../lib.sh"
#
# A test builds a throwaway work directory from template/ with a three-statement toy task
# (statement <s> is done when out/<s>.txt holds the single line "ok"), then drives the real
# scripts and the real gateway. tmux and claude are stubs (tests/stubs/), so nothing here
# starts an agent session and no test needs the network. The merge job's sandbox is the real
# one wherever it can be started.
#
#   mk_workdir [agent ...]   copy template/ to $W and write its config (default: lead h1 h2)
#   setcfg <dotted.key> <json>   change one value of $W/config.json (before setup_wd)
#   setup_wd                 run $W/setup.sh
#   launch [args]            run $W/launch.sh; the stub tmux starts nothing
#   start_gateway / stop_gateway   the real gateway, as a child of the test
#   as <agent> <cmd ...>     run a command in that agent's workspace, with `team` on PATH
#   land <agent> <s> [title] [content]   commit out/<s>.txt and ask the merge job to land it
#   check <label> [-i] <regex> <cmd ...>   PASS if the command's output matches (-i: any case)
#   refute <label> [-i] <regex> <cmd ...>  PASS if it does not match
#   ok <label> / no <label> [detail]     record a result directly
#   wait_for <seconds> <cmd ...>         poll until the command succeeds
#   finish                   print the totals; the exit status is 0 only if nothing failed
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PYTHONDONTWRITEBYTECODE=1
PASS=0; FAIL=0; GWPID=; TOP=; W=; TOPS=()

ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
no() { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | tail -6 | sed 's/^/        /'; FAIL=$((FAIL+1)); }
check() { local label=$1 g=-qE pat out; shift; [ "$1" = -i ] && { g=-qiE; shift; }; pat=$1; shift; out=$("$@" 2>&1)
  if grep $g -- "$pat" <<<"$out"; then ok "$label"; else no "$label" "$out"; fi; }
refute() { local label=$1 g=-qE pat out; shift; [ "$1" = -i ] && { g=-qiE; shift; }; pat=$1; shift; out=$("$@" 2>&1)
  if grep $g -- "$pat" <<<"$out"; then no "$label" "$out"; else ok "$label"; fi; }
wait_for() { local n=$1 i; shift; for i in $(seq $((n*5))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; done; return 1; }

mk_workdir() {
  stop_gateway
  TOP=$(mktemp -d "${TMPDIR:-/tmp}/tat.XXXXXX"); TOPS+=("$TOP"); W=$TOP/wd
  export STUB_DIR=$TOP/stub; mkdir -p "$STUB_DIR"
  cp -r "$REPO/template" "$W"
  rm -rf "$W/task" "$W/ws" "$W/central.git" "$W/records" "$W/state" "$W/tools" "$W/harness/settings"
  find "$W" -name __pycache__ -prune -exec rm -rf {} +
  mkdir -p "$W/task/seed" "$W/task/probe/good/out" "$W/task/probe/bad/out"
  printf '# Statements\n\nStatement `<s>` (one of `a`, `b`, `c`) is done when the file `out/<s>.txt` holds the single line `ok`.\n' > "$W/task/seed/STATEMENTS.md"
  echo ok > "$W/task/probe/good/out/a.txt"; echo no > "$W/task/probe/bad/out/a.txt"
  python3 - "$W/config.json" "tat-$(basename "$TOP")" "${@:-lead h1 h2}" <<'PY'
import json, sys
path, session, agents = sys.argv[1], sys.argv[2], " ".join(sys.argv[3:]).split()
c = json.load(open(path))
c.update(session=session, agents=agents, budget_min=30)
c["task"] = {"statements": ["a", "b", "c"], "check": "grep -qx ok out/{name}.txt", "attempted_if": "out/{name}.txt",
             "allowed_paths": ["out/[a-z0-9_]+\\.txt"], "check_timeout_s": 60, "toolchain_paths": []}
json.dump(c, open(path, "w"), indent=2)
PY
  case ":$PATH:" in *":$REPO/tests/stubs:"*) ;; *) export PATH="$REPO/tests/stubs:$PATH"
    # Where a sandbox cannot be nested (inside an agent's own sandbox), the toy check runs
    # through a stand-in with no isolation. The merge job of a real run has the real one.
    bwrap --ro-bind / / true 2>/dev/null || { export PATH="$REPO/tests/stubs/nosandbox:$PATH"
      echo "NOTE  no nested sandbox here: the toy task's check runs without one"; };;
  esac
  trap cleanup EXIT
}

setcfg() { python3 - "$W/config.json" "$1" "$2" <<'PY'
import json, sys
path, key, value = sys.argv[1:]
c = json.load(open(path)); d = c; parts = key.split(".")
for p in parts[:-1]:
    d = d.setdefault(p, {})
d[parts[-1]] = json.loads(value)
json.dump(c, open(path, "w"), indent=2)
PY
}

setup_wd() { ( cd "$W" && ./setup.sh ) > "$TOP/setup.log" 2>&1 || { cat "$TOP/setup.log"; return 1; }; }
launch() { ( cd "$W" && ./launch.sh "$@" ); }
start_gateway() {
  ( cd "$W" && exec python3 -u "$W/harness/gateway.py" ) >> "$TOP/gw.log" 2>&1 & GWPID=$!
  sleep 1; kill -0 "$GWPID" 2>/dev/null || { echo "the gateway did not start:"; cat "$TOP/gw.log"; return 1; }
}
stop_gateway() { [ -n "$GWPID" ] && { kill "$GWPID" 2>/dev/null; wait "$GWPID" 2>/dev/null; }; GWPID=; return 0; }
as() { local a=$1; shift; ( cd "$W/ws/$a" && PATH="$W/bin:$PATH" "$@" ); }
land() {
  as "$1" sh -c 'git fetch -q origin main && git merge -q --no-edit origin/main >/dev/null 2>&1
    mkdir -p out && echo "$2" > "out/$1.txt" && git add -A out && git commit -q -m "$1" && team mr "$3"' \
    sh "$2" "${4:-ok}" "${3:-land $2}"
}
cleanup() {
  stop_gateway
  local t; for t in "${TOPS[@]}"; do pkill -f "$t/wd/harness/gateway.py" 2>/dev/null; rm -rf "$t"; done
}
finish() { echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }
