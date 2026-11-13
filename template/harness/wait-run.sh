#!/bin/bash
# Blocks until the run completes, pauses, or runs out of time, or MAX seconds pass (default 540).
# First line of output: DONE, HALT, TIME UP, or STILL RUNNING. Exit status is always 0.
R=$(cd "$(dirname "$0")/.." && pwd); MAX=${1:-540}; t0=$(date +%s)
while true; do
  [ -e "$R/state/DONE" ] && { echo "DONE"; break; }
  [ -e "$R/state/HALT" ] && { echo "HALT"; cat "$R/state/HALT"; break; }
  python3 -c "import time,sys;sys.exit(0 if time.time()>float(open('$R/state/deadline').read()) else 1)" && { echo "TIME UP"; break; }
  [ $(( $(date +%s) - t0 )) -ge $MAX ] && { echo "STILL RUNNING"; break; }
  sleep 5
done
echo "done on main: $(cat "$R/state/landed.json")"
