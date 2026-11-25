"""Write one self-contained HTML page that shows what a run did.

  report.py [-o FILE]                  the run in this work directory
  report.py --records DIR [-o FILE]    a run put away by teardown.sh --archive: DIR is the records/
                                       folder of the unpacked archive (any copy of report.py will do)

Without -o the page is report.html in the work directory, or in DIR with --records. The last line
printed is "report: <full path>". It reads and changes nothing else, so it works before a run,
during one, after one, and on an archive. The page loads nothing from the network, and every
piece of text that comes from the records is escaped.

The records say what happened; the run's facts (when it started and ended, what is done, the
agents and their profiles) come from config.json and state/ in a work directory, and from
records/run.json in an archive (archive.py writes it). For an archive older than run.json they
come from its STATUS.txt, which does not say the profiles or when a helper was removed. A work
directory without state/ but with records/run.json is read like an archive.
"""
import calendar
import collections
import glob
import html
import json
import os
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import runclock  # noqa: E402

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOW = time.time()
# the run being shown; use() sets them. AT is "now" for this run: an archived run stopped at its archive time
REC, STATE, F, AGENTS, STATEMENTS, AT = R + "/records", None, {}, [], [], NOW
e = lambda s: html.escape(str(s), quote=True)
USAGE = "usage: report.py [-o FILE] | report.py --records DIR [-o FILE]"


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
    try:
        return time.strftime("%H:%M:%S", time.localtime(float(t))) if t else "-"
    except (TypeError, ValueError, OverflowError, OSError):
        return "-"


