"""Print the run state and the team's board. Read-only. Used by board.sh."""
import json
import os
import sqlite3
import sys
import time
import unicodedata

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W = int(os.environ.get("COLUMNS", "200"))
HIDDEN = {"Cc", "Cf", "Zl", "Zp", "Cs", "Co", "Cn"}     # as in gateway.py: never put raw on the boss's screen


def visible(s):
    """s with every control or format character but newline and tab written as an escape (\\x1b, \\r)."""
    return "".join(("\\r" if c == "\r" else "\\x%02x" % ord(c) if ord(c) < 256 else "\\u%04x" % ord(c))
                   if c not in "\n\t" and unicodedata.category(c) in HIDDEN else c for c in s)


def show(db, title, sql):
    print("-- " + title)
    try:
        for row in db.execute(sql).fetchall():
            print((" | ".join("" if v is None else visible(str(v)).replace("\n", " ") for v in row))[:W])
    except sqlite3.Error as e:
        print("   (%s)" % e)


if "--messages" in sys.argv:      # boss.sh messages: every message, oldest first
    try:
        db = sqlite3.connect("file:%s/state/board.db?mode=ro" % R, uri=True)
        rows = db.execute("SELECT id, ts, sender, recipient, body FROM messages ORDER BY id").fetchall()
    except sqlite3.Error:
        rows = []
    for i, ts, snd, rcp, body in rows:
        print("#%d %s UTC  %s -> %s: %s" % (i, ts, snd, rcp, visible(body).replace("\n", "\n    ")))
    print("(%d message%s)" % (len(rows), "" if len(rows) == 1 else "s"))
    sys.exit(0)

try:
    left = int((float(open(R + "/state/deadline").read()) - time.time()) // 60)
except OSError:
    left = "?"
try:
    done = " ".join(json.load(open(R + "/state/landed.json")))
except (OSError, ValueError):
    done = ""
if os.path.exists(R + "/state/DONE"):
    sys.path.insert(0, R + "/harness")
    import runclock     # running time: the pauses and the time down before a resume do not count
    run, paused, down = runclock.used(R + "/records", float(open(R + "/state/started").read()),
                                      float(open(R + "/state/DONE").read()))
    print("== RUN COMPLETE in %.1f min%s  done on main: %s" % (run / 60, " (clock stopped: paused %.1f min, down %.1f min)"
                                                               % (paused / 60, down / 60) if paused or down else "", done or "-"))
else:
    print("== %s  time left: %s min  done on main: %s" % (time.strftime("%H:%M:%S"), left, done or "-"))
stall_min = json.load(open(R + "/config.json")).get("stall_min") or 0
if os.path.exists(R + "/state/STALLED"):
    print("== STALLED: no merge was accepted for %s min (stall_min). The run is over; what landed stays on main."
          % stall_min)
elif stall_min and not os.path.exists(R + "/state/DONE"):
    try:   # the stall clock is shown to the boss only, so agents are not tempted to land filler to reset it
        idle = (time.time() - float(open(R + "/state/stall_from").read())) / 60
        print("== stall clock: %.0f of %s min without an accepted merge%s" % (max(0, idle), stall_min,
              " (stopped while paused)" if os.path.exists(R + "/state/HALT") else ""))
    except (OSError, ValueError):
        pass
if os.path.exists(R + "/state/HALT"):
    print("== TEAM PAUSED: " + open(R + "/state/HALT").read()[:400])
if os.path.exists(R + "/state/board.db"):
    db = sqlite3.connect("file:%s/state/board.db?mode=ro" % R, uri=True)
    tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    print("-- tables: " + ", ".join("%s (%d)" % (t, db.execute('SELECT count(*) FROM "%s"' % t).fetchone()[0]) for t in tables))
    if "--brief" in sys.argv:
        sys.exit(0)
    for t in ("assign", "subtasks"):
        if t in tables:
            show(db, t, 'SELECT * FROM "%s"' % t)
    if "notes" in tables:
        show(db, "notes (last 6)", "SELECT * FROM notes ORDER BY rowid DESC LIMIT 6")
if "--brief" in sys.argv:
    sys.exit(0)
try:
    lines = open(R + "/records/merges.jsonl").read().splitlines()[-6:]
    print("-- merges")
    for l in lines:
        d = json.loads(l)
        print(time.strftime("%H:%M:%S", time.localtime(d["ts"])), d["agent"], d["title"][:60], "->", " ".join(d["landed"]))
except OSError:
    pass
