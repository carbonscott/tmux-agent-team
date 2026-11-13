#!/bin/bash
# Stop everything this example started. With --purge, also delete what setup.sh and the run created.
R=$(cd "$(dirname "$0")" && pwd); cfg() { python3 "$R/harness/cfg.py" "$1"; }
tmux kill-session -t "$(cfg session)" 2>/dev/null && echo "tmux session stopped"
pkill -f "$R/harness/gateway.py" 2>/dev/null && echo "gateway stopped"
docker rm -f "$(cfg db.container)" >/dev/null 2>&1 && echo "database container removed"
if [ "${1:-}" = "--purge" ]; then
  rm -rf "$R"/ws "$R"/central.git "$R"/records "$R"/state "$R"/tools "$R"/harness/.venv "$R"/harness/secrets "$R"/harness/settings
  echo "runtime files deleted"
fi
