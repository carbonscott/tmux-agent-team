#!/bin/bash
# Runs one agent's Claude Code session inside its tmux window. usage: run-agent.sh <id>
R=$(cd "$(dirname "$0")/.." && pwd); A=$1
cd "$R/ws/$A" || exit 1
export PATH=$R/bin:$R/tools/bin:$PATH CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=100000
PROMPT="$(python3 "$R/harness/render.py" "$A")"
RC=(); [ -n "${TEAM_REMOTE_CONTROL:-}" ] && RC=(--remote-control "team-$A")
# Only a shell and file tools: no web, no subagents, no messaging, no MCP servers.
# "--" keeps the brief from being read as another tool name.
claude --name "team-$A" "${RC[@]}" \
  --settings "$R/harness/settings/$A.json" \
  --permission-mode auto --effort medium \
  --tools Bash,Edit,Read,Write,Glob,Grep --strict-mcp-config --disable-slash-commands \
  -- "$PROMPT"
echo "[claude exited; shell kept open so the window persists]"; exec bash
