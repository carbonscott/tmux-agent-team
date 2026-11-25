#!/bin/bash
# A time-left reminder typed into the lead's window every 5 minutes (TEAM_REMIND_S seconds).
# Quiet while the team is paused or the run is stalled (boss.sh unstall may reopen it); it stops
# only when the run is complete or out of time.
R=$(cd "$(dirname "$0")/.." && pwd); S=$("$R/harness/py" "$R/harness/cfg.py" session)
while sleep "${TEAM_REMIND_S:-300}"; do
  [ -e "$R/state/DONE" ] && { echo "run complete; reminders stop"; break; }
  [ -e "$R/state/STALLED" ] && { echo "run stalled; no reminder (boss.sh unstall would reopen it)"; continue; }
  [ -e "$R/state/HALT" ] && { echo "team paused; no reminder"; continue; }
  left=$("$R/harness/py" -c "import time;print(int((float(open('$R/state/deadline').read())-time.time())//60))")
  [ "$left" -le 0 ] && { echo "time is up"; break; }
  msg="[harness] Time left: $left min. Done: $("$R/harness/py" -c "import json;print(' '.join(json.load(open('$R/state/landed.json'))) or 'nothing yet')"). Keep going."
  tmux send-keys -t "=$S:lead" -l "$msg"; sleep 0.5; tmux send-keys -t "=$S:lead" Enter
  echo "$(date +%T) sent: $msg"
done
