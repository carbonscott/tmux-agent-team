#!/bin/bash
# The boss's controls.
#   boss.sh status              run state, and the blocked action if the team is paused
#   boss.sh trust               answer "yes" to the workspace trust prompt in every agent window (waits for it),
#                               then wait to see each session running, and say so
#   boss.sh say <id|all> "..."  type a message into an agent's window
#   boss.sh slash <id> "/..."   type a slash command, as it is, into the window of an agent on the open
#                               profile (the way to put it under /goal: boss.sh slash h3 "/goal ...")
#   boss.sh messages            every message the agents sent each other (team msg), oldest first
#   boss.sh resume              clear a reviewed pause and give the lost time back (to the deadline and the stall clock)
#   boss.sh unstall             reopen a stalled run: the stall clock starts again from now
#   boss.sh remove <id>         remove a helper: the gateway and the monitor refuse it from now on
#   boss.sh end                 end the run now
R=$(cd "$(dirname "$0")/.." && pwd); cfg() { python3 "$R/harness/cfg.py" "$1"; }; S=$(cfg session)
say() { tmux send-keys -t "=$S:$1" -l "[boss] $2"; sleep 0.5; tmux send-keys -t "=$S:$1" Enter; }
case "${1:-status}" in
  status) python3 "$R/harness/board.py" --brief
          echo "profiles: $(python3 "$R/harness/profiles.py" --list)"
          st=$(python3 "$R/harness/runstate.py"); case "$st" in INTERRUPTED*|ended*) echo "== $st";; esac
          [ -e "$R/state/HALT" ] && { echo "blocked action:"; python3 -m json.tool "$R/state/HALT"; }; true;;
  trust)  # waits up to 30 s: for each prompt to appear (so it can be run right after launch), and,
          # once answered, for the session to be seen running (its name team-<id> on screen)
          todo=" $(cfg agents) "; for a in $todo; do [ -e "$R/state/removed/$a" ] && todo=${todo/ $a / }; done
          sent=" "    # answered, not yet seen running
          for i in $(seq 30); do
            for a in $todo $sent; do
              pane=$(tmux capture-pane -p -t "=$S:$a" 2>/dev/null)
              case "$sent" in *" $a "*)
                if echo "$pane" | grep -q "claude exited"; then
                  echo "$a: answered, but the session did not start (it exited): look at the window"; sent=${sent/ $a / }
                elif echo "$pane" | grep -q "team-$a" && ! echo "$pane" | grep -q "trust this folder"; then
                  echo "$a: answered yes, started"; sent=${sent/ $a / }
                fi; continue;; esac
              if echo "$pane" | grep -q "trust this folder"; then
                # the cursor may start on either answer: move it only when it is not on Yes
                echo "$pane" | grep -qE '❯ *([0-9]+\. *)?Yes' || { tmux send-keys -t "=$S:$a" Down; sleep 0.4; }
                tmux send-keys -t "=$S:$a" Enter; todo=${todo/ $a / }; sent="$sent$a "
              elif echo "$pane" | grep -q "team-$a"; then
                echo "$a: started without a prompt"; todo=${todo/ $a / }
              fi
            done
            [ -z "${todo// /}" ] && [ -z "${sent// /}" ] && break; sleep 1
          done
          for a in $sent; do echo "$a: answered, but the session was not seen running: look at the window"; done
          [ -n "${todo// /}" ] && echo "still starting, run again:$todo";;
  messages) python3 "$R/harness/board.py" --messages;;
  slash)  # no "[boss]" prefix, so the session reads it as a command: only for the open profile,
          # where slash commands are on, and only one printable line that starts with /
          case " $(cfg agents) " in *" ${2:-?} "*) ;; *) echo "refused: no agent ${2:-} (one agent, by name)"; exit 1;; esac
          p=$(python3 "$R/harness/profiles.py" "$2" | cut -d' ' -f1)
          [ "$p" = open ] || { echo "refused: $2 has the $p profile; slash commands are on only in the open profile (config.json agent_profiles)"; exit 1; }
          [ -e "$R/state/removed/$2" ] && { echo "refused: $2 has been removed"; exit 1; }
          python3 -c 'import sys; s = sys.argv[1]; sys.exit(0 if s.startswith("/") and s.isprintable() else 1)' "${3:-}" ||
            { echo "refused: give one line of printable text that starts with /, such as \"/goal ...\""; exit 1; }
          tmux send-keys -t "=$S:$2" -l "$3"; sleep 0.5; tmux send-keys -t "=$S:$2" Enter; echo "typed into $2: $3";;
  say)    if [ "$2" = all ]; then for a in $(cfg agents); do say "$a" "$3"; done; else say "$2" "$3"; fi;;
  resume) python3 -c "
import json,time
h=json.load(open('$R/state/HALT')); lost=time.time()-h['ts']
for f, need in (('deadline', True), ('stall_from', False)):
    try:
        v=float(open('$R/state/'+f).read())
    except OSError:
        if need: raise
        continue
    open('$R/state/'+f,'w').write(str(v+lost))" &&
          mv "$R/state/HALT" "$R/records/halt.$(date +%s).json" &&
          echo "pause cleared. Agents that stopped will not restart by themselves: boss.sh say all \"...\"";;
  unstall) [ -e "$R/state/STALLED" ] || { echo "the run has not stalled"; exit 1; }
          date +%s > "$R/state/stall_from" && mv "$R/state/STALLED" "$R/records/stalled.$(date +%s).json" &&
          echo "stall cleared; the stall clock starts again. Agents that stopped will not restart by themselves: boss.sh say all \"...\"";;
  remove) touch "$R/state/removed/$2" && echo "$2 removed. Ask the lead to reopen its tasks.";;
  end)    python3 -c "import time;open('$R/state/deadline','w').write(str(time.time()))"; echo "run ended";;
  *)      sed -n 2,13p "$0";;
esac
