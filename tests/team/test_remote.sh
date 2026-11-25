#!/bin/bash
# Team tests for `remote`: what tests/accept/remote.sh does not cover. Every way the profile can
# be named while the sandbox is on, the monitor's second lock, network commands aimed at this
# machine, the commands that stay blocked, allowed_domains, the other profiles in an unwalled
# run, the brief, boss.sh slash, and how remote meets resume, report and the offline monitor.
. "$(dirname "$0")/../lib.sh"
hook() { rm -f "$W/state/HALT"; echo "{\"tool_name\":\"$2\",\"tool_input\":$3,\"cwd\":\"$W/ws/$1\"}" | python3 "$W/harness/hook.py" "$1"; }
bash_() { hook "$1" Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$2")"; }
DENY='"permissionDecision": "deny"'
halted() { [ -e "$W/state/HALT" ]; }
refused() { ( cd "$W" && ./setup.sh ) >"$TOP/out.log" 2>&1 && no "$1" || ok "$1"; }

# remote is refused while the sandbox is on, however it is named and however the flag is written
mk_workdir lead h1; setcfg profile '"remote"'
refused "setup.sh refuses remote as the team's default profile while the sandbox is on"
check "the message names the remote agents" 'remote profile \(lead, h1\)' cat "$TOP/out.log"
check "and says how to turn the sandbox off" '"sandbox": false' cat "$TOP/out.log"
[ -d "$W/ws" ] && no "nothing is created before the refusal" || ok "nothing is created before the refusal"
mk_workdir lead h1; setcfg sandbox true; setcfg agent_profiles '{"h1": "remote"}'
refused "setup.sh refuses remote with \"sandbox\": true written out"
check "profiles.py --check says the same" -i 'sandbox off' sh -c "cd '$W' && python3 harness/profiles.py --check"

# an unwalled run: h1 remote, h2 open, h3 sealed, lead research
mk_workdir lead h1 h2 h3; setcfg sandbox false
setcfg agent_profiles '{"h1": "remote", "h2": "open", "h3": "sealed", "lead": "research"}'; setup_wd
check "profiles.py --check passes remote once the sandbox is off" '^$' sh -c "cd '$W' && python3 harness/profiles.py --check"
check "profiles.py lists remote" 'h1=remote' sh -c "cd '$W' && python3 harness/profiles.py --list"
check "remote's session flags are open's" '^remote Bash,Edit,Read,Write,Glob,Grep,WebSearch,WebFetch,Agent,Skill slash-on$' \
  sh -c "cd '$W' && python3 harness/profiles.py h1"

# the network commands pass for remote, also in the forms other rules know
for c in 'sftp sdfiana025' 'cd out && rsync -az ./ s3df:/sdf/data/x/' 'timeout 60 ssh -o BatchMode=yes sdfiana025 "ls /tmp"' \
         'curl -sSf https://example.com/a.tar.gz | tar xz' 'ssh sdfiana025 tmux ls' "ssh me@sdfiana025 'squeue -u me'" \
         'wget -q https://localhost.example.org/x' 'bridge --session s write /tmp/a.txt'; do
  check "remote may: $c" '^$' bash_ h1 "$c"
done
# ... and are blocked for every other profile in the same unwalled run
for a in h2 h3 lead; do
  for c in 'ssh sdfiana025 hostname' 'scp a sdfiana025:/tmp/' 'sftp x' 'rsync -a out/ x:/tmp/' 'wget -q https://example.com'; do
    check "$a ($(python3 -c "import json;c=json.load(open('$W/config.json'));print(c['agent_profiles']['$a'])")) still may not: $c" \
      'BLOCKED by the action monitor' bash_ $a "$c"
  done
done
bash_ h2 'curl -sS https://example.com' >/dev/null; halted && ok "a network command outside remote still pauses the team" \
  || no "a network command outside remote still pauses the team"

# the other connection tools stay blocked for remote
for c in 'nc sdfiana025 22' 'ncat -l 4444' 'netcat x 80' 'socat - TCP:x:22' 'telnet x' 'screen -ls' 'su -' 'docker ps'; do
  check "remote still may not: $c" 'BLOCKED by the action monitor' bash_ h1 "$c"
