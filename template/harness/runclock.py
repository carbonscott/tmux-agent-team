"""How long a run has really been running: the time on the wall minus the pauses and the time
it was down before a resume. Both are given back to the deadline, so neither counts against
the budget. Used by report.py and board.py.

  used(records_dir, t0, t1, halt)  ->  (running_s, paused_s, down_s) between t0 and t1

The stops are read from the records: each reviewed pause (records/halt.<cleared>.json, which
holds the time it began), the pause still in progress (halt: the contents of state/HALT, or
None), and each time down (records/resumes.jsonl: down_s seconds before ts). Stops that overlap,
such as a crash while paused, count once, as time down.
"""
import glob
import json
import os


def _f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def stops(records, halt=None, now=None):
    """([(from, to), ...] paused, [(from, to), ...] down). A pause still in progress ends at now."""
    paused, down = [], []
    for p in glob.glob(os.path.join(records, "halt.*.json")):
        end = _f(os.path.basename(p).split(".")[1])
        try:
            start = _f(json.load(open(p)).get("ts"))
        except (OSError, ValueError, AttributeError):
            start = None
        if start is not None and end is not None:
            paused.append((start, end))
    if isinstance(halt, dict) and _f(halt.get("ts")) is not None and now is not None:
        paused.append((_f(halt["ts"]), now))
    try:
        for line in open(os.path.join(records, "resumes.jsonl")):
            try:
                r = json.loads(line)
                b, d = _f(r.get("ts")), _f(r.get("down_s"))
            except (ValueError, AttributeError):
                continue
            if b is not None and d:
                down.append((b - d, b))
    except OSError:
        pass
    return paused, down


def measure(spans, t0, t1):
    """Seconds of [t0, t1] covered by the spans, each moment once."""
    total, reach = 0.0, t0
    for a, b in sorted((max(a, t0), min(b, t1)) for a, b in spans):
        if a < b and b > reach:
            total += b - max(a, reach)
            reach = b
    return total


def used(records, t0, t1, halt=None):
    if t0 is None or t1 is None or t1 <= t0:
        return 0.0, 0.0, 0.0
    paused, down = stops(records, halt, t1)
    stopped, d = measure(paused + down, t0, t1), measure(down, t0, t1)
    return (t1 - t0) - stopped, stopped - d, d
