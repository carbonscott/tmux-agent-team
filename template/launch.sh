#!/bin/bash
# Start the team in one tmux session: gateway, board, one window per agent, reminders.
#   ./launch.sh            start a new run
#   ./launch.sh --resume   continue an interrupted run: the same board, main and removals; the
#                          deadline moves later by the time the run was down (harness/runstate.py)
set -eu
R=$(cd "$(dirname "$0")" && pwd); cfg() { python3 "$R/harness/cfg.py" "$1"; }
S=$(cfg session); MODE=${1:-}
case "$MODE" in ""|--resume) ;; *) echo "usage: ./launch.sh [--resume]"; exit 2;; esac
tmux has-session -t "=$S" 2>/dev/null && { echo "tmux session $S already exists"; exit 1; }
[ -d "$R/ws" ] || { echo "run ./setup.sh first"; exit 1; }
STATE=$(python3 "$R/harness/runstate.py")
if [ -z "$MODE" ]; then
  case "$STATE" in
    INTERRUPTED*) echo "This run was interrupted: it started, is not complete, and its tmux session is gone."
                  echo "  ./launch.sh --resume       continue it: same board, same main, the time it was down given back"
                  echo "  ./teardown.sh --archive    put it away as one sealed file"
                  echo "Nothing was started."; exit 1;;
    complete*|ended*) echo "This work directory holds a run that is $STATE"
                  echo "Put it away with ./teardown.sh --archive before starting another. Nothing was started."; exit 1;;
  esac
  rm -f "$R"/state/DONE "$R"/state/HALT "$R"/state/stops.* "$R"/state/removed/* 2>/dev/null || true
  [ -e "$R/state/landed.json" ] || echo '[]' > "$R/state/landed.json"
else
  python3 "$R/harness/runstate.py" --resume
  rm -f "$R"/state/stops.* 2>/dev/null || true
fi
tmux new-session -d -s "$S" -n gateway -c "$R" "python3 -u $R/harness/gateway.py; exec bash"
tmux set-option -t "$S" remain-on-exit on
tmux new-window -d -t "$S" -n board -c "$R" "bash $R/harness/board.sh; exec bash"
if [ -z "$MODE" ]; then
  sleep 1
  python3 -c "import time;open('$R/state/deadline','w').write(str(time.time()+$(cfg budget_min)*60))"
  date +%s > "$R/state/started"
fi
for a in $(cfg agents); do
  # a helper the boss removed stays removed: it gets no window and the gateway still refuses it
  [ -n "$MODE" ] && [ -e "$R/state/removed/$a" ] && continue
  tmux new-window -d -t "$S" -n $a -c "$R/ws/$a" "TEAM_REMOTE_CONTROL=${TEAM_REMOTE_CONTROL:-} bash $R/harness/run-agent.sh $a $MODE"
done
tmux new-window -d -t "$S" -n reminders -c "$R" "bash $R/harness/remind.sh; exec bash"
tmux list-windows -t "$S" -F '#{window_index} #{window_name}'
echo "If an agent window asks whether to trust its workspace folder, answer it (harness/boss.sh trust)."
