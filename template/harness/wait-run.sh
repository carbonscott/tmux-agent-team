#!/bin/bash
# Blocks until the run completes, stalls, pauses, or runs out of time, or MAX seconds pass (default 540).
# First line of output: DONE, STALLED, HALT, TIME UP, or STILL RUNNING, then the team's session
# name in brackets (e.g. "DONE [my-team]"). Exit status is always 0.
R=$(cd "$(dirname "$0")/.." && pwd); MAX=${1:-540}; t0=$(date +%s)
S=$("$R/harness/py" "$R/harness/cfg.py" session)
while true; do
  [ -e "$R/state/DONE" ] && { echo "DONE [$S]"; break; }
  [ -e "$R/state/STALLED" ] && { echo "STALLED [$S]"; cat "$R/state/STALLED"; echo; break; }
  [ -e "$R/state/HALT" ] && { echo "HALT [$S]"; cat "$R/state/HALT"; break; }
  "$R/harness/py" -c "import time,sys;sys.exit(0 if time.time()>float(open('$R/state/deadline').read()) else 1)" && { echo "TIME UP [$S]"; break; }
  [ $(( $(date +%s) - t0 )) -ge $MAX ] && { echo "STILL RUNNING [$S]"; break; }
  sleep 5
done
echo "done on main: $(cat "$R/state/landed.json")"
