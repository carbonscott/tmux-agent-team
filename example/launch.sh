#!/bin/bash
# Start the team in one tmux session: gateway, board, one window per agent, reminders.
set -eu
R=$(cd "$(dirname "$0")" && pwd); cfg() { python3 "$R/harness/cfg.py" "$1"; }
S=$(cfg session)
tmux has-session -t "$S" 2>/dev/null && { echo "tmux session $S already exists"; exit 1; }
[ -d "$R/ws" ] || { echo "run ./setup.sh first"; exit 1; }
rm -f "$R"/state/DONE "$R"/state/HALT "$R"/state/stops.* "$R"/state/removed/* 2>/dev/null || true
[ -e "$R/state/landed.json" ] || echo '[]' > "$R/state/landed.json"
tmux new-session -d -s "$S" -n gateway -c "$R" "$R/harness/.venv/bin/python -u $R/harness/gateway.py; exec bash"
tmux set-option -t "$S" remain-on-exit on
tmux new-window -d -t "$S" -n board -c "$R" "bash $R/harness/board.sh; exec bash"
sleep 1
python3 -c "import time;open('$R/state/deadline','w').write(str(time.time()+$(cfg budget_min)*60))"
date +%s > "$R/state/started"
for a in $(cfg agents); do
  tmux new-window -d -t "$S" -n $a -c "$R/ws/$a" "TEAM_REMOTE_CONTROL=${TEAM_REMOTE_CONTROL:-} bash $R/harness/run-agent.sh $a"
done
tmux new-window -d -t "$S" -n reminders -c "$R" "bash $R/harness/remind.sh; exec bash"
tmux list-windows -t "$S" -F '#{window_index} #{window_name}'
echo "Each agent window first asks whether to trust its workspace folder; answer it, then the run starts."
