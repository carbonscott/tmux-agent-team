#!/bin/bash
# Operator controls. usage: operator.sh status | resume | remove <id> | end | say <id> "<text>"
R=$(cd "$(dirname "$0")/.." && pwd); S=$(python3 "$R/harness/cfg.py" session)
case "${1:-status}" in
  status) ls "$R/state"; [ -e "$R/state/HALT" ] && cat "$R/state/HALT"; echo; cat "$R/state/landed.json";;
  resume) # clear a reviewed pause and give the lost time back
          python3 -c "
import json,time
h=json.load(open('$R/state/HALT')); d=float(open('$R/state/deadline').read())
open('$R/state/deadline','w').write(str(d+time.time()-h['ts']))"
          mv "$R/state/HALT" "$R/records/halt.$(date +%s).json" && echo "team resumed; tell each agent (operator.sh say)";;
  remove) touch "$R/state/removed/$2" && echo "$2 removed from the team";;
  end)    python3 -c "import time;open('$R/state/deadline','w').write(str(time.time()))"; echo "run ended";;
  say)    tmux send-keys -t "$S:$2" -l "[operator] $3"; sleep 0.5; tmux send-keys -t "$S:$2" Enter;;
esac
