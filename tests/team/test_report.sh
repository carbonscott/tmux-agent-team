#!/bin/bash
# Team tests for harness/report.py: escaping wherever record text lands (attributes too), records
# damaged by a crash, the run states it names, and what other statements leave behind (resumes,
# a stall, messages, profiles). The page must change nothing it reads.
. "$(dirname "$0")/../lib.sh"
rep() { ( cd "$W" && python3 harness/report.py -o "$TOP/r.html" ) >/dev/null 2>&1; cat "$TOP/r.html"; }
fp() { find "$W/records" "$W/state" -type f ! -name 'board.db*' ! -name heartbeat -print0 | sort -z | xargs -0 md5sum | md5sum; }
# CSS rules that would pull a legend swatch (<i class="k act">, ...) out of the legend: an
# absolutely placed rule whose selector is only classes the swatch also has
swatches() { python3 - "$1" <<'PY'
import re, sys
css = re.search(r"<style>(.*?)</style>", open(sys.argv[1]).read(), re.S).group(1)
css = re.sub(r"@media[^{]*\{((?:[^{}]*\{[^{}]*\})*)[^{}]*\}", r"\1", css)
bad = []
for sel, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css):
    if "position:absolute" in body.replace(" ", ""):
        for s in (x.strip() for x in sel.split(",")):
            for sw in ("act", "gone", "pause", "down", "stall", "ok", "no", "blk"):
                if re.fullmatch(r"(\.[\w-]+)+", s) and set(s[1:].split(".")) <= {"k", sw}:
                    bad.append("%s also matches the legend swatch .k.%s" % (s, sw))
print("\n".join(bad) or "ok")
PY
}
# Labels on the timeline's done lane that overlap, at the narrowest track each kind is shown on:
# names (desktop, track >= 460 px) and numbers (phone, track >= 260 px), ~6.5 px per character
overlaps() { python3 - "$1" <<'PY'
import re, sys
page = open(sys.argv[1]).read()
bad = []
for cls, track, pad in (("done", 460, 8), ("num", 260, 10)):
    marks = []
    for style, text in re.findall(r'<b class="m %s" style="([^"]*)"[^>]*>([^<]*)</b>' % cls, page):
        v = dict(re.findall(r"([\w-]+):([^;]+)", style))
        x, w = float(v["left"].rstrip("%")) * track / 100, max(16, 6.5 * len(text) + pad)
        a = x + float(v.get("--x", "-50%").rstrip("%")) / 100 * w
        marks.append((int(v.get("--r", 0)), a, a + w, text))
    if len(marks) < 5:
        bad.append("only %d %s labels" % (len(marks), cls))
    for i, (r, a, b, t) in enumerate(marks):
        for r2, a2, b2, t2 in marks[i + 1:]:
            if r == r2 and a < b2 and a2 < b:
                bad.append("%s labels %s and %s overlap" % (cls, t, t2))
print("\n".join(bad) or "ok")
PY
}
# Tables at phone width: every table must give each labelled column's header to its cells there
labelled() { python3 - "$1" <<'PY'
import json, re, sys
page = open(sys.argv[1]).read()
narrow = ""
for m in re.finditer(r"@media \(max-width:600px\)\{", page):     # each block, to its matching brace
    depth, i = 1, m.end()
    while depth and i < len(page):
        depth += {"{": 1, "}": -1}.get(page[i], 0)
        i += 1
    narrow += page[m.end():i]
bad, n = [], 0
for t in re.findall(r"<table[^>]*>.*?</table>", page, re.S):
    n += 1
    m = re.match(r'<table class="(t-[\w-]+)"', t)
    if not m:
        bad.append("a table without a name: %s" % t[:60])
        continue
    for i, h in enumerate(re.findall(r"<th>([^<]*)</th>", t)):
        if h and ".%s td:nth-child(%d)" % (m.group(1), i + 1) not in narrow:
            bad.append("%s: column %r has no rule for phone width" % (m.group(1), h))
print("\n".join(bad) or ("ok" if n else "no tables"))
PY
}
# contrast of text on its background, light and dark theme, for the rules named:  contrast FILE 'selector' ...
contrast() { python3 - "$@" <<'PY'
import re, sys
css = re.search(r"<style>(.*?)</style>", open(sys.argv[1]).read(), re.S).group(1)
light = dict(re.findall(r"--([\w-]+):([^;}]+)", re.search(r"(?m)^:root\{(.*?)\}", css, re.S).group(1)))
dark = dict(light, **dict(re.findall(r"--([\w-]+):([^;}]+)", re.search(r":root\[data-theme=dark\]\{(.*?)\}", css, re.S).group(1))))
def lum(h):
    c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
def val(v, theme):
    v = v.strip()
    while v.startswith("var("):
        v = theme[v[6:-1]].strip()
    return {"#fff": "#ffffff", "#000": "#000000"}.get(v, v)
low = []
for sel in sys.argv[2:]:
    decl = {}
    for s, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css):
        if sel in [x.strip() for x in s.split(",")]:
            decl.update(re.findall(r"([\w-]+):([^;]+)", body))
    for name, theme in (("light", light), ("dark", dark)):
        fg, bg = val(decl["color"], theme), val(decl.get("background", "var(--bg)"), theme)
        a, b = sorted((lum(fg), lum(bg)))
        r = (b + 0.05) / (a + 0.05)
        if r < 4.5:
            low.append("%s in %s: %s on %s is %.2f:1" % (sel, name, fg, bg, r))
