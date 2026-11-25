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

# ---- A2: the sandbox hides every entry of ~/.claude but shell-snapshots, and every dot-entry in ~ but a few
if want A2; then
mk_workdir lead h1; setup_wd
H=$TOP     # a fake home directory that holds the work directory ($TOP/wd)
mkdir -p "$H/.claude/shell-snapshots" "$H/.claude/projects" "$H/.aws" "$H/.somethingnew" "$H/.local/bin" "$H/.cache"
echo secret > "$H/.claude/history.jsonl"; echo ': ok' > "$H/.claude/shell-snapshots/x.sh"; touch "$H/.bashrc" "$H/.profile" "$H/.claude.json"
deny_of() { python3 -c "import json,sys; print('\n'.join(json.load(open(sys.argv[1]))['sandbox']['filesystem']['denyRead']))" "$W/harness/settings/h1.json"; }
( cd "$W" && env -u CLAUDE_CONFIG_DIR HOME="$H" python3 harness/mk_settings.py ) >/dev/null
d=$(deny_of)
for p in .claude/history.jsonl .claude/projects .aws .somethingnew .claude.json stub; do
  grep -qxF "$H/$p" <<<"$d" && ok "A2 hidden: ~/$p" || no "A2 hidden: ~/$p" "$d"
done
for p in .claude/shell-snapshots .claude .bashrc .profile .local .cache wd; do
  grep -qxF "$H/$p" <<<"$d" && no "A2 left readable: ~/$p" "$d" || ok "A2 left readable: ~/$p"
done
refute "A2 the home directory itself is not hidden" "^$H\$" echo "$d"
# CLAUDE_CONFIG_DIR: that folder is treated like ~/.claude, and ~/.claude is then hidden whole
mkdir -p "$H/.claude-alt/shell-snapshots"; echo secret > "$H/.claude-alt/history.jsonl"
( cd "$W" && HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude-alt" python3 harness/mk_settings.py ) >/dev/null
d=$(deny_of)
grep -qxF "$H/.claude-alt/history.jsonl" <<<"$d" && ok "A2 CLAUDE_CONFIG_DIR: its history is hidden" || no "A2 CLAUDE_CONFIG_DIR: its history is hidden" "$d"
grep -qxF "$H/.claude-alt/shell-snapshots" <<<"$d" && no "A2 CLAUDE_CONFIG_DIR: its shell-snapshots stay readable" "$d" || ok "A2 CLAUDE_CONFIG_DIR: its shell-snapshots stay readable"
grep -qxF "$H/.claude" <<<"$d" && ok "A2 CLAUDE_CONFIG_DIR: ~/.claude is hidden whole" || no "A2 CLAUDE_CONFIG_DIR: ~/.claude is hidden whole" "$d"
# a work directory outside the home directory: everything in it but the shell's dot-files is hidden
mkdir -p "$TOP/home2/codes" "$TOP/home2/.claude/shell-snapshots"; touch "$TOP/home2/.bashrc" "$TOP/home2/notes.txt"
( cd "$W" && env -u CLAUDE_CONFIG_DIR HOME="$TOP/home2" python3 harness/mk_settings.py ) >/dev/null
d=$(deny_of)
grep -qxF "$TOP/home2/codes" <<<"$d" && grep -qxF "$TOP/home2/notes.txt" <<<"$d" && ok "A2 a work directory outside ~ still hides the home directory's folders" || no "A2 a work directory outside ~ still hides the home directory's folders" "$d"
check "A2 references/claude-code.md lists what stays readable" 'shell-snapshots' cat "$REPO/references/claude-code.md"
check "A2 launch.sh writes the settings again, so entries made after setup.sh are hidden too" 'mk_settings.py' cat "$W/launch.sh"
fi

finish
