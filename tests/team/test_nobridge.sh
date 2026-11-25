#!/bin/bash
# Team tests for `nobridge`: what tests/accept/nobridge.sh does not cover. The docs describe
# unwalled runs and the remote preset without the bridge CLI, and the remote brief and monitor
# behave the same in the rejoin brief and for each network command.
. "$(dirname "$0")/../lib.sh"
cd "$REPO" || exit 1
hook() { rm -f "$W/state/HALT"; echo "{\"tool_name\":\"$2\",\"tool_input\":$3,\"cwd\":\"$W/ws/$1\"}" | python3 "$W/harness/hook.py" "$1"; }
bash_() { hook "$1" Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$2")"; }

# the docs: no stray mention, and the rows still read whole
refute "README.md does not name bridge" -iw 'bridge' cat README.md
refute "design.md does not name bridge" -iw 'bridge' cat references/design.md
check "SKILL.md: shell_net row ends its command list with profiles.NET_CMDS" '`wget` \(`profiles.NET_CMDS`\) \|' cat SKILL.md
check "SKILL.md: remote preset is for another machine, for example over SSH" '^\| `remote` \| all four \| An agent must work on another machine \(for example over SSH\)' cat SKILL.md
check "SKILL.md: unwalled runs reach other machines, for example over SSH" 'must reach other machines \(for example over SSH\)' sh -c "tr '\n' ' ' < SKILL.md"
check "design.md: unwalled runs still exist for shells that reach other machines" 'must reach other machines \(SSH' sh -c "tr '\n' ' ' < references/design.md"
refute "no doc says something was removed" -i 'no longer names|used to name' cat SKILL.md references/design.md

# the brief, fresh and on rejoin
mk_workdir lead h1 h2; setcfg sandbox false; setcfg agent_profiles '{"h1": "remote"}'; setup_wd
for f in "" "--resume"; do
  b=$(cd "$W" && python3 harness/render.py h1 $f)
  check "brief $f lists the network commands ending with wget" '`curl` and `wget`\. That' echo "$b"
  refute "brief $f does not name bridge" -i 'bridge' echo "$b"
done
refute "a non-remote agent's brief has no Remote machines section" '^## Remote machines' sh -c "cd '$W' && python3 harness/render.py h2"

# the monitor is unchanged: each network command passes for remote, and is blocked for h2
for c in 'ssh host ls' 'scp a host:b' 'sftp host' 'rsync -a ./ host:/x' 'curl -sS https://example.com' 'wget -q https://example.com'; do
  check "remote may: $c" '^$' bash_ h1 "$c"
  check "h2 may not: $c" 'permissionDecision' bash_ h2 "$c"
done
finish
