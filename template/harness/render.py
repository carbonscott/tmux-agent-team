"""Print an agent's brief with the team and task filled in. usage: render.py <agent> [--resume]

With --resume it prints the brief for an agent that rejoins an interrupted run: the opening
paragraph of docs/<role>-rejoin.md replaces the brief's first paragraph, and each of its
sections replaces the brief's section with the same heading. The rest is the usual brief."""
import json
import os
import re
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cfg = json.load(open(R + "/config.json"))
agent = sys.argv[1]
role = "lead" if agent == "lead" else "helper"
helpers = [a for a in cfg["agents"] if a != "lead"]
task = cfg["task"]
text = open("%s/docs/%s.md" % (R, role)).read()


def split(t):
    """The text before the first '## ' heading, and the sections keyed by their heading line."""
    parts = re.split(r"(?m)^(?=## )", t)
    return parts[0], [(p.split("\n", 1)[0], p) for p in parts[1:]]


if "--resume" in sys.argv[2:]:
    head, secs = split(text)
    new_head, new_secs = split(open("%s/docs/%s-rejoin.md" % (R, role)).read())
    head = new_head.rstrip("\n") + "\n\n" + head.split("\n\n", 1)[1]
    new_secs = dict(new_secs)
    text = head + "".join(new_secs.get(h, s) for h, s in secs)
removed = set(os.listdir(R + "/state/removed")) if os.path.isdir(R + "/state/removed") else set()

# The check command. With task.checks, statements may each have their own: the brief then
# points to a list of them, appended at the end.
own = {s: c for s, c in (task.get("checks") or {}).items() if c and s in task["statements"]}
if own:
    check = "the statement's own check command, listed under Checks at the end"
    rest = [s for s in task["statements"] if s not in own]
    lines = ["", "## Checks", "",
             "Each statement is done when its check exits 0 in the repository root. The merge job "
             "runs the same command.", ""]
    lines += ["- `%s`: `%s`" % (s, own[s]) for s in task["statements"] if s in own]
    if rest:
        lines.append("- every other statement: `%s`" % task["check"].replace("{name}", "<name>"))
    tail = "\n".join(lines) + "\n"
else:
    check = "`%s`" % task["check"].replace("{name}", "<name>")
    tail = ""

for key, value in {
    "{ID}": agent,
    "{N}": str(len(cfg["agents"])),
    "{NH}": str(len(helpers)),
    "{HELPERS}": ", ".join("`%s`" % h for h in helpers),
    "{BACK}": ", ".join("`%s`" % h for h in helpers if h not in removed) or "none",
    "{GONE}": ", ".join("`%s`" % h for h in helpers if h in removed) or "none",
    "{BUDGET}": str(cfg["budget_min"]),
    "{NSTATE}": str(len(task["statements"])),
    "{CHECK}": check,
}.items():
    text = text.replace(key, value)
print(text.rstrip("\n") + "\n" + tail)
