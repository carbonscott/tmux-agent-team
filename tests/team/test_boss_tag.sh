#!/bin/bash
# boss_tag: boss.sh names its team on every line it prints itself; passed-through output,
# the usage text and exit statuses are unchanged. Covers what tests/accept/boss_tag.sh does not.
. "$(dirname "$0")/../lib.sh"
mk_workdir lead h1 h2 h3; setcfg agent_profiles '{"h3": "open"}'; setup_wd; launch >/dev/null 2>&1
S=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['session'])" "$W/config.json")
B="$W/harness/boss.sh"
T="^\[$S\] "

# ---- slash: success and every refusal tagged, exit statuses kept
: > "$STUB_DIR/calls.log"
check "slash on an open agent reports, tagged" "${T}typed into h3: /goal x\$" sh -c "cd / && bash '$B' slash h3 '/goal x'"
check "slash still types the line as it is (no tag, no [boss])" "send-keys -t =$S:h3 -l /goal x" cat "$STUB_DIR/calls.log"
out=$(bash "$B" slash h1 "/goal x" 2>&1); rc=$?
check "slash refusal for a sealed profile is tagged" "${T}refused: h1 has the .* profile" echo "$out"
[ $rc -eq 1 ] && ok "and still exits 1" || no "and still exits 1" "rc=$rc"
out=$(bash "$B" slash h3 "goal x" 2>&1); rc=$?
check "slash refusal for a non-slash line is tagged" "${T}refused: give one line" echo "$out"
[ $rc -eq 1 ] && ok "and still exits 1" || no "and still exits 1" "rc=$rc"
bash "$B" slash nobody /goal >/dev/null 2>&1; rc=$?
[ $rc -eq 1 ] && ok "slash for an unknown agent still exits 1" || no "slash for an unknown agent still exits 1" "rc=$rc"

# ---- say: exactly one tagged line, exit 0
out=$(bash "$B" say h2 "two words" 2>&1); rc=$?
[ "$out" = "[$S] typed into h2: two words" ] && ok "say prints exactly one tagged line" || no "say prints exactly one tagged line" "$out"
[ $rc -eq 0 ] && ok "say exits 0" || no "say exits 0" "rc=$rc"
check "say all reports every agent" "^4\$" sh -c "bash '$B' say all hey | grep -c '^\[$S\] typed into [a-z0-9]*: hey\$'"

# ---- status: work dir first, own lines tagged, board view passed through untagged
out=$(cd / && bash "$B" status 2>&1); rc=$?
[ "$(head -1 <<<"$out")" = "[$S] $W" ] && ok "status line 1 is the tag and the absolute work dir" || no "status line 1 is the tag and the absolute work dir" "$out"
check "status tags its profiles line" "${T}profiles: " echo "$out"
check "status still shows the board view untagged" '^== .*time left: ' echo "$out"
[ $rc -eq 0 ] && ok "status exits 0" || no "status exits 0" "rc=$rc"
python3 -c "import json,time; json.dump(dict(ts=time.time(), agent='h1', tool='Bash', why='probe'), open('$W/state/HALT','w'))"
out=$(bash "$B" status 2>&1); rc=$?
check "status tags 'blocked action:'" "${T}blocked action:\$" echo "$out"
check "the HALT record is passed through untagged" '^    "why": "probe"' echo "$out"
[ $rc -eq 0 ] && ok "status exits 0 when paused" || no "status exits 0 when paused" "rc=$rc"

# ---- resume / unstall
check "resume is tagged" "${T}pause cleared\." bash "$B" resume
python3 -c "import json; json.dump(dict(stall_min=1), open('$W/state/STALLED','w'))"
check "unstall is tagged" "${T}stall cleared;" bash "$B" unstall
bash "$B" unstall >/dev/null 2>&1; rc=$?
[ $rc -eq 1 ] && ok "unstall on a running run still exits 1" || no "unstall on a running run still exits 1" "rc=$rc"

# ---- trust: every line tagged, including 'still starting'
echo "nothing here" > "$STUB_DIR/pane"
out=$(timeout 60 bash "$B" trust 2>&1)
check "trust 'still starting' is tagged" "${T}still starting, run again:" echo "$out"
refute "trust prints no untagged line" "^[^[]" echo "$out"

# ---- usage text and messages are left as they are
out=$(bash "$B" help 2>&1)
check "usage text unchanged" '^# The boss.s controls\.$' echo "$out"
refute "usage text is not tagged" "^\[$S\]" echo "$out"
refute "messages output is not tagged" "^\[$S\]" bash "$B" messages

# ---- two teams: each boss.sh names its own session
S1=$S; B1=$B; W1=$W
mk_workdir lead h1; setup_wd; launch >/dev/null 2>&1
S2=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['session'])" "$W/config.json")
[ "$S1" != "$S2" ] && ok "two work dirs, two sessions" || no "two work dirs, two sessions"
check "the second team's boss.sh names the second session" "^\[$S2\] typed into h1: a\$" sh -c "cd '$W1' && bash '$W/harness/boss.sh' say h1 a"
check "the first team's boss.sh still names the first" "^\[$S1\] typed into h1: b\$" sh -c "cd '$W' && bash '$B1' say h1 b"
finish
