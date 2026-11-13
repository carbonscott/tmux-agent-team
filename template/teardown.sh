#!/bin/bash
# Stop everything this run started. With --purge, also delete what setup.sh and the run created.
R=$(cd "$(dirname "$0")" && pwd)
tmux kill-session -t "=$(python3 "$R/harness/cfg.py" session)" 2>/dev/null && echo "tmux session stopped"
pkill -f "$R/harness/gateway.py" 2>/dev/null && echo "gateway stopped"
# agent sessions take a few seconds to exit after their windows close
left() { for p in /proc/[0-9]*; do c=$(readlink "$p/cwd" 2>/dev/null) || continue; case "$c" in "$R"/ws/*) echo "${p#/proc/}";; esac; done; }
for i in $(seq 15); do [ -z "$(left)" ] && break; sleep 1; done
[ -z "$(left)" ] && echo "nothing from this run is still running" || echo "still running (process ids): $(left | tr '\n' ' ')"
if [ "${1:-}" = "--purge" ]; then
  rm -rf "$R"/ws "$R"/central.git "$R"/records "$R"/state "$R"/tools "$R"/harness/settings
  echo "runtime files deleted"
fi
