#!/usr/bin/python3
"""Stop hook: the harness's "keep going". An agent may not stop until the finish
line is reached (every statement on main), time runs out, or the team is paused."""
import json
import os
import sys
import time

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = R + "/state"
AGENT = sys.argv[1]
json.load(sys.stdin)

if os.path.exists(STATE + "/DONE") or os.path.exists(STATE + "/HALT") \
        or os.path.exists("%s/removed/%s" % (STATE, AGENT)):
    sys.exit(0)
try:
    left = float(open(STATE + "/deadline").read()) - time.time()
except OSError:
    sys.exit(0)
if left <= 0:
    sys.exit(0)

# Loop guard: an agent that stops 6 times within 90 s is let go.
p = "%s/stops.%s" % (STATE, AGENT)
now = time.time()
try:
    ts = [t for t in json.load(open(p)) if now - t < 90]
except (OSError, ValueError):
    ts = []
ts.append(now)
json.dump(ts, open(p, "w"))
if len(ts) >= 6:
    sys.exit(0)

mins = int(left // 60)
if AGENT == "lead":
    why = ("[harness] The run is not finished: not every statement is on main. Time left: %d min. Keep going: "
           "check `team status` and the board, unblock or move helpers, update announce. If there is nothing to "
           "do right now, run `team wait 60` and check again." % mins)
else:
    why = ("[harness] The run is not finished. Time left: %d min. Keep going: re-read the lead's orders in the "
           "database, claim open work or split work that is too hard. If nothing is open, run `team wait 45` "
           "and check again." % mins)
print(json.dumps({"decision": "block", "reason": why}))
