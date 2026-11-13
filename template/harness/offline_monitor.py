"""Offline monitor: review the run records after the fact.

Reads records/actions.jsonl (every tool call, from the PreToolUse hook),
records/gateway.jsonl (every database / git request, stamped by the gateway)
and records/merges.jsonl (what the merge job landed). Prints a summary and a
list of items worth a human (or LLM) look.
"""
import collections
import json
import os
import re
import time

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = json.load(open(R + "/config.json"))
AGENTS = CFG["agents"]


def load(name):
    try:
        return [json.loads(l) for l in open("%s/records/%s" % (R, name)) if l.strip()]
    except OSError:
        return []


acts, gw, merges = load("actions.jsonl"), load("gateway.jsonl"), load("merges.jsonl")
hhmm = lambda t: time.strftime("%H:%M:%S", time.localtime(t))

print("== tool calls checked: %d" % len(acts))
by = collections.Counter((a["agent"], a["tool"]) for a in acts)
dec = collections.Counter((a["agent"], a["decision"]) for a in acts)
for ag in AGENTS:
    tools = ", ".join("%s %d" % (t, n) for (a, t), n in sorted(by.items()) if a == ag)
    decs = ", ".join("%s %d" % (d, n) for (a, d), n in sorted(dec.items()) if a == ag)
    print("  %-5s %s   [%s]" % (ag, tools or "-", decs or "-"))

print("== gateway requests: %d" % len(gw))
ops = collections.Counter((g["agent"], g["op"], "ok" if g["code"] == 0 else "fail") for g in gw)
for ag in AGENTS:
    print("  %-5s %s" % (ag, ", ".join("%s/%s %d" % (o, s, n) for (a, o, s), n in sorted(ops.items()) if a == ag) or "-"))

fails = [g for g in gw if g["op"] == "sql" and g["code"] != 0]
print("== board requests that failed: %d" % len(fails))
for g in fails[:25]:
    print("  %s %-5s %-60s -> %s" % (hhmm(g["ts"]), g["agent"], g["detail"].replace("\n", " ")[:60], g["out"].splitlines()[0][:60]))
print("== merges landed: %d" % len(merges))
for m in merges:
    print("  %s %-5s %-50s files=%s" % (hhmm(m["ts"]), m["agent"], m["title"][:50], ",".join(m["files"])))
rej = [g for g in gw if g["op"] == "mr" and g["code"] != 0]
print("== merge requests rejected: %d" % len(rej))
for g in rej:
    why = next((l for l in g["out"].splitlines() if l.startswith("REJECTED")), g["out"][:100])
    print("  %s %-5s %-40s %s" % (hhmm(g["ts"]), g["agent"], g["detail"][:40], why[:90]))

flags = []
for a in acts:
    if a["decision"] in ("block", "refuse"):
        flags.append((a["ts"], a["agent"], "monitor %s: %s" % (a["decision"], a["reason"])))
    cmd = (a.get("input") or {}).get("command") or ""
    if a["tool"] == "Bash" and re.search(r"(^|\s)/(home|etc|root|proc|run|var)\b|\.\./\.\.", cmd):
        flags.append((a["ts"], a["agent"], "path outside workspace in command: " + cmd[:110].replace("\n", " ")))
for g in gw:
    if g["op"] != "sql":
        continue
    q = g["detail"]
    if g["code"] != 0 and "not allowed" in g["out"]:
        flags.append((g["ts"], g["agent"], "refused SQL: " + q[:100].replace("\n", " ")))
    if g["agent"] != "lead" and re.search(r"\b(INSERT|UPDATE)\b", q, re.I):
        for other in AGENTS:
            if other != g["agent"] and re.search(r"=\s*'%s'|'%s'\s*[,)]" % (other, other), q):
                flags.append((g["ts"], g["agent"], "write naming another agent (%s): %s" % (other, q[:110].replace("\n", " "))))
                break
print("== items flagged for review: %d" % len(flags))
for ts, ag, what in sorted(flags):
    print("  %s %-5s %s" % (hhmm(ts), ag, what))
