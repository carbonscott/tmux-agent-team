#!/bin/bash
# Live view for people: run state plus the team's board, refreshed every 10 seconds.
R=$(cd "$(dirname "$0")/.." && pwd)
while true; do clear; COLUMNS=$(tput cols 2>/dev/null || echo 200) python3 "$R/harness/board.py"; sleep 10; done
