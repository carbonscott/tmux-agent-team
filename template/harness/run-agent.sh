#!/bin/bash
# Runs one agent's Claude Code session inside its tmux window. usage: run-agent.sh <id> [--resume]
# With --resume the agent starts, as a fresh session, from the brief for rejoining a run.
R=$(cd "$(dirname "$0")/.." && pwd); A=$1
cd "$R/ws/$A" || exit 1
export PATH=$R/bin:$R/tools/bin:$PATH CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=100000
PROMPT="$(python3 "$R/harness/render.py" "$A" ${2:+"$2"})"
RC=(); [ -n "${TEAM_REMOTE_CONTROL:-}" ] && RC=(--remote-control "team-$A")
# config.json: "model" (empty means Claude Code's default) and "effort" (default medium)
MODEL=$(python3 -c "import json;print(json.load(open('$R/config.json')).get('model') or '')")
EFFORT=$(python3 -c "import json;print(json.load(open('$R/config.json')).get('effort') or 'medium')")
[ -n "$MODEL" ] && RC+=(--model "$MODEL")
# The agent's profile (harness/profiles.py) decides its tools. The default, sealed, is a shell and
# file tools only: no web, no subagents, no slash commands or skills. No profile has MCP servers
# (--strict-mcp-config); sessions may still be offered EndConversation and tools that plugins
# register, which the monitor (hook.py) refuses.
read -r PROFILE TOOLS SLASH <<<"$(python3 "$R/harness/profiles.py" "$A")"
[ -n "$TOOLS" ] || { echo "no profile for $A: check config.json (harness/profiles.py --check)"; exec bash; }
[ "$SLASH" = slash-on ] || RC+=(--disable-slash-commands)
# "--" keeps the brief from being read as another tool name.
claude --name "team-$A" "${RC[@]}" \
  --settings "$R/harness/settings/$A.json" \
  --permission-mode auto --effort "$EFFORT" \
  --tools "$TOOLS" --strict-mcp-config \
  -- "$PROMPT"
echo "[claude exited; shell kept open so the window persists]"; exec bash