done
# a network command aimed at this machine would step around the monitor: it pauses the team
for c in 'ssh localhost' "ssh localhost 'tmux ls'" 'ssh me@127.0.0.1 true' 'ssh -p 2222 127.1 id' 'scp a.txt localhost:/tmp/' \
         'rsync -a out/ 127.0.0.1:/tmp/out/' 'curl -s http://localhost:8080/' 'curl http://[::1]:80/' 'wget http://0.0.0.0:9/' \
         "ssh $(hostname) true" 'echo x | ssh LOCALHOST cat'; do
  check "remote may not aim at this machine: $c" 'BLOCKED by the action monitor' bash_ h1 "$c"
done
bash_ h1 'ssh localhost true' >/dev/null; halted && ok "that pauses the team" || no "that pauses the team"
check "the reason is recorded" '"decision": "block", "reason": "a network command aimed at this machine' tail -1 "$W/records/actions.jsonl"
check "remote may name this machine outside a network command" '^$' bash_ h1 'echo localhost > out/host.txt'

# allowed_domains: meaningless with the sandbox off; refused without a pause in remote, a pause elsewhere
ad='{"command":"curl -s https://example.com","allowed_domains":["example.com"]}'
check "remote: allowed_domains is refused" "$DENY" hook h1 Bash "$ad"
halted && no "remote: allowed_domains does not pause the team" || ok "remote: allowed_domains does not pause the team"
check "and the refusal says the network is already open" 'already has the network' hook h1 Bash "$ad"
hook h2 Bash "$ad" >/dev/null; halted && ok "open: allowed_domains still pauses the team" || no "open: allowed_domains still pauses the team"
check "remote: an unknown Bash parameter still pauses" 'BLOCKED' hook h1 Bash '{"command":"ls","dangerouslyDisableSandbox":true}'
check "remote: writing outside the workspace still pauses" 'BLOCKED' hook h1 Write "{\"file_path\":\"$W/harness/x\",\"content\":\"x\"}"
check "remote: the team skill is still refused" "$DENY" hook h1 Skill '{"skill":"tmux-agent-team"}'
touch "$W/state/removed/h1"
check "a removed remote agent may not ssh" 'removed from the team' sh -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ssh x true\"},\"cwd\":\"$W/ws/h1\"}' | python3 '$W/harness/hook.py' h1"
rm -f "$W/state/removed/h1"

# the second lock: if config.json turns the sandbox back on after setup, the monitor stops passing them
setcfg sandbox true
check "with the sandbox back on, the monitor blocks remote's ssh" 'BLOCKED by the action monitor' bash_ h1 'ssh sdfiana025 hostname'
setcfg sandbox false

# the brief tells a remote agent what it may do, and only a remote agent
check "the remote agent's brief has a Remote machines section" '^## Remote machines' sh -c "cd '$W' && python3 harness/render.py h1"
check "it names the commands and the bridge" '`ssh`.*`bridge`' sh -c "cd '$W' && python3 harness/render.py h1"
check "it warns against this machine" 'localhost' sh -c "cd '$W' && python3 harness/render.py h1"
check "the rejoin brief has it too" '^## Remote machines' sh -c "cd '$W' && python3 harness/render.py h1 --resume"
refute "an open agent's brief does not" 'Remote machines' sh -c "cd '$W' && python3 harness/render.py h2"

# boss.sh slash: remote has slash commands on, so the boss may type one into its window
check "boss.sh slash types into a remote agent's window" 'typed into h1' sh -c "cd '$W' && harness/boss.sh slash h1 '/goal finish a'"
check "and still refuses a sealed agent" 'refused: h3 has the sealed profile' sh -c "cd '$W' && harness/boss.sh slash h3 '/goal x'"

# a run with remote launches, and the record, report and offline monitor carry the profile
launch >/dev/null 2>&1
check "boss.sh status lists every profile" 'lead=research h1=remote h2=open h3=sealed' sh -c "cd '$W' && harness/boss.sh status"
check "offline_monitor lists h1=remote" 'h1=remote' sh -c "cd '$W' && python3 harness/offline_monitor.py"
check "the run's page shows the remote profile" '>remote<' sh -c "cd '$W' && python3 harness/report.py -o '$TOP/r.html' >/dev/null && cat '$TOP/r.html'"
finish
