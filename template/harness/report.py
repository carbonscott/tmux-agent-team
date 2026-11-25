"""Write one self-contained HTML page that shows what a run did.  usage: report.py [-o FILE]

Without -o the page is report.html in the work directory. The last line printed is
"report: <full path>". It reads config.json, state/ and records/ and changes nothing, so it
works before a run, during one and after one. The page loads nothing from the network, and
every piece of text that comes from the records is escaped.
"""
import collections
import glob
import html
import json
import os
import re
import sqlite3
import sys
import time

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE, REC = R + "/state", R + "/records"
CFG = json.load(open(R + "/config.json"))
AGENTS, STATEMENTS = CFG["agents"], CFG["task"]["statements"]
NOW = time.time()
e = lambda s: html.escape(str(s), quote=True)


def load(name):
    out = []
    try:
        for line in open(os.path.join(REC, name)):
            try:
                out.append(json.loads(line))
            except ValueError:
                # a line cut short by a crash has the next record glued to its end: keep that one
                i = line.rfind('{"ts"')
                try:
                    out.append(json.loads(line[i:])) if i > 0 else None
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def num(path):
    try:
        return float(open(path).read().strip())
    except (OSError, ValueError):
        return None


def jfile(path):
    try:
        d = json.load(open(path))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {} if os.path.exists(path) else None


def clock(t):
    return time.strftime("%H:%M:%S", time.localtime(t)) if t else "-"


def span(s):
    s = int(max(0, s or 0))
    return "%dh %02dm" % (s // 3600, s % 3600 // 60) if s >= 3600 else "%dm %02ds" % (s // 60, s % 60) if s >= 60 \
        else "%ds" % s


def profile_of(a):
    return (CFG.get("agent_profiles") or {}).get(a) or CFG.get("profile") or "sealed"


def first_line(out, prefix):
    lines = str(out).splitlines()
    for i, l in enumerate(lines):
        if l.startswith(prefix):
            more = " ".join(x.strip() for x in lines[i + 1:i + 3] if x.strip())
            return (l + (" " + more if more else ""))[:400]
    return str(out)[:300]


# ------------------------------------------------------------------ gather
def gather():
    g = dict(acts=load("actions.jsonl"), gw=load("gateway.jsonl"), merges=load("merges.jsonl"),
             resumes=load("resumes.jsonl"))
    g["started"], g["deadline"] = num(STATE + "/started"), num(STATE + "/deadline")
    g["done_at"], g["beat"] = num(STATE + "/DONE"), num(STATE + "/heartbeat")
    try:
        g["landed"] = [s for s in json.load(open(STATE + "/landed.json")) if s in STATEMENTS]
    except (OSError, ValueError):
        g["landed"] = []
    st = jfile(STATE + "/STALLED")
    if st is not None:
        st.setdefault("ts", os.path.getmtime(STATE + "/STALLED"))
    g["stalled"] = st
    pauses = []
    for p in sorted(glob.glob(REC + "/halt.*.json")):
        h = jfile(p) or {}
        try:
            end = float(os.path.basename(p).split(".")[1])
        except (IndexError, ValueError):
            end = os.path.getmtime(p)
        pauses.append(dict(h, end=end))
    h = jfile(STATE + "/HALT")
    if h is not None:
        pauses.append(dict(h, end=None))
    for p in pauses:
        p["ts"] = float(p.get("ts") or 0) or (p["end"] or NOW)
    g["pauses"] = pauses
    rdir = STATE + "/removed"
    g["removed"] = sorted(((os.path.getmtime(os.path.join(rdir, a)), a) for a in os.listdir(rdir)), key=lambda x: x[0]) \
        if os.path.isdir(rdir) else []
    g["rejected"] = [x for x in g["gw"] if x.get("op") == "mr" and x.get("code") != 0]
    g["msgs"] = messages(g["gw"])
    return g


def messages(gw):
    """Counts per (sender, recipient): from the board's messages table where there is one, else
    from the gateway log (op msg)."""
    pairs = collections.Counter()
    db = STATE + "/board.db"
    if os.path.exists(db):
        try:
            c = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=2)
            if c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='messages'").fetchone():
                for s, r, n in c.execute("SELECT sender, recipient, count(*) FROM messages GROUP BY 1, 2"):
                    pairs[(str(s), str(r))] += n
                c.close()
                return pairs
            c.close()
        except sqlite3.Error:
            pass
    for x in gw:
        if x.get("op") == "msg" and x.get("code") == 0:
            to = re.match(r"to (\S+):", str(x.get("detail", "")))      # detail is "to <agent>: <text>"
            pairs[(x.get("agent"), to.group(1) if to else "?")] += 1
    return pairs


