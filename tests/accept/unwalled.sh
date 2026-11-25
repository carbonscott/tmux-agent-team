#!/bin/bash
# Acceptance: "sandbox": false, a run without the shell sandbox  (see STATEMENTS.md, statement `unwalled`)
. "$(dirname "$0")/../lib.sh"
enabled() {   # sandbox.enabled of each named agent's settings, on one line
  python3 - "$W" "$@" <<'PY'
import json, sys
w, agents = sys.argv[1], sys.argv[2:]
print(*[json.load(open("%s/harness/settings/%s.json" % (w, a))).get("sandbox", {}).get("enabled") for a in agents])
PY
}
visible() {   # the text a reader sees on an HTML page: no tags, no <script> or <style> contents
  python3 - "$1" <<'PY'
import html.parser, sys
class P(html.parser.HTMLParser):
    def __init__(s):
        super().__init__(); s.skip = 0; s.out = []
    def handle_starttag(s, t, a):
        s.skip += t in ("script", "style")
    def handle_endtag(s, t):
        s.skip -= t in ("script", "style")
    def handle_data(s, d):
        s.skip or s.out.append(d)
p = P(); p.feed(open(sys.argv[1]).read()); print(" ".join(p.out))
PY
}
report() { ( cd "$W" && python3 harness/report.py -o "$TOP/report.html" >/dev/null 2>&1 ) && visible "$TOP/report.html"; }
hook() { rm -f "$W/state/HALT"; echo "{\"tool_name\":\"$2\",\"tool_input\":$3,\"cwd\":\"$W/ws/$1\"}" | python3 "$W/harness/hook.py" "$1"; }
DENY='"permissionDecision": "deny"'
WARN='unwalled|sandbox (is )?off'

# the default stays walled
mk_workdir lead h1; setup_wd; launch >/dev/null 2>&1
check  "by default every agent's shell sandbox is on" '^True True$' enabled lead h1
refute "a walled run's status does not say unwalled" -i 'unwalled' sh -c "cd '$W' && harness/boss.sh status"
refute "a walled run's report does not say unwalled" -i 'unwalled' report

# "sandbox": true is the same as leaving it out
mk_workdir lead h1; setcfg sandbox true; setup_wd
check  "\"sandbox\": true keeps the sandbox on" '^True True$' enabled lead h1

# "sandbox": false
mk_workdir lead h1 h2; setcfg sandbox false
setup_wd && ok "setup.sh accepts \"sandbox\": false" || no "setup.sh accepts \"sandbox\": false"
check  "setup.sh says the sandbox is off" -i "$WARN" cat "$TOP/setup.log"
check  "every agent's shell sandbox is off" '^False False False$' enabled lead h1 h2
check  "Git still works for the agents (GIT_CONFIG_GLOBAL stays set)" '/dev/null' python3 -c "
import json; print(json.load(open('$W/harness/settings/h1.json'))['env']['GIT_CONFIG_GLOBAL'])"
check  "the monitor hook is still installed" 'hook.py' cat "$W/harness/settings/h1.json"
check  "the keep-going hook is still installed" 'keepgoing.py' cat "$W/harness/settings/h1.json"
check  "selftest.sh, run before launch, says the sandbox is off" -i "$WARN" sh -c "cd '$W' && timeout 60 harness/selftest.sh h1 </dev/null"
check  "launch.sh says the sandbox is off" -i "$WARN" launch
check  "boss.sh status says the run is unwalled" -i 'unwalled' sh -c "cd '$W' && harness/boss.sh status"
check  "the run's page says the run is unwalled" -i 'unwalled' report
check  "the monitor still refuses tmux" "$DENY" hook h1 Bash '{"command":"tmux ls"}'
check  "and that still pauses the team" . ls "$W/state/HALT"
check  "the monitor still refuses a direct push" "$DENY" hook h1 Bash '{"command":"git push origin HEAD:main"}'
check  "the monitor still records every call" '"tool": "Bash"' tail -1 "$W/records/actions.jsonl"
rm -f "$W/state/HALT"
start_gateway
check  "the merge job still rejects a wrong answer" 'REJECTED by the check' land h1 a "wrong a" no
check  "the merge job still lands a right answer" 'ACCEPTED: merged into main' land h2 a "right a" ok
stop_gateway
DEST=$TOP/dest; mkdir -p "$DEST"
out=$(cd "$W" && ./teardown.sh --archive "$DEST" 2>&1); f=$(ls "$DEST"/team-archive-*.tar.gz 2>/dev/null | head -1)
mkdir -p "$TOP/x"; tar -xzf "${f:-/nonexistent}" -C "$TOP/x" 2>/dev/null; s=$(find "$TOP/x" -maxdepth 2 -name STATUS.txt | head -1)
check  "the archive's STATUS.txt says the run was unwalled" -i 'unwalled' cat "${s:-/nonexistent}"
check  "and its first line keeps its usual form" '^abandoned run, stopped .+, 1 of 3 done, not verified$' head -1 "${s:-/nonexistent}"

# anything but true or false is refused
mk_workdir lead h1; setcfg sandbox '"no"'
( cd "$W" && ./setup.sh ) >/dev/null 2>&1 && no "setup.sh refuses a sandbox value that is not true or false" || ok "setup.sh refuses a sandbox value that is not true or false"

check "SKILL.md documents \"sandbox\": false" '"sandbox": false' cat "$REPO/SKILL.md"
check "references/design.md says what an unwalled run gives up" -i 'unwalled' cat "$REPO/references/design.md"
finish
