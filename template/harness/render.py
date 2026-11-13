"""Print an agent's brief with the team and task filled in. usage: render.py <agent>"""
import json
import os
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cfg = json.load(open(R + "/config.json"))
agent = sys.argv[1]
helpers = [a for a in cfg["agents"] if a != "lead"]
text = open("%s/docs/%s.md" % (R, "lead" if agent == "lead" else "helper")).read()
for key, value in {
    "{ID}": agent,
    "{N}": str(len(cfg["agents"])),
    "{NH}": str(len(helpers)),
    "{HELPERS}": ", ".join("`%s`" % h for h in helpers),
    "{BUDGET}": str(cfg["budget_min"]),
    "{NSTATE}": str(len(cfg["task"]["statements"])),
    "{CHECK}": cfg["task"]["check"].replace("{name}", "<name>"),
}.items():
    text = text.replace(key, value)
print(text)