print("\n".join(low) or "ok")
PY
}

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
# a resume record as launch.sh --resume writes it: every field in human terms, no raw epoch numbers
python3 -c "
import json, time; t = time.time() - 3
print(json.dumps(dict(ts=t, down_s=187.8, given_back_s=187.8, last_beat=t - 187.8, beat_from='heartbeat', paused=False,
      deadline_before=t + 1000, deadline_after=t + 1187.8, removed=['h2'], landed=['a'])))" >> "$W/records/resumes.jsonl"
rs=$(rep | sed -n '/<h2>Resumes</,/<\/section>/p')
refute "the resumes table shows no raw epoch numbers or field names" '[0-9]{10}|_s=|last_beat|deadline_after' echo "$rs"
check "it shows the time given back, then the new deadline as a clock time" '<td>3m 07s</td><td>[0-9]{2}:[0-9]{2}:[0-9]{2}</td>' echo "$rs"
check "and who was not restarted" 'h2' echo "$rs"
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

# ---- found by the live proof run
check "the legend's swatches stay in the legend (no lane rule matches them)" '^ok$' swatches "$TOP/r.html"
check "text on green (statement chips, done labels) has 4.5:1 contrast in both themes" '^ok$' \
  contrast "$TOP/r.html" '.chips li.on' '.m.done'
check "the state word (COMPLETE, STALLED, PAUSED, RUNNING) has 4.5:1 contrast in both themes" '^ok$' \
  contrast "$TOP/r.html" '.good .s' '.bad .s' '.warn .s' '.live .s'
check "at phone width every table cell is shown with its column's name" '^ok$' labelled "$TOP/r.html"
# running time: 50 min on the wall, less a reviewed pause (5 min) and the time down before a resume (10 min)
python3 -c "
import json, time; b = int(time.time()) - 4000
open('$W/state/started', 'w').write(str(b)); open('$W/state/DONE', 'w').write(str(b + 3000))
json.dump(dict(ts=b + 600, agent='h1', reason='test'), open('$W/records/halt.%d.json' % (b + 900), 'w'))
open('$W/records/resumes.jsonl', 'a').write(json.dumps(dict(ts=b + 1800, down_s=600)) + '\\n')"
p=$(rep)
check "the time a run took is its running time: wall time less pauses and time down" '<dt>running time</dt><dd>35m 00s' echo "$p"
check "the time stopped is stated beside it" 'paused 5m 00s, down 10m 00s' echo "$p"
check "boss.sh status gives the running time of a finished run" 'RUN COMPLETE in 35.0 min' sh -c "cd '$W' && harness/boss.sh status"
check "and the time stopped" 'paused 5.0 min, down 10.0 min' sh -c "cd '$W' && harness/boss.sh status"

# five statements done within one minute of a ten-minute run: every label stays legible
mk_workdir lead h1 h2; setcfg task.statements '["alpha", "beta", "gamma", "delta", "epsilon"]'; mkdir -p "$W/state" "$W/records"
python3 -c "
import json, time; b = int(time.time()) - 900; names = ['alpha', 'beta', 'gamma', 'delta', 'epsilon']
open('$W/state/started', 'w').write(str(b)); open('$W/state/deadline', 'w').write(str(b + 1800))
with open('$W/records/merges.jsonl', 'w') as f:
    for k, n in enumerate(names):
        f.write(json.dumps(dict(ts=b + 300 + 15 * k, agent='h1', title=n, landed=names[:k + 1])) + '\n')
open('$W/state/DONE', 'w').write(str(b + 600)); json.dump(names, open('$W/state/landed.json', 'w'))"
p=$(rep)
check "five done labels within a minute do not overlap, as names or as numbers" '^ok$' overlaps "$TOP/r.html"
check "the numbers are keyed to the statements, in order" '<ol class="dkey">.*alpha.*beta.*gamma.*delta.*epsilon' echo "$p"
check "the narrow layout shows numbers and the key instead of names" '@media \(max-width:600px\)\{\.m\.done\{display:none\}' echo "$p"
finish
