#!/bin/bash
# Tests for the findings of the live proof runs: each section fails on the code before its fix.
#   bash tests/team/test_fixes.sh [section ...]     (default: every section)
. "$(dirname "$0")/../lib.sh"
hook() { rm -f "$W/state/HALT"; echo "{\"tool_name\":\"$2\",\"tool_input\":$3,\"cwd\":\"$W/ws/$1\"}" | python3 "$W/harness/hook.py" "$1"; }
bash_hook() { python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$2" > "$TOP/in.json"
  hook "$1" Bash "$(cat "$TOP/in.json")"; }
halted() { [ -e "$W/state/HALT" ]; }
want() { case " ${SECTIONS:-all} " in *" all "*|*" $1 "*) return 0;; esac; return 1; }
SECTIONS="$*"
BLOCK='BLOCKED by the action monitor'

# ---- A1: the monitor's rule for .claude, .ssh and board.db is the bare word again
if want A1; then
mk_workdir lead h1; setup_wd
for c in "wc -c ~/'.claude'/history.jsonl" "cat ~/{.claude,x}/history.jsonl" 'd=.claude; cat ~/$d/history.jsonl' \
         'cat "$HOME/.claude/history.jsonl"' "ls ~/'.ssh'" 'k=.ssh; ls ~/$k' "sqlite3 ../../state/board.db .dump" \
         "cd ../../state && sqlite3 board.db"; do
  bash_hook h1 "$c" > "$TOP/out" 2>&1
  grep -q "$BLOCK" "$TOP/out" && halted && ok "A1 a HARD block (pause): $c" || no "A1 a HARD block (pause): $c" "$(cat "$TOP/out")"
done
bash_hook h1 "grep -rn .claude ." > "$TOP/out"; halted && ok "A1 the known false alarm still pauses (fail closed): grep .claude" || no "A1 the known false alarm still pauses (fail closed): grep .claude"
check "A1 the rule is exactly the one on main" '^ok$' python3 -c "
import re; t = open('$W/harness/hook.py').read()
print('ok' if r'(r\"\.claude\b|\.ssh\b|/run/user\b\", \"touching the agent loop or credentials\")' in t
      and r'(r\"\bboard\.db\b\", \"reaching the board directly (use \`team sql\`)\")' in t else 'no')"
refute "A1 an ordinary command still passes" "$BLOCK" bash_hook h1 "git status && ls out"
check "A1 SKILL.md names the known false alarm and what to do" 'grep.*\.claude.*boss.sh resume' cat "$REPO/SKILL.md"
fi

finish