def span(s):
    try:
        s = int(max(0, float(s or 0)))
    except (TypeError, ValueError, OverflowError):
        return "-"
    return "%dh %02dm" % (s // 3600, s % 3600 // 60) if s >= 3600 else "%dm %02ds" % (s // 60, s % 60) if s >= 60 \
        else "%ds" % s


def profile_of(a):
    return (F.get("profiles") or {}).get(a) or "unknown"


def first_line(out, prefix):
    lines = str(out).splitlines()
    for i, l in enumerate(lines):
        if l.startswith(prefix):
            more = " ".join(x.strip() for x in lines[i + 1:i + 3] if x.strip())
            return (l + (" " + more if more else ""))[:400]
    return str(out)[:300]


# ------------------------------------------------------------------ the run's facts
def live_facts(root, stopped=None):
    """The run's facts from a work directory's config.json and state/. With stopped (the time the
    run was stopped), also how and when it ended: what archive.py keeps as records/run.json."""
    cfg = json.load(open(root + "/config.json"))
    st = root + "/state"
    try:
        landed = json.load(open(st + "/landed.json"))
    except (OSError, ValueError):
        landed = []
    stalled = jfile(st + "/STALLED")
    if stalled is not None:
        stalled.setdefault("ts", os.path.getmtime(st + "/STALLED"))
    rdir = st + "/removed"
    f = dict(session=cfg.get("session"), agents=cfg["agents"], statements=cfg["task"]["statements"],
             budget_min=cfg.get("budget_min"), stall_min=cfg.get("stall_min"),
             profiles={a: (cfg.get("agent_profiles") or {}).get(a) or cfg.get("profile") or "sealed"
                       for a in cfg["agents"]},
             started=num(st + "/started"), deadline=num(st + "/deadline"), done_at=num(st + "/DONE"),
             heartbeat=num(st + "/heartbeat"), landed=landed if isinstance(landed, list) else [],
             stalled=stalled, halt=jfile(st + "/HALT"),
             removed=sorted([os.path.getmtime(os.path.join(rdir, a)), a] for a in os.listdir(rdir))
             if os.path.isdir(rdir) else [])
    if stopped is not None:
        f.update(version=1, stopped=stopped, end=end_of(f, stopped, f["heartbeat"]))
    return f


def end_of(f, stopped, alive):
    """How and when a stopped run ended: complete, stalled, time up, stopped (before any of those)
    or not started. alive: the last sign of life before the stop. As in runstate.py, a pause in
    progress holds the deadline back."""
    if not f.get("started"):
        return dict(kind="not started", ts=None)
    if f.get("done_at"):
        return dict(kind="complete", ts=f["done_at"])
    if f.get("stalled") is not None:
        return dict(kind="stalled", ts=f["stalled"].get("ts") or alive or stopped)
    alive = min(stopped, alive) if alive else stopped
    deadline, halt = f.get("deadline"), f.get("halt") or {}
    if deadline and isinstance(halt.get("ts"), (int, float)):
        deadline += max(0.0, alive - halt["ts"])
    if deadline and deadline <= alive:
        return dict(kind="time up", ts=deadline)
    return dict(kind="stopped", ts=alive)


def when(s):
    """A time as STATUS.txt writes it ("2026-11-25 01:23:22 UTC"), in seconds, or None."""
    try:
        t = time.strptime(s, "%Y-%m-%d %H:%M:%S %Z")
    except (TypeError, ValueError):
        return None
    return float(calendar.timegm(t) if s.endswith(("UTC", "GMT")) else time.mktime(t))


def status_facts(rec):
    """The facts of an archive older than run.json, from the STATUS.txt beside its records."""
    text = open(os.path.join(os.path.dirname(rec), "STATUS.txt")).read()
    kv = {k.strip(): v.strip() for k, v in re.findall(r"(?m)^([a-z][a-z ]*):[ \t]+(.*)$", text)}
    words = lambda k: [] if kv.get(k, "-") in ("-", "") else kv[k].split()
    flags = words("state at stop")
    budget = re.match(r"([0-9.]+)", kv.get("budget", ""))
    f = dict(session=kv.get("session"), agents=words("agents"), statements=words("statements"),
             budget_min=float(budget.group(1)) if budget else None, stall_min=None, profiles={},
             started=when(kv.get("started")), done_at=when(kv.get("finished at")) if "DONE" in flags else None,
             heartbeat=None, landed=words("done on main"), stalled=None, halt=None,
             removed=[[None, a] for a in words("removed helpers")], version=0, stopped=when(kv.get("stopped")),
             source="STATUS.txt: this archive is older than records/run.json, so the agents' profiles and the "
                    "times of removals are unknown, and the deadline is worked out from the budget")
    if f["budget_min"] is not None and f["budget_min"] == int(f["budget_min"]):
        f["budget_min"] = int(f["budget_min"])
    if "HALT" in flags:
        m = re.search(r"The blocked action:\n(.*)", text)
        try:
            f["halt"] = json.loads(m.group(1)) if m else {}
        except ValueError:
            f["halt"] = {"reason": "see STATUS.txt"}
    # the deadline moves later by every pause and every resume's time given back
    given = sum(float(r.get("given_back_s") or 0) for r in load_from(rec, "resumes.jsonl"))
    pauses = runclock.stops(rec)[0]
    if f["started"] and f["budget_min"]:
        f["deadline"] = f["started"] + f["budget_min"] * 60 + given + sum(b - a for a, b in pauses)
    else:
        f["deadline"] = None
    last = max([x.get("ts", 0) for n in ("actions.jsonl", "gateway.jsonl", "merges.jsonl")
                for x in load_from(rec, n)[-1:]] or [0]) or None
    if "STALLED" in flags:
        f["stalled"] = {"ts": last}
    f["end"] = end_of(f, f["stopped"] or last or NOW, last)
    return f


def load_from(rec, name):
    global REC
    keep, REC = REC, rec
    try:
        return load(name)
    finally:
        REC = keep


def archived_facts(rec):
    """The facts of an archived run: records/run.json, else the archive's STATUS.txt."""
    try:
        f = json.load(open(os.path.join(rec, "run.json")))
        if isinstance(f, dict) and f.get("agents") is not None:
            return f
    except (OSError, ValueError):
        pass
    try:
        return status_facts(rec)
    except OSError:
        sys.exit("report: %s holds no run.json and there is no STATUS.txt beside it, so what the run was "
                 "cannot be told" % rec)


def use(rec, facts, state=None):
    """Show this run: its records folder, its facts, and (in a work directory) its state/."""
    global REC, STATE, F, AGENTS, STATEMENTS, AT
    REC, STATE, F = rec, state, facts
    AGENTS, STATEMENTS = list(facts.get("agents") or []), list(facts.get("statements") or [])
    AT = facts.get("stopped") or NOW


# ------------------------------------------------------------------ gather
def gather():
    g = dict(acts=load("actions.jsonl"), gw=load("gateway.jsonl"), merges=load("merges.jsonl"),
             resumes=load("resumes.jsonl"))
    g["started"], g["deadline"] = F.get("started"), F.get("deadline")
    g["done_at"], g["beat"] = F.get("done_at"), F.get("heartbeat")
    g["landed"] = [s for s in (F.get("landed") or []) if s in STATEMENTS]
    g["stalled"] = F.get("stalled")
    pauses = []
    for p in sorted(glob.glob(REC + "/halt.*.json")):
        h = jfile(p) or {}
        try:
            end = float(os.path.basename(p).split(".")[1])
        except (IndexError, ValueError):
            end = os.path.getmtime(p)
        pauses.append(dict(h, end=end))
    if F.get("halt") is not None:
        pauses.append(dict(F["halt"], end=None))
    for p in pauses:
        p["ts"] = float(p.get("ts") or 0) or (p["end"] or AT)
    g["pauses"] = pauses
    g["removed"] = sorted(((t, a) for t, a in (F.get("removed") or [])), key=lambda x: x[0] or 0)
    g["rejected"] = [x for x in g["gw"] if x.get("op") == "mr" and x.get("code") != 0]
    g["msgs"] = messages(g["gw"])
    # every stall: those reopened with boss.sh unstall (records/stalled.<reopened>.json), then the
    # one in progress, if any
    g["stalls"] = []
    for p in glob.glob(REC + "/stalled.*.json"):
        s = jfile(p) or {}
        try:
            s["reopened"] = float(os.path.basename(p).split(".")[1])
        except (IndexError, ValueError):
            s["reopened"] = os.path.getmtime(p)
        s["ts"] = float(s.get("ts") or s["reopened"])
        g["stalls"].append(s)
    g["stalls"].sort(key=lambda s: s["ts"])
    if g["stalled"] is not None:
        g["stalls"].append(dict(g["stalled"], reopened=None))
    return g


def messages(gw):
    """Counts per (sender, recipient): from the board's messages table where there is one, else
    from the gateway log (op msg)."""
    pairs = collections.Counter()
    db = STATE + "/board.db" if STATE else ""
    if db and os.path.exists(db):
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


ARCHIVED = {"complete": ("COMPLETE", "good"), "stalled": ("STALLED", "bad"), "time up": ("TIME UP", "bad"),
            "not started": ("NOT STARTED", "idle")}


def state_of(g):
    if not g["started"]:
        return "NOT STARTED", "idle"
    if g["done_at"] or len(g["landed"]) == len(STATEMENTS):
        return "COMPLETE", "good"
    if F.get("end"):        # an archived run: as archive.py found it; stopped before any end, it was abandoned
        return ARCHIVED.get(F["end"].get("kind"), ("ABANDONED", "bad"))
    if g["stalled"] is not None:
        return "STALLED", "bad"
    if g["deadline"] and NOW >= g["deadline"]:
        return "TIME UP", "bad"
    if any(p["end"] is None for p in g["pauses"]):
        return "PAUSED", "warn"
    if g["beat"] and NOW - g["beat"] > 30:
        return "GATEWAY DOWN", "warn"
    return "RUNNING", "live"


def ended(g):
    """When the run stopped running: it was done or stalled, its time ran out, it was stopped and
    archived, or it is still going (then now, or the last beat when the gateway is down). Pauses
    and time down are inside it."""
    if F.get("end"):
        return F["end"].get("ts") or AT
    end = g["done_at"] or (g["stalled"] or {}).get("ts")
    if end is None:
        paused = any(p["end"] is None for p in g["pauses"])
        end = NOW if paused or not g["deadline"] else min(NOW, g["deadline"])
        if g["beat"] and NOW - g["beat"] > 30:
            end = min(end, g["beat"])
    return end


def window(g):
    t0 = g["started"]
    last = [x.get("ts", 0) for k in ("acts", "gw", "merges") for x in g[k][-1:]]
    end = max([ended(g)] + last)
    return t0, max(end, t0 + 60)


# ------------------------------------------------------------------ render
def pct(t, t0, t1):
    return max(0.0, min(100.0, (t - t0) * 100.0 / (t1 - t0)))


def lay_out(labels, track):
    """Rows for labels on one lane, so that none overlaps another on a track `track` px wide or
    wider. labels: [(left in %, width in px)] in time order. Returns [(row, shift)] where shift
    is the label's CSS translateX: centred on its moment, or starting or ending there at the
    edges. Widths are estimated on the generous side (7 px a character)."""
    out, ends = [], []
    for x, w in labels:
        at = x * track / 100.0
        shift = "0%" if at - w / 2 < 0 else "-100%" if at + w / 2 > track else "-50%"
        a = at - {"0%": 0, "-100%": w}.get(shift, w / 2)
        row = next((i for i, end in enumerate(ends) if end + 4 <= a), len(ends))
        ends[row:row + 1] = [a + w]
        out.append((row, shift))
    return out


def timeline(g):
    if not g["started"]:
        return '<p class="muted">The run has not been launched yet, so there is no timeline.</p>'
    t0, t1 = window(g)
    total = t1 - t0
    step = next(s for s in (60, 120, 300, 600, 900, 1800, 3600, 7200, 14400) if total / s <= 8)
    ticks = "".join('<span class="tick%s" style="left:%.3f%%">%d:%02d</span>' % (
        " odd" if i % 2 else "", pct(t0 + k, t0, t1), k // 3600, k % 3600 // 60)
        for i, k in enumerate(range(0, int(total) + 1, step)))
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
    for st in g["stalls"]:
        over.append('<i class="rule stall" style="left:%.3f%%" title="%s"></i>' % (
            pct(st["ts"], t0, t1), e("stalled at %s%s" % (clock(st["ts"]), ", reopened at %s" % clock(st["reopened"])
                                                         if st.get("reopened") else ""))))
    if g["deadline"] and t0 <= g["deadline"] <= t1:
        over.append('<i class="rule deadline" style="left:%.3f%%" title="deadline %s"></i>' % (
            pct(g["deadline"], t0, t1), e(clock(g["deadline"]))))
    rows = []
    # the run lane: when each statement became done. Names on a wide screen, numbers keyed below on
    # a phone; each label goes in the first row where it overlaps nothing (see lay_out)
    seen, done = set(), []
    for m in g["merges"]:
        new = [s for s in m.get("landed", []) if s not in seen]
        seen.update(new)
        if new:
            done.append((pct(m["ts"], t0, t1), " ".join(new), m))
    wide = lay_out([(x, len(t) * 7.0 + 12) for x, t, _ in done], 460)
    narrow = lay_out([(x, len(str(k + 1)) * 7.0 + 12) for k, (x, _, _) in enumerate(done)], 260)
    marks, key = [], []
    for k, (x, text, m) in enumerate(done):
        tip = e("%s done at %s (+%s) by %s" % (text, clock(m["ts"]), span(m["ts"] - t0), m.get("agent")))
        marks.append('<i class="dt" style="left:%.3f%%"></i>' % x)
        marks.append('<b class="m done" style="left:%.3f%%;--r:%d;--x:%s" title="%s">%s</b>' % (x, wide[k][0], wide[k][1], tip, e(text)))
        marks.append('<b class="m num" style="left:%.3f%%;--r:%d;--x:%s" title="%s">%d</b>' % (x, narrow[k][0], narrow[k][1], tip, k + 1))
        key.append("<li><b>%d</b> %s <span>+%s, %s</span></li>" % (k + 1, e(text), e(span(m["ts"] - t0)), e(m.get("agent"))))
    rows.append('<div class="lane run" style="--rows:%d;--nrows:%d"><div class="who">done</div><div class="track">%s</div></div>'
                % (1 + max([r for r, _ in wide] or [0]), 1 + max([r for r, _ in narrow] or [0]), "".join(marks)))
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
            if who == a and t:
                ms.append('<i class="gone" style="left:%.3f%%" title="%s"></i>' % (pct(t, t0, t1), e("removed at " + clock(t))))
        rows.append('<div class="lane"><div class="who">%s</div><div class="track">%s%s</div></div>' % (
            e(a), cells, "".join(ms)))
    return ('<div class="tl"><div class="axis"><div class="who"></div><div class="track">%s</div></div>'
            '<div class="lanes">%s<div class="over">%s</div></div></div>'
            '<p class="legend"><span><b class="k ok"></b>accepted merge</span><span><b class="k no"></b>rejected</span>'
            '<span><b class="k blk"></b>blocked action</span><span><i class="k act"></i>tool calls</span>'
            '<span><i class="k pause"></i>paused</span><span><i class="k down"></i>down (before a resume)</span>'
            '<span><i class="k gone"></i>removed</span><span><i class="k stall"></i>stall / deadline</span></p>'
            '%s<p class="muted">Start %s, axis in h:mm since launch, %s shown. Hover a mark for details.</p>' % (
                ticks, "".join(rows), "".join(over), '<ol class="dkey">%s</ol>' % "".join(key) if key else "",
                clock(t0), span(total)))


NARROW = []    # rules for phone width, one set per table; table() adds them, page() puts them in the style


def table(head, rows, empty, name, first=None, wide=()):
    """A table, and how it reads on a phone: each row becomes a block in which every cell is
    labelled with its column's header, column `first` (unlabelled) leads, and the `wide` columns
    take a line of their own. The headers are fixed strings of this file, never record text."""
    if not rows:
        return '<p class="muted">%s</p>' % e(empty)
    sel = ".t-" + name
    for i, h in enumerate(head):
        if i == first:
            NARROW.append("%s td:nth-child(%d){order:-1;flex-basis:100%%;font-weight:600}" % (sel, i + 1))
        elif h:
            NARROW.append("%s td:nth-child(%d)::before{content:%s}" % (sel, i + 1, json.dumps(h + " ")))
        if i in wide:
            NARROW.append("%s td:nth-child(%d){flex-basis:100%%}" % (sel, i + 1))
    return ('<div class="scroll"><table class="t-%s"><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>' % (
        name, "".join("<th>%s</th>" % e(h) for h in head),
        "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % c for c in r) for r in rows)))


def page(g):
    del NARROW[:]
    state, tone = state_of(g)
    n, m = len(g["landed"]), len(STATEMENTS)
    t0 = g["started"]
    rel = lambda t: ("+" + span(t - t0)) if t0 and t else ""
    # the running time: the budget's clock stops while the team is paused and while the run is down
    run_s, paused_s, down_s = runclock.used(REC, t0, ended(g), F.get("halt")) if t0 else (0, 0, 0)
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
                       e("removed %s" % (clock(next(t for t, w in g["removed"] if w == a)) if F.get("removed") and
                                          next(t for t, w in g["removed"] if w == a) else "(time unknown)"))
                       if any(w == a for _, w in g["removed"]) else ""])
    pauses = []
    for p in g["pauses"]:
        inp = p.get("input") or {}
        what = inp.get("command") or inp.get("file_path") or inp.get("url") or json.dumps(inp)[:300] \
            if isinstance(inp, dict) else str(inp)
        pauses.append([e(clock(p["ts"])), e(clock(p["end"]) if p["end"] else "still paused" + (" at the stop" if
                       F.get("end") else "")), e(span((p["end"] or AT) - p["ts"])), e(p.get("agent", "?")), e(p.get("by", "")),
                       e(p.get("tool", "")), "<code>%s</code>" % e(str(what)[:600]), e(p.get("reason", ""))])
    removals = [[e(clock(t) if t else "unknown"), e(rel(t)), e(a)] for t, a in g["removed"]]
    resumes = []
    for r in g["resumes"]:      # a record of launch.sh --resume (runstate.py), in human terms
        given = "none while paused: given back when the pause was cleared" if r.get("paused") else (
            span(r["given_back_s"]) if isinstance(r.get("given_back_s"), (int, float)) else "")
        notes = []
        if r.get("beat_from") and r.get("beat_from") != "heartbeat":
            notes.append("last sign of life: " + str(r["beat_from"]))
        if isinstance(r.get("landed"), list):
            notes.append("done then: %d of %d" % (len(r["landed"]), len(STATEMENTS)))
        if r.get("removed"):
            notes.append("not restarted (removed): " + " ".join(map(str, r["removed"])))
        resumes.append([e(clock(r.get("ts"))), e(span(r.get("down_s"))), e(clock(r.get("last_beat"))), e(given),
                        e(clock(r.get("deadline_after"))), e("; ".join(notes))])
    events = []
    for st in g["stalls"]:
        events.append("<li><b>STALLED</b> at %s (%s): %s%s</li>" % (
            e(clock(st["ts"])), e(rel(st["ts"])),
            e("no merge accepted for %s min" % st["stall_min"] if "stall_min" in st else "no progress"),
            e("; reopened at %s (%s) with boss.sh unstall" % (clock(st["reopened"]), rel(st["reopened"])))
            if st.get("reopened") else ""))
    total_msgs = sum(g["msgs"].values())
    pairs = [[e(s), e(r), e(k)] for (s, r), k in sorted(g["msgs"].items())]
    budget = F.get("budget_min")
    stopped = ", ".join(w + " " + span(v) for w, v in (("paused", paused_s), ("down", down_s)) if v >= 1)
    facts = [("done", "%d of %d" % (n, m)), ("state", state),
             ("running time", span(run_s) + (" of %s min" % budget if budget else ""))]
    facts += [("clock stopped", stopped)] if stopped else []
    facts += [("merges", "%d accepted, %d rejected" % (len(g["merges"]), len(g["rejected"]))),
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
%(source)s%(events)s
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
        sess=e(F.get("session") or ""), now=e(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(NOW))),
        when=e("launched " + time.strftime("%Y-%m-%d %H:%M", time.localtime(t0)) if t0 else "not launched yet") + (
            " &middot; archived " + e(time.strftime("%Y-%m-%d %H:%M", time.localtime(F["stopped"])))
            if F.get("stopped") else ""),
        agents=len(AGENTS), tone=tone, n=n, m=m, state=e(state), w=100.0 * n / max(1, m), chips=chips,
        facts="".join("<div><dt>%s</dt><dd>%s</dd></div>" % (e(k), e(v)) for k, v in facts),
        events='<ul class="events">%s</ul>' % "".join(events) if events else "",
        source='<p class="muted">The run\'s facts come from %s.</p>\n' % e(F["source"]) if F.get("source") else "",
        tl=timeline(g),
        merges=table(["time", "since start", "agent", "title", "made done", "files"], merges, "No merge accepted yet.",
                     "merges", first=3),
        rej=table(["time", "since start", "agent", "title", "reason"], rej, "No merge request rejected.", "rejected",
                  first=3, wide=(4,)),
        people=table(["agent", "profile", "tool calls", "refused", "blocked", "board", "merged", "rejected", "msgs",
                      "first", "last", ""], people, "No agents.", "agents", first=0),
        pauses=table(["paused", "cleared", "length", "agent", "by", "tool", "blocked action", "reason"], pauses,
                     "The team was never paused.", "pauses", wide=(6, 7)),
        removals=table(["time", "since start", "agent"], removals, "Nobody was removed.", "removals"),
        resumes=table(["resumed", "down for", "last beat before", "time given back", "new deadline", "notes"], resumes,
                      "The run was never resumed after a crash.", "resumes", wide=(5,)),
        pairs=table(["from", "to", "messages"], pairs, "No messages.", "messages"))
    return "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n" \
           "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" \
           "<title>%s</title>\n<style>%s</style></head>\n<body><main>%s</main>\n<script>%s</script></body></html>\n" % (
               e("Run report %s: %d of %d done" % (F.get("session") or "", n, m)),
               CSS + "@media (max-width:600px){%s}\n" % "".join(NARROW), body, JS)


# Text on green uses --okbg/--onok, and state words their own --*t colours: each pair is at least
# 4.5:1 in both themes (light: white on #187a44 5.4:1; dark: #0b1f14 on #3ccf7a 8.5:1).
DARK = """--bg:#15171a;--fg:#e6e6e3;--mut:#9aa0a8;--card:#1e2125;--line:#30343a;--ok:#3ccf7a;--no:#ff6b6b;--warn:#f0b429;
--live:#63a4ff;--act:#63a4ff;--pause:rgba(240,180,41,.22);--down:rgba(154,160,168,.25);--chip:#2a2e33;--okbg:#3ccf7a;
--onok:#0b1f14;--okt:#3ccf7a;--not:#ff6b6b;--warnt:#f0b429"""
CSS = """
:root{--bg:#f7f7f5;--fg:#1d1f21;--mut:#62666d;--card:#fff;--line:#e2e2de;--ok:#1f9d55;--no:#d64545;--warn:#c98a00;
--live:#2b6cb0;--act:#2b6cb0;--pause:rgba(201,138,0,.22);--down:rgba(107,111,118,.28);--chip:#ecece8;--okbg:#187a44;
--onok:#fff;--okt:#187a44;--not:#b83a3a;--warnt:#8a5d00}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){DARK}}
:root[data-theme=dark]{DARK}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:1100px;margin:0 auto;padding:20px 16px 48px}
h1{font-size:1.5rem;margin:0}h2{font-size:1.1rem;margin:0 0 10px}
.sess{color:var(--mut);font-weight:500}.muted{color:var(--mut);font-size:.85rem}
header{display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap}
.big{text-align:right}.big .n{display:block;font-size:2.2rem;font-weight:700;line-height:1}
.big .s{font-weight:600;letter-spacing:.04em;font-size:.85rem}
.good .s{color:var(--okt)}.bad .s{color:var(--not)}.warn .s{color:var(--warnt)}.live .s{color:var(--live)}.idle .s{color:var(--mut)}
.bar{height:8px;background:var(--chip);border-radius:4px;margin:14px 0 10px;overflow:hidden}
.bar i{display:block;height:100%;background:var(--ok)}
.chips{list-style:none;padding:0;margin:0 0 14px;display:flex;flex-wrap:wrap;gap:6px}
.chips li{padding:2px 10px;border-radius:12px;font-size:.85rem;background:var(--chip);color:var(--mut)}
.chips li.on{background:var(--okbg);color:var(--onok)}
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
.m.done,.m.num{width:auto;height:18px;line-height:18px;border-radius:4px;background:var(--okbg);color:var(--onok);
padding:0 5px;font-weight:600;transform:translateX(var(--x,-50%));margin-left:0;top:calc(4px + var(--r,0) * 20px);
font-size:.72rem;border:0;white-space:nowrap;z-index:1}
.m.num{display:none;min-width:18px;text-align:center;padding:0 4px}
.lane.run .track{height:calc(var(--rows,1) * 20px + 8px)}
.dt{position:absolute;top:0;bottom:0;border-left:1px solid var(--okbg);opacity:.4}
.dkey{display:none;list-style:none;padding:0;margin:10px 0 2px;flex-wrap:wrap;gap:4px 14px;font-size:.8rem}
.dkey b{display:inline-block;min-width:18px;text-align:center;border-radius:4px;background:var(--okbg);color:var(--onok);
padding:0 4px;margin-right:3px;font-size:.72rem}.dkey span{color:var(--mut)}
.track .gone{position:absolute;top:0;bottom:0;right:0;background:repeating-linear-gradient(45deg,transparent 0 4px,var(--down) 4px 8px)}
.band{position:absolute;top:0;bottom:0}.band.pause{background:var(--pause)}
.band.down{background:repeating-linear-gradient(135deg,var(--down) 0 6px,transparent 6px 12px)}
.rule{position:absolute;top:0;bottom:0;width:0;border-left:2px dashed var(--no)}.rule.deadline{border-color:var(--mut)}
.legend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:.8rem;color:var(--mut);margin:10px 0 4px}
.legend span{display:inline-flex;align-items:center;gap:5px}
.k{display:inline-block;width:12px;height:12px;border-radius:50%}.k.ok{background:var(--ok)}
.k.no{background:var(--no);border-radius:2px;transform:rotate(45deg)}.k.blk{background:var(--warn);border-radius:2px}
.k.act{background:var(--act);border-radius:1px;opacity:.6}.k.pause{background:var(--pause);border-radius:2px}
.k.down{background:repeating-linear-gradient(135deg,var(--down) 0 3px,transparent 3px 6px);border-radius:2px;box-shadow:inset 0 0 0 1px var(--down)}
.k.gone{background:repeating-linear-gradient(45deg,transparent 0 2px,var(--down) 2px 4px);border-radius:2px;box-shadow:inset 0 0 0 1px var(--down)}
.k.stall{border-left:2px dashed var(--no);border-radius:0;width:2px}
#theme{position:absolute;top:10px;right:10px;background:var(--card);color:var(--fg);border:1px solid var(--line);
border-radius:16px;padding:3px 10px;font:inherit;font-size:.8rem;cursor:pointer}
@media (max-width:600px){main{padding:12px 10px 40px}.tl{--who:3rem}.big .n{font-size:1.7rem}header{padding-right:56px}}
@media (max-width:600px){.m.done{display:none}.m.num{display:block}.dkey{display:flex}
.lane.run .track{height:calc(var(--nrows,1) * 20px + 8px)}.tick.odd{display:none}}
@media (max-width:600px){.scroll table,.scroll tbody,.scroll td{display:block}.scroll thead{display:none}
.scroll tr{display:flex;flex-wrap:wrap;gap:1px 14px;padding:7px 0;border-bottom:1px solid var(--line)}
.scroll td{border:0;padding:0}.scroll td:empty{display:none}.scroll td::before{color:var(--mut);font-size:.78rem}}
@media print{#theme{display:none}}
""".replace("DARK", DARK)

JS = """(function(){var b=document.createElement('button');b.id='theme';b.type='button';b.textContent='theme';
b.title='switch between the light and the dark theme';b.onclick=function(){var r=document.documentElement;
var dark=r.dataset.theme?r.dataset.theme==='dark':matchMedia('(prefers-color-scheme: dark)').matches;
r.dataset.theme=dark?'light':'dark';};document.body.appendChild(b);})();"""


def render(rec, facts, state=None):
    """The page for the run with these records and facts (archive.py uses it too)."""
    use(rec, facts, state)
    return page(gather())


def main(argv):
    out = rec = None
    args = list(argv)
    while args:
        a = args.pop(0)
        if a in ("-o", "--records") and args:
            v = args.pop(0)
            out, rec = (v, rec) if a == "-o" else (out, v)
        else:
            sys.exit(USAGE)
    if rec is None and not os.path.isdir(R + "/state") and os.path.isfile(R + "/records/run.json"):
        rec = R + "/records"            # the run's files are gone but its facts were kept
    if rec is None:
        text, default = render(R + "/records", live_facts(R), R + "/state"), R + "/report.html"
    else:
        rec = os.path.abspath(rec)
        if not os.path.isdir(rec):
            sys.exit("report: no such folder: %s" % rec)
        text, default = render(rec, archived_facts(rec)), os.path.join(rec, "report.html")
    out = os.path.abspath(out or default)
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.rename(tmp, out)
    print("report: %s" % out)


if __name__ == "__main__":
    main(sys.argv[1:])
