#!/bin/bash
# Acceptance: boss.sh names its team on every line it prints itself  (see STATEMENTS.md, statement `boss_tag`)
. "$(dirname "$0")/../lib.sh"
mk_workdir lead h1 h2; setup_wd; launch >/dev/null 2>&1
S=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['session'])" "$W/config.json")
B="$W/harness/boss.sh"
: > "$STUB_DIR/calls.log"
check "say <id> reports the session, the agent and the text" "^\[$S\] typed into h1: hello there\$" bash "$B" say h1 "hello there"
check "say still types [boss] <text> into that team's window" "send-keys -t =$S:h1 -l \[boss\] hello there" cat "$STUB_DIR/calls.log"
check "say all reports one tagged line per agent" "^\[$S\] typed into lead: hi\|\[$S\] typed into h1: hi\|\[$S\] typed into h2: hi\$" sh -c "bash '$B' say all hi | paste -sd'|'"
check "a slash refusal carries the session" "^\[$S\] refused: no agent nobody" bash "$B" slash nobody /goal
check "unstall on a running run carries the session" "^\[$S\] the run has not stalled" bash "$B" unstall
check "remove reports the session" "^\[$S\] h2 removed\. Ask the lead to reopen its tasks\.\$" bash "$B" remove h2
[ -e "$W/state/removed/h2" ] && ok "remove still marks the helper" || no "remove still marks the helper"
check "status opens with the session and the work directory" "^\[$S\] $W\$" sh -c "bash '$B' status 2>&1 | head -1"
echo "x team-lead team-h1 team-h2" > "$STUB_DIR/pane"
check "trust tags its per-agent lines" "^\[$S\] lead: started without a prompt\$" sh -c "bash '$B' trust | head -1"
check "it works when called by absolute path from another directory" "^\[$S\] typed into h1: x\$" sh -c "cd / && bash '$B' say h1 x"
check "end reports the session" "^\[$S\] run ended\$" bash "$B" end
finish
