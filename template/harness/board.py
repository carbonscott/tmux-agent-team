"""Print the run state and the team's board. Read-only. Used by board.sh."""
import json
import os
import sqlite3
import sys
import time

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W = int(os.environ.get("COLUMNS", "200"))


def show(db, title, sql):
    print("-- " + title)
    try:
        for row in db.execute(sql).fetchall():
            print((" | ".join("" if v is None else str(v).replace("\n", " ") for v in row))[:W])
    except sqlite3.Error as e:
        print("   (%s)" % e)


try:
    left = int((float(open(R + "/state/deadline").read()) - time.time()) // 60)
except OSError:
    left = "?"
try:
    done = " ".join(json.load(open(R + "/state/landed.json")))
except (OSError, ValueError):
    done = ""
if os.path.exists(R + "/state/DONE"):
    took = (float(open(R + "/state/DONE").read()) - float(open(R + "/state/started").read())) / 60
    print("== RUN COMPLETE in %.1f min  done on main: %s" % (took, done or "-"))
else:
    print("== %s  time left: %s min  done on main: %s" % (time.strftime("%H:%M:%S"), left, done or "-"))
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