def state_of(g):
    if not g["started"]:
        return "NOT STARTED", "idle"
    if g["done_at"] or len(g["landed"]) == len(STATEMENTS):
        return "COMPLETE", "good"
    if g["stalled"] is not None:
        return "STALLED", "bad"
    if g["deadline"] and NOW >= g["deadline"]:
        return "TIME UP", "bad"
    if any(p["end"] is None for p in g["pauses"]):
        return "PAUSED", "warn"
    if g["beat"] and NOW - g["beat"] > 30:
        return "GATEWAY DOWN", "warn"
    return "RUNNING", "live"


def window(g):
    t0 = g["started"]
    ends = [g["done_at"], (g["stalled"] or {}).get("ts")]
    end = next((t for t in ends if t), None)
    if end is None:
        end = min(NOW, g["deadline"]) if g["deadline"] else NOW
        if g["beat"] and NOW - g["beat"] > 30:
            end = g["beat"]
    last = [x.get("ts", 0) for k in ("acts", "gw", "merges") for x in g[k][-1:]]
    end = max([end] + last)
    return t0, max(end, t0 + 60)


# ------------------------------------------------------------------ render
def pct(t, t0, t1):
    return max(0.0, min(100.0, (t - t0) * 100.0 / (t1 - t0)))


def timeline(g):
    if not g["started"]:
        return '<p class="muted">The run has not been launched yet, so there is no timeline.</p>'
    t0, t1 = window(g)
    total = t1 - t0
    step = next(s for s in (60, 120, 300, 600, 900, 1800, 3600, 7200, 14400) if total / s <= 8)
    ticks = "".join('<span class="tick" style="left:%.3f%%">%d:%02d</span>' % (pct(t0 + k, t0, t1), k // 3600, k % 3600 // 60)
                    for k in range(0, int(total) + 1, step))
    over = []
    for p in g["pauses"]:
        a, b = p["ts"], p["end"] or t1
        over.append('<i class="band pause" style="left:%.3f%%;width:%.3f%%" title="%s"></i>' % (
            pct(a, t0, t1), max(0.4, pct(b, t0, t1) - pct(a, t0, t1)),
            e("paused %s, %s: %s" % (clock(a), span(b - a), p.get("reason", "")))))
    for r in g["resumes"]:
        b = float(r.get("ts") or 0)
        a = b - float(r.get("down_s") or 0)
        if b:
            over.append('<i class="band down" style="left:%.3f%%;width:%.3f%%" title="%s"></i>' % (
                pct(a, t0, t1), max(0.4, pct(b, t0, t1) - pct(a, t0, t1)), e("down %s, resumed %s" % (span(b - a), clock(b)))))
    if g["stalled"] is not None:
        over.append('<i class="rule stall" style="left:%.3f%%" title="%s"></i>' % (
            pct(g["stalled"]["ts"], t0, t1), e("stalled at %s" % clock(g["stalled"]["ts"]))))
    if g["deadline"] and t0 <= g["deadline"] <= t1:
        over.append('<i class="rule deadline" style="left:%.3f%%" title="deadline %s"></i>' % (
            pct(g["deadline"], t0, t1), e(clock(g["deadline"]))))
    rows = []
    # the run lane: when each statement became done
    seen, marks = set(), []
    for m in g["merges"]:
        new = [s for s in m.get("landed", []) if s not in seen]
        seen.update(new)
        if new:
            marks.append('<b class="m done" style="left:%.3f%%" title="%s">%s</b>' % (
                pct(m["ts"], t0, t1), e("%s done at %s (+%s) by %s" % (" ".join(new), clock(m["ts"]), span(m["ts"] - t0),
                                                                   m.get("agent"))), e(" ".join(new))))
    rows.append('<div class="lane run"><div class="who">done</div><div class="track">%s</div></div>' % "".join(marks))
    bins = 48
    for a in AGENTS:
        cnt = [0] * bins
        for x in g["acts"]:
            if x.get("agent") == a and t0 <= x.get("ts", 0) <= t1:
                cnt[min(bins - 1, int((x["ts"] - t0) * bins / total))] += 1
        top = max(cnt) or 1
        cells = "".join('<i class="act" style="left:%.3f%%;width:%.3f%%;opacity:%.2f" title="%d tool calls"></i>' % (
            k * 100.0 / bins, 100.0 / bins, 0.12 + 0.88 * n / top, n) for k, n in enumerate(cnt) if n)
        ms = []
        for m in g["merges"]:
            if m.get("agent") == a:
                ms.append('<b class="m ok" style="left:%.3f%%" title="%s"></b>' % (
                    pct(m["ts"], t0, t1), e("ACCEPTED %s: %s" % (clock(m["ts"]), m.get("title", "")))))
        for x in g["rejected"]:
            if x.get("agent") == a:
                ms.append('<b class="m no" style="left:%.3f%%" title="%s"></b>' % (
                    pct(x["ts"], t0, t1), e("REJECTED %s: %s" % (clock(x["ts"]), x.get("detail", "")))))
        for x in g["acts"]:
            if x.get("agent") == a and x.get("decision") == "block":
                ms.append('<b class="m blk" style="left:%.3f%%" title="%s"></b>' % (
                    pct(x["ts"], t0, t1), e("BLOCKED %s: %s" % (clock(x["ts"]), x.get("reason", "")))))
        for t, who in g["removed"]:
            if who == a:
                ms.append('<i class="gone" style="left:%.3f%%" title="%s"></i>' % (pct(t, t0, t1), e("removed at " + clock(t))))
        rows.append('<div class="lane"><div class="who">%s</div><div class="track">%s%s</div></div>' % (
            e(a), cells, "".join(ms)))
    return ('<div class="tl"><div class="axis"><div class="who"></div><div class="track">%s</div></div>'
            '<div class="lanes">%s<div class="over">%s</div></div></div>'
            '<p class="legend"><span><b class="k ok"></b>accepted merge</span><span><b class="k no"></b>rejected</span>'
            '<span><b class="k blk"></b>blocked action</span><span><i class="k act"></i>tool calls</span>'
            '<span><i class="k pause"></i>paused</span><span><i class="k down"></i>down (before a resume)</span>'
            '<span><i class="k gone"></i>removed</span><span><i class="k stall"></i>stall / deadline</span></p>'
            '<p class="muted">Start %s, axis in h:mm since launch, %s shown. Hover a mark for details.</p>' % (
                ticks, "".join(rows), "".join(over), clock(t0), span(total)))


def table(head, rows, empty):
    if not rows:
        return '<p class="muted">%s</p>' % e(empty)
    return ('<div class="scroll"><table><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>' % (
        "".join("<th>%s</th>" % e(h) for h in head),
        "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % c for c in r) for r in rows)))


def page(g):
    state, tone = state_of(g)
    n, m = len(g["landed"]), len(STATEMENTS)
    t0 = g["started"]
    rel = lambda t: ("+" + span(t - t0)) if t0 and t else ""
    used = ((g["done_at"] or (g["stalled"] or {}).get("ts") or min(NOW, g["deadline"] or NOW)) - t0) if t0 else 0
    done_when = {}
    for mg in g["merges"]:
        for s in mg.get("landed", []):
            done_when.setdefault(s, mg)
    chips = "".join('<li class="%s" title="%s">%s</li>' % (
        "on" if s in g["landed"] else "off",
        e("done %s by %s" % (clock(done_when[s]["ts"]), done_when[s].get("agent")) if s in done_when else "not done"), e(s))
        for s in STATEMENTS)
    merges = []
    prev = set()
    for mg in g["merges"]:
        new = [s for s in mg.get("landed", []) if s not in prev]
        prev |= set(mg.get("landed", []))
        merges.append([e(clock(mg["ts"])), e(rel(mg["ts"])), e(mg.get("agent")), e(mg.get("title")),
                       e(" ".join(new) or "-"), e(len(mg.get("files", [])))])
    rej = [[e(clock(x["ts"])), e(rel(x["ts"])), e(x.get("agent")), e(x.get("detail")),
            e(first_line(x.get("out", ""), "REJECTED"))] for x in g["rejected"]]
    sent, got = collections.Counter(), collections.Counter()
    for (s, r), k in g["msgs"].items():
        sent[s] += k
        for a in (AGENTS if r == "all" else [r]):
            if a != s:
                got[a] += k
    people = []
    for a in AGENTS:
        acts = [x for x in g["acts"] if x.get("agent") == a]
        dec = collections.Counter(x.get("decision") for x in acts)
        gw = [x for x in g["gw"] if x.get("agent") == a]
        sql = [x for x in gw if x.get("op") == "sql"]
        ts = [x.get("ts", 0) for x in acts + gw]
        people.append([e(a), e(profile_of(a)), e(len(acts)), e(dec.get("refuse", 0)), e(dec.get("block", 0)),
                       e("%d / %d" % (len(sql), sum(1 for x in sql if x.get("code") != 0))),
                       e(sum(1 for x in g["merges"] if x.get("agent") == a)),
                       e(sum(1 for x in g["rejected"] if x.get("agent") == a)),
                       e("%d / %d" % (sent[a], got[a])),
                       e(clock(min(ts)) if ts else "-"), e(clock(max(ts)) if ts else "-"),
                       e("removed %s" % clock(next(t for t, w in g["removed"] if w == a)))
                       if any(w == a for _, w in g["removed"]) else ""])
    pauses = []
    for p in g["pauses"]:
        inp = p.get("input") or {}
        what = inp.get("command") or inp.get("file_path") or inp.get("url") or json.dumps(inp)[:300] \
            if isinstance(inp, dict) else str(inp)
        pauses.append([e(clock(p["ts"])), e(clock(p["end"]) if p["end"] else "still paused"),
                       e(span((p["end"] or NOW) - p["ts"])), e(p.get("agent", "?")), e(p.get("by", "")),
                       e(p.get("tool", "")), "<code>%s</code>" % e(str(what)[:600]), e(p.get("reason", ""))])
    removals = [[e(clock(t)), e(rel(t)), e(a)] for t, a in g["removed"]]
    resumes = [[e(clock(r.get("ts"))), e(span(r.get("down_s"))),
                e(", ".join("%s=%s" % (k, v) for k, v in r.items() if k not in ("ts", "down_s"))[:300])]
               for r in g["resumes"]]
    events = []
    if g["stalled"] is not None:
        st = g["stalled"]
        events.append("<li><b>STALLED</b> at %s (%s): %s</li>" % (
            e(clock(st["ts"])), e(rel(st["ts"])),
            e("no merge accepted for %s min" % st["stall_min"] if "stall_min" in st else "no progress")))
    total_msgs = sum(g["msgs"].values())
    pairs = [[e(s), e(r), e(k)] for (s, r), k in sorted(g["msgs"].items())]
    budget = CFG.get("budget_min")
    facts = [("done", "%d of %d" % (n, m)), ("state", state),
             ("time used", span(used) + (" of %s min" % budget if budget else "")),
             ("merges", "%d accepted, %d rejected" % (len(g["merges"]), len(g["rejected"]))),
             ("tool calls", str(len(g["acts"]))), ("pauses", str(len(g["pauses"]))),
             ("removals", str(len(g["removed"]))), ("resumes", str(len(g["resumes"]))),
             ("messages", str(total_msgs))]
    body = """<header>
<div><h1>Run report <span class="sess">%(sess)s</span></h1>
<p class="muted">%(when)s &middot; %(agents)d agents &middot; written %(now)s</p></div>
<div class="big %(tone)s"><span class="n">%(n)d of %(m)d</span><span class="s">%(state)s</span></div>
</header>
<div class="bar"><i style="width:%(w).1f%%"></i></div>
<ul class="chips">%(chips)s</ul>
<dl class="facts">%(facts)s</dl>
%(events)s
<section><h2>Timeline</h2>%(tl)s</section>
<section><h2>Accepted merges</h2>%(merges)s</section>
<section><h2>Rejected merge requests</h2>%(rej)s</section>
<section><h2>Agents</h2>%(people)s
<p class="muted">refused: not available in the sandbox; blocked: a rule violation that paused the team. board: requests / failed.
msgs: sent / received.</p></section>
<section><h2>Pauses</h2>%(pauses)s</section>
<section><h2>Removals</h2>%(removals)s</section>
<section><h2>Resumes</h2>%(resumes)s</section>
<section><h2>Messages</h2>%(pairs)s</section>
""" % dict(
        sess=e(CFG.get("session", "")), now=e(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(NOW))),
        when=e("launched " + time.strftime("%Y-%m-%d %H:%M", time.localtime(t0)) if t0 else "not launched yet"),
        agents=len(AGENTS), tone=tone, n=n, m=m, state=e(state), w=100.0 * n / max(1, m), chips=chips,
        facts="".join("<div><dt>%s</dt><dd>%s</dd></div>" % (e(k), e(v)) for k, v in facts),
        events='<ul class="events">%s</ul>' % "".join(events) if events else "",
        tl=timeline(g),
        merges=table(["time", "since start", "agent", "title", "made done", "files"], merges, "No merge accepted yet."),
        rej=table(["time", "since start", "agent", "title", "reason"], rej, "No merge request rejected."),
        people=table(["agent", "profile", "tool calls", "refused", "blocked", "board", "merged", "rejected", "msgs",
                      "first", "last", ""], people, "No agents."),
        pauses=table(["paused", "cleared", "length", "agent", "by", "tool", "blocked action", "reason"], pauses,
                     "The team was never paused."),
        removals=table(["time", "since start", "agent"], removals, "Nobody was removed."),
        resumes=table(["resumed", "down for", "detail"], resumes, "The run was never resumed after a crash."),
        pairs=table(["from", "to", "messages"], pairs, "No messages."))
    return "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n" \
           "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" \
           "<title>%s</title>\n<style>%s</style></head>\n<body><main>%s</main>\n<script>%s</script></body></html>\n" % (
               e("Run report %s: %d of %d done" % (CFG.get("session", ""), n, m)), CSS, body, JS)


CSS = """
:root{--bg:#f7f7f5;--fg:#1d1f21;--mut:#6b6f76;--card:#fff;--line:#e2e2de;--ok:#1f9d55;--no:#d64545;--warn:#c98a00;
--live:#2b6cb0;--act:#2b6cb0;--pause:rgba(201,138,0,.22);--down:rgba(107,111,118,.28);--chip:#ecece8}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#15171a;--fg:#e6e6e3;--mut:#9aa0a8;--card:#1e2125;
--line:#30343a;--ok:#3ccf7a;--no:#ff6b6b;--warn:#f0b429;--live:#63a4ff;--act:#63a4ff;--pause:rgba(240,180,41,.22);
--down:rgba(154,160,168,.25);--chip:#2a2e33}}
:root[data-theme=dark]{--bg:#15171a;--fg:#e6e6e3;--mut:#9aa0a8;--card:#1e2125;--line:#30343a;--ok:#3ccf7a;--no:#ff6b6b;
--warn:#f0b429;--live:#63a4ff;--act:#63a4ff;--pause:rgba(240,180,41,.22);--down:rgba(154,160,168,.25);--chip:#2a2e33}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:1100px;margin:0 auto;padding:20px 16px 48px}
h1{font-size:1.5rem;margin:0}h2{font-size:1.1rem;margin:0 0 10px}
.sess{color:var(--mut);font-weight:500}.muted{color:var(--mut);font-size:.85rem}
header{display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap}
.big{text-align:right}.big .n{display:block;font-size:2.2rem;font-weight:700;line-height:1}
.big .s{font-weight:600;letter-spacing:.04em;font-size:.85rem}
.good .s{color:var(--ok)}.bad .s{color:var(--no)}.warn .s{color:var(--warn)}.live .s{color:var(--live)}.idle .s{color:var(--mut)}
.bar{height:8px;background:var(--chip);border-radius:4px;margin:14px 0 10px;overflow:hidden}
.bar i{display:block;height:100%;background:var(--ok)}
.chips{list-style:none;padding:0;margin:0 0 14px;display:flex;flex-wrap:wrap;gap:6px}
.chips li{padding:2px 10px;border-radius:12px;font-size:.85rem;background:var(--chip);color:var(--mut)}
.chips li.on{background:var(--ok);color:#fff}
.facts{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:8px;margin:0 0 18px}
.facts div{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:8px 10px}
.facts dt{color:var(--mut);font-size:.75rem;text-transform:uppercase;letter-spacing:.05em}.facts dd{margin:0;font-weight:600}
.events{background:var(--card);border-left:4px solid var(--no);padding:8px 12px 8px 28px;border-radius:6px}
section{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px;margin:0 0 14px}
.scroll{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:.88rem}
th,td{text-align:left;padding:5px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--mut);font-weight:600;white-space:nowrap}td code{font-size:.8rem;word-break:break-all}
.tl{--who:4.5rem;font-size:.8rem}
.axis,.lane{display:grid;grid-template-columns:var(--who) 1fr;align-items:center}
.who{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;padding-right:6px;color:var(--mut)}
.track{position:relative;height:26px}.axis .track{height:18px;border-bottom:1px solid var(--line)}
.lane .track{border-bottom:1px dashed var(--line)}
.lanes{position:relative}.over{position:absolute;top:0;bottom:0;left:var(--who);right:0;pointer-events:none}
.tick{position:absolute;bottom:2px;transform:translateX(-50%);color:var(--mut);white-space:nowrap}
.tick:first-child{transform:none}
/* lane marks live in a .track: the legend's swatches share their names (.k.act, .k.gone) */
.track .act{position:absolute;top:8px;height:10px;background:var(--act);border-radius:1px}
.m{position:absolute;top:6px;width:14px;height:14px;margin-left:-7px;border-radius:50%;border:2px solid var(--card)}
.m.ok{background:var(--ok)}.m.no{background:var(--no);border-radius:2px;transform:rotate(45deg)}
.m.blk{background:var(--warn);border-radius:2px}
.m.done{width:auto;height:auto;border-radius:4px;background:var(--ok);color:#fff;padding:0 4px;font-weight:600;
transform:translateX(-50%);margin-left:0;top:4px;font-size:.72rem;border:0;white-space:nowrap}
.track .gone{position:absolute;top:0;bottom:0;right:0;background:repeating-linear-gradient(45deg,transparent 0 4px,var(--down) 4px 8px)}
.band{position:absolute;top:0;bottom:0}.band.pause{background:var(--pause)}
.band.down{background:repeating-linear-gradient(135deg,var(--down) 0 6px,transparent 6px 12px)}
.rule{position:absolute;top:0;bottom:0;width:0;border-left:2px dashed var(--no)}.rule.deadline{border-color:var(--mut)}
.legend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:.8rem;color:var(--mut);margin:10px 0 4px}
.legend span{display:inline-flex;align-items:center;gap:5px}
.k{display:inline-block;width:12px;height:12px;border-radius:50%}.k.ok{background:var(--ok)}
.k.no{background:var(--no);border-radius:2px;transform:rotate(45deg)}.k.blk{background:var(--warn);border-radius:2px}
.k.act{background:var(--act);border-radius:1px;opacity:.6}.k.pause{background:var(--pause);border-radius:2px}
.k.down{background:var(--down);border-radius:2px}.k.gone{background:var(--down);border-radius:2px}
.k.stall{border-left:2px dashed var(--no);border-radius:0;width:2px}
#theme{position:fixed;top:10px;right:10px;background:var(--card);color:var(--fg);border:1px solid var(--line);
border-radius:16px;padding:3px 10px;font:inherit;font-size:.8rem;cursor:pointer}
@media (max-width:600px){main{padding:12px 10px 40px}.tl{--who:3rem}.big .n{font-size:1.7rem}header{padding-right:56px}}
@media print{#theme{display:none}}
"""

JS = """(function(){var b=document.createElement('button');b.id='theme';b.type='button';b.textContent='theme';
b.title='switch between the light and the dark theme';b.onclick=function(){var r=document.documentElement;
var dark=r.dataset.theme?r.dataset.theme==='dark':matchMedia('(prefers-color-scheme: dark)').matches;
r.dataset.theme=dark?'light':'dark';};document.body.appendChild(b);})();"""


def main(argv):
    out = R + "/report.html"
    if argv[:1] == ["-o"] and len(argv) == 2:
        out = argv[1]
    elif argv:
        sys.exit("usage: report.py [-o FILE]")
    out = os.path.abspath(out)
    text = page(gather())
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.rename(tmp, out)
    print("report: %s" % out)


if __name__ == "__main__":
    main(sys.argv[1:])
