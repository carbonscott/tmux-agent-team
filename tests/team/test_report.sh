#!/bin/bash
# Team tests for harness/report.py: escaping wherever record text lands (attributes too), records
# damaged by a crash, the run states it names, and what other statements leave behind (resumes,
# a stall, messages, profiles). The page must change nothing it reads.
. "$(dirname "$0")/../lib.sh"
rep() { ( cd "$W" && python3 harness/report.py -o "$TOP/r.html" ) >/dev/null 2>&1; cat "$TOP/r.html"; }
fp() { find "$W/records" "$W/state" -type f ! -name 'board.db*' ! -name heartbeat -print0 | sort -z | xargs -0 md5sum | md5sum; }

# ---- before setup.sh has run: no state, no records
mk_workdir lead h1 h2
out=$(cd "$W" && python3 harness/report.py -o "$TOP/r.html" 2>&1)
check "it works before setup.sh" '^report: ' sh -c 'echo "$1" | tail -1' sh "$out"
check "and says the run has not started" 'NOT STARTED' cat "$TOP/r.html"
check "with 0 of 3 done" '0 of 3' cat "$TOP/r.html"
( cd "$W" && python3 harness/report.py --bogus ) >/dev/null 2>&1 && no "an unknown argument is refused" || ok "an unknown argument is refused"
out=$(cd "$TOP" && python3 "$W/harness/report.py" -o rel.html 2>&1)
check "a relative -o is printed as a full path" "^report: $TOP/rel.html\$" sh -c 'echo "$1" | tail -1' sh "$out"

# ---- a run with hostile titles, a rejection, a pause, a removal
setcfg agent_profiles '{"h1": "research"}'
setup_wd; launch >/dev/null 2>&1; start_gateway
land h1 a "\"quoted' <b>bold</b> & amp" >/dev/null 2>&1
land h2 b "<img src=x onerror=alert(1)>" no >/dev/null 2>&1
check "the run is shown as running" 'RUNNING' rep
p=$(rep)
refute "a hostile merge title never appears as markup" '<b>bold</b>|<img src=x' echo "$p"
check "and is shown as text" '&lt;b&gt;bold&lt;/b&gt;' echo "$p"
refute "quotes cannot break out of an attribute" "title=\"[^\"]*\"quoted" echo "$p"
check "the rejected title is shown escaped" '&lt;img src=x onerror=alert\(1\)&gt;' echo "$p"
check "the rejection's reason is shown" 'REJECTED by the check' echo "$p"
check "a statement chip shows a as done" '<li class="on"[^>]*>a</li>' echo "$p"
check "each agent's profile is shown" '<td>h1</td><td>research</td>' echo "$p"
check "the default profile is sealed" '<td>lead</td><td>sealed</td>' echo "$p"
check "the timeline marks the accepted merge" 'class="m ok"' echo "$p"
check "and the rejected one" 'class="m no"' echo "$p"
check "the page fits a phone" 'name="viewport" content="width=device-width' echo "$p"
check "the page has a dark theme" 'prefers-color-scheme:dark' echo "$p"
check "and a narrow layout" '@media \(max-width:600px\)' echo "$p"
echo '{"tool_name":"Bash","tool_input":{"command":"sudo cat <x> & echo \"</code><script>bad()</script>\""},"cwd":"'"$W/ws/h2"'"}' \
  | python3 "$W/harness/hook.py" h2 >/dev/null 2>&1
( cd "$W" && harness/boss.sh remove h2 ) >/dev/null 2>&1
before=$(fp)
p=$(rep)
[ "$(fp)" = "$before" ] && ok "writing the report changes nothing in records/ or state/" || no "writing the report changes nothing in records/ or state/"
check "a pause in progress is shown" 'PAUSED' echo "$p"
check "as still paused" 'still paused' echo "$p"
refute "the blocked command is escaped" '<script>bad\(\)</script>|</code><script>' echo "$p"
check "and shown" 'sudo cat &lt;x&gt;' echo "$p"
check "the blocked action is marked on the timeline" 'class="m blk"' echo "$p"
check "the removal is listed with the agent" '<td>h2</td></tr>' echo "$p"
check "and drawn on h2's lane" 'class="gone"' echo "$p"
( cd "$W" && harness/boss.sh resume ) >/dev/null 2>&1
p=$(rep)
refute "a cleared pause is no longer in progress" 'still paused' echo "$p"
check "but is still listed" 'sudo cat' echo "$p"
check "and drawn as a band" 'class="band pause"' echo "$p"

# ---- what other statements leave behind, and damage from a crash
python3 -c "import time; open('$W/records/resumes.jsonl','a').write('{\"ts\": %f, \"down_s\": 600}\n' % (time.time() - 5))"
printf '{"ts": 1, "agent": "h1", "op": "sq' >> "$W/records/gateway.jsonl"     # a line cut short by a crash
printf 'not json at all\n' >> "$W/records/actions.jsonl"
p=$(rep)
check "records cut short by a crash do not stop the report" 'RUNNING|PAUSED' echo "$p"
check "a resume is listed with the time down" '<td>10m 00s</td>' echo "$p"
check "and drawn as down time" 'class="band down"' echo "$p"
as h1 team msg h2 "x" >/dev/null 2>&1; as h1 team msg h2 "<i>y</i>" >/dev/null 2>&1; as lead team msg all "z" >/dev/null 2>&1
p=$(rep)
check "messages are counted by sender and recipient" '<td>h1</td><td>h2</td><td>2</td>' echo "$p"
check "a message to all is counted" '<td>lead</td><td>all</td><td>1</td>' echo "$p"
check "the total number of messages is stated" '<dt>messages</dt><dd>3</dd>' echo "$p"
refute "message text is not put on the page" '<i>y</i>|&lt;i&gt;y' echo "$p"
stop_gateway; mv "$W/state/board.db" "$TOP/board.db"; rm -f "$W"/state/board.db-*
check "without the board, messages are counted from the gateway log" '<td>h1</td><td>h2</td><td>2</td>' rep
mv "$TOP/board.db" "$W/state/board.db"
echo '{"ts": '"$(date +%s)"', "stall_min": 30, "idle_s": 1800}' > "$W/state/STALLED"
p=$(rep)
check "a stall is named as the state of the run" 'STALLED' echo "$p"
check "with its limit" 'no merge accepted for 30 min' echo "$p"
check "and drawn on the timeline" 'class="rule stall"' echo "$p"
rm -f "$W/state/STALLED"
python3 -c "import time; open('$W/state/deadline','w').write(str(time.time() - 1))"
check "a run out of time says TIME UP" 'TIME UP' rep

# ---- a finished run
mk_workdir lead h1; setup_wd; launch >/dev/null 2>&1; start_gateway
land h1 a >/dev/null 2>&1; land h1 b >/dev/null 2>&1; land h1 c >/dev/null 2>&1
p=$(rep)
check "a finished run says COMPLETE" 'COMPLETE' echo "$p"
check "with 3 of 3 done" '3 of 3' echo "$p"
check "the done lane names each statement where it was done" '<b class="m done"[^>]*>c</b>' echo "$p"
check "the page's title says how much is done" '<title>[^<]*3 of 3 done</title>' echo "$p"
refute "the page loads nothing from the network" -i '(src|href)\s*=\s*["'"'"']?(https?:)?//|@import|url\(' echo "$p"
check "SKILL.md puts the report in the finish steps" 'report\.py' cat "$REPO/SKILL.md"
finish
