#!/bin/bash
# A time-left reminder typed into the lead's window every 5 minutes.
R=$(cd "$(dirname "$0")/.." && pwd); S=$(python3 "$R/harness/cfg.py" session)
while sleep 300; do
  [ -e "$R/state/DONE" ] && { echo "run complete; reminders stop"; break; }
  [ -e "$R/state/HALT" ] && { echo "team paused; no reminder"; continue; }
  left=$(python3 -c "import time;print(int((float(open('$R/state/deadline').read())-time.time())//60))")
  [ "$left" -le 0 ] && { echo "time is up"; break; }
  msg="[harness] Time left: $left min. Done: $(python3 -c "import json;print(' '.join(json.load(open('$R/state/landed.json'))) or 'nothing yet')"). Keep going."
  tmux send-keys -t "=$S:lead" -l "$msg"; sleep 0.5; tmux send-keys -t "=$S:lead" Enter
  echo "$(date +%T) sent: $msg"
done
