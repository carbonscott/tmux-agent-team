#!/bin/bash
# Acceptance: no part of the skill names the `bridge` CLI  (see STATEMENTS.md, statement `nobridge`)
# The harness has no rule, knob or code path for it: it runs wherever the sandbox is off.
. "$(dirname "$0")/../lib.sh"
cd "$REPO" || exit 1

# 1. Nothing names it, but the one record of the owner's trial in references/claude-code.md
#    and the decision records under references/decisions/.
hits=$(grep -rniw 'bridge' SKILL.md README.md references template tests \
  --exclude-dir=decisions --exclude-dir=.check-cache --exclude-dir=__pycache__ \
  | grep -v '^references/claude-code\.md:' \
  | grep -v '^tests/accept/nobridge\.sh:' | grep -v '^tests/team/test_nobridge\.sh:')
[ -z "$hits" ] && ok "no file names the bridge CLI" || no "no file names the bridge CLI" "$hits"
check "claude-code.md keeps the owner's trial (bridge worked unwalled, failed on the Unix socket walled)" \
  -i 'bridge.{0,120}sandbox off|bridge.{0,200}unix socket' sh -c "tr '\n' ' ' < references/claude-code.md"

# 2. What the docs say instead is still there.
S=SKILL.md
check "SKILL.md: shell_net still lists the network commands" '`shell_net`.*`ssh`.*`wget`' cat "$S"
check "SKILL.md: the remote preset is still for work on another machine" '^\| `remote` \|.*another machine' cat "$S"
check "SKILL.md: unwalled runs are still for work that must reach other machines" -i 'sandbox": false`? only when the user asks for it' sh -c "tr '\n' ' ' < '$S' | tr -s ' '"

# 3. The remote agent's brief keeps its Remote machines section and its commands.
mk_workdir lead h1 h2; setcfg sandbox false; setcfg agent_profiles '{"h1": "remote"}'; setup_wd
b=$(cd "$W" && python3 harness/render.py h1)
check "the remote brief still has its Remote machines section" '^## Remote machines' echo "$b"
check "and names the commands it may run" '`ssh`.*`scp`.*`sftp`.*`rsync`.*`curl`.*`wget`' echo "$b"
refute "and no longer names the bridge" -i 'bridge' echo "$b"

# 4. Nothing changed for the monitor: a bridge command is passed in every profile of an unwalled run.
hook() { rm -f "$W/state/HALT"; echo "{\"tool_name\":\"$2\",\"tool_input\":$3,\"cwd\":\"$W/ws/$1\"}" | python3 "$W/harness/hook.py" "$1"; }
bash_() { hook "$1" Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$2")"; }
for a in h1 h2; do check "the monitor still passes \`bridge\` for $a" '^$' bash_ $a "bridge --session s bash 'hostname'"; done

# 5. The tests that held bridge lines still pass.
out=$(bash tests/accept/remote.sh 2>&1); refute "tests/accept/remote.sh passes" '^FAIL' echo "$out"
out=$(bash tests/team/test_remote.sh 2>&1); refute "tests/team/test_remote.sh passes" '^FAIL' echo "$out"
finish
