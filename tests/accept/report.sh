#!/bin/bash
# Acceptance: the run report, harness/report.py  (see STATEMENTS.md, statement `report`)
. "$(dirname "$0")/../lib.sh"

mk_workdir lead h1 h2; setup_wd
( cd "$W" && python3 harness/report.py -o "$TOP/r0.html" ) >/dev/null 2>&1 && grep -qi '<html' "$TOP/r0.html" \
  && ok "report.py works before any run" || no "report.py works before any run"
launch >/dev/null 2>&1; start_gateway
check "h1 lands a"            'ACCEPTED' land h1 a "land a"
check "h2 is rejected once"   'REJECTED' land h2 b "first try at b" no
check "h2 lands b"            'ACCEPTED' land h2 b "<script>x</script> b" ok
( cd "$W" && python3 harness/report.py -o "$TOP/r.html" ) >/dev/null 2>&1 && ok "report.py -o FILE succeeds during a run" || no "report.py -o FILE succeeds during a run"
R1=$TOP/r.html
check  "it is an HTML page"                          -i '<html' cat "$R1"
check  "it states how much is done"                  '2 of 3' cat "$R1"
check  "it names the agents"                         'h1' cat "$R1"
check  "it names the agents (h2)"                    'h2' cat "$R1"
check  "it lists accepted merges by title"           'land a' cat "$R1"
check  "it lists rejected merge requests"            'first try at b' cat "$R1"
check  "it says they were rejected"                  -i 'reject' cat "$R1"
refute "text from the records is escaped"            '<script>x</script>' cat "$R1"
check  "and still shown"                             '&lt;script&gt;x&lt;/script&gt;' cat "$R1"
refute "the page loads nothing from the network"     -i '(src|href)\s*=\s*["'"'"']?(https?:)?//' cat "$R1"
[ "$(wc -c < "$R1")" -ge 2000 ] && ok "it is a real page, not a stub" || no "it is a real page, not a stub"
( cd "$W" && harness/boss.sh remove h2 ) >/dev/null 2>&1
echo '{"tool_name":"Bash","tool_input":{"command":"sudo ls"},"cwd":"'"$W/ws/h1"'"}' | python3 "$W/harness/hook.py" h1 >/dev/null 2>&1
out=$(cd "$W" && python3 harness/report.py 2>&1)
check "with no -o it writes report.html in the work directory and says so" "^report: $W/report.html\$" sh -c 'echo "$1" | tail -1' sh "$out"
check "the report shows the pause" -i 'paus' cat "$W/report.html"
check "and what was blocked" 'sudo' cat "$W/report.html"
check "and the removal" -i 'remov' cat "$W/report.html"
check "report.html is not tracked as part of the template" 'report\.html' cat "$W/.gitignore"
check "SKILL.md documents report.py" 'report\.py' cat "$REPO/SKILL.md"
finish
