#!/bin/bash
# The boss's controls.
#   boss.sh status              run state, and the blocked action if the team is paused
#   boss.sh trust               answer "yes" to the workspace trust prompt in every agent window (waits for it)
#   boss.sh say <id|all> "..."  type a message into an agent's window
#   boss.sh resume              clear a reviewed pause and give the lost time back
#   boss.sh remove <id>         remove a helper: the gateway and the monitor refuse it from now on
#   boss.sh end                 end the run now
R=$(cd "$(dirname "$0")/.." && pwd); cfg() { python3 "$R/harness/cfg.py" "$1"; }; S=$(cfg session)
say() { tmux send-keys -t "=$S:$1" -l "[boss] $2"; sleep 0.5; tmux send-keys -t "=$S:$1" Enter; }
case "${1:-status}" in
  status) python3 "$R/harness/board.py" --brief
          [ -e "$R/state/HALT" ] && { echo "blocked action:"; python3 -m json.tool "$R/state/HALT"; };;
  trust)  # waits up to 20 s for the prompts to appear, so it can be run right after launch
          todo=" $(cfg agents) "
          for i in $(seq 20); do
            for a in $todo; do
              pane=$(tmux capture-pane -p -t "=$S:$a" 2>/dev/null)
              if echo "$pane" | grep -q "trust this folder"; then
                tmux send-keys -t "=$S:$a" Down; sleep 0.4; tmux send-keys -t "=$S:$a" Enter
                echo "$a: answered yes"; todo=${todo/ $a / }
              elif echo "$pane" | grep -q "team-$a"; then
                echo "$a: started without a prompt"; todo=${todo/ $a / }
              fi
            done
            [ -z "${todo// /}" ] && break; sleep 1
          done
          [ -n "${todo// /}" ] && echo "still starting, run again:$todo";;
  say)    if [ "$2" = all ]; then for a in $(cfg agents); do say "$a" "$3"; done; else say "$2" "$3"; fi;;
  resume) python3 -c "
import json,time
h=json.load(open('$R/state/HALT')); d=float(open('$R/state/deadline').read())
open('$R/state/deadline','w').write(str(d+time.time()-h['ts']))" &&
          mv "$R/state/HALT" "$R/records/halt.$(date +%s).json" &&
          echo "pause cleared. Agents that stopped will not restart by themselves: boss.sh say all \"...\"";;
  remove) touch "$R/state/removed/$2" && echo "$2 removed. Ask the lead to reopen its tasks.";;
  end)    python3 -c "import time;open('$R/state/deadline','w').write(str(time.time()))"; echo "run ended";;
  *)      sed -n 2,9p "$0";;
esac
