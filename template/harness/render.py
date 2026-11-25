"""Print an agent's brief with the team and task filled in. usage: render.py <agent>"""
import json
import os
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cfg = json.load(open(R + "/config.json"))
agent = sys.argv[1]
helpers = [a for a in cfg["agents"] if a != "lead"]
task = cfg["task"]
text = open("%s/docs/%s.md" % (R, "lead" if agent == "lead" else "helper")).read()

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
    "{BUDGET}": str(cfg["budget_min"]),
    "{NSTATE}": str(len(task["statements"])),
    "{CHECK}": check,
}.items():
    text = text.replace(key, value)
print(text.rstrip("\n") + "\n" + tail)
