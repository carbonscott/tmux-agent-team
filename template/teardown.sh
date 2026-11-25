#!/bin/bash
# Stop everything this run started.
#   ./teardown.sh                  stop the tmux session, the gateway and the agent sessions; keep the files
#   ./teardown.sh --archive [DIR]  stop, seal the repository and the records into one dated file in DIR
#                                  (default: the folder that holds this work directory), then delete the
#                                  run's files. Nothing is deleted unless the file was written and read back.
#   ./teardown.sh --purge          stop, then delete the run's files for good, keeping nothing
R=$(cd "$(dirname "$0")" && pwd)
mode=${1:-}
case "$mode" in
  ""|--purge) ;;
  --archive) DEST=${2:-$(dirname "$R")}
             python3 "$R/harness/archive.py" --check "$DEST" || exit 1;;
  *)         sed -n 2,7p "$0"; exit 2;;
esac
tmux kill-session -t "=$(python3 "$R/harness/cfg.py" session)" 2>/dev/null && echo "tmux session stopped"
pkill -f "$R/harness/gateway.py" 2>/dev/null && echo "gateway stopped"
# agent sessions take a few seconds to exit after their windows close
left() { for p in /proc/[0-9]*; do c=$(readlink "$p/cwd" 2>/dev/null) || continue; case "$c" in "$R"/ws/*) echo "${p#/proc/}";; esac; done; }
for i in $(seq 15); do [ -z "$(left)" ] && break; sleep 1; done
[ -z "$(left)" ] && echo "nothing from this run is still running" || echo "still running (process ids): $(left | tr '\n' ' ')"
purge() { rm -rf "$R"/ws "$R"/central.git "$R"/records "$R"/state "$R"/tools "$R"/harness/settings; echo "runtime files deleted"; }
case "$mode" in
  --purge)   purge;;
  --archive) f=$(python3 "$R/harness/archive.py" "$DEST") && [ -s "$f" ] ||
               { echo "the archive was not written: the run is stopped and its files are kept"; exit 1; }
             purge
             echo "archived: $f";;
esac
