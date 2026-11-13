#!/usr/bin/python3
"""PermissionDenied hook: Claude Code's auto-mode classifier (the LLM action monitor)
refused a tool call. Fail closed: record it and pause the whole team."""
import json
import os
import sys
import time

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT = sys.argv[1]
d = json.load(sys.stdin)
reason = "auto-mode classifier denied %s: %s" % (d.get("tool_name"), str(d.get("reason"))[:500])
with open(R + "/records/actions.jsonl", "a") as f:
    f.write(json.dumps(dict(ts=round(time.time(), 3), agent=AGENT, session=d.get("session_id"),
                            tool=d.get("tool_name"), input=d.get("tool_input"), decision="block",
                            reason=reason)) + "\n")
try:
    fd = os.open(R + "/state/HALT", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    os.write(fd, json.dumps(dict(ts=time.time(), agent=AGENT, by="classifier", tool=d.get("tool_name"),
                                 reason=reason, input=d.get("tool_input"))).encode())
    os.close(fd)
except FileExistsError:
    pass
