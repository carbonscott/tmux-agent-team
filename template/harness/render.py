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
# An unwalled run: the Sandbox limit above describes walls this run does not have. Say so, and that
# its rules still hold (the monitor checks them), so no agent reads "no network" as a fact here.
if cfg.get("sandbox", True) is False:
    tail += ("\n## This run is unwalled\n\n"
             "The owner turned the shell sandbox off for this run (config.json `\"sandbox\": false`). The "
             "Sandbox limit above is no longer a wall: your shell can technically reach the network and "
             "files outside your workspace. The rules still hold all the same. Keep to your workspace, use "
             "only `team` for the board and `main`, and use no network unless your profile below says so. "
             "The action monitor still checks every command and pauses the team on a violation.\n")
# An agent on the remote profile (only in a run with the sandbox off) may reach other machines:
# its brief says so, and which of the limits above still hold.
if ((cfg.get("agent_profiles") or {}).get(agent) or cfg.get("profile")) == "remote":
    tail += ("\n## Remote machines\n\n"
             "Your profile is `remote`. This run's shell sandbox is off, and your shell may reach other "
             "machines: you may run `ssh`, `scp`, `sftp`, `rsync`, `curl`, `wget` and the `bridge` CLI. That "
             "replaces the limits above only for those commands, and only for the machines your task "
             "names. Never connect back to this machine with them (`localhost`, its own name): that pauses "
             "the team. Do not give a shell command `allowed_domains`: it is refused, since the network is "
             "already open. Every other rule above still holds: your workspace only, no `tmux`, `claude`, "
             "`sudo` or `git push`, nothing under `.ssh`, `.claude`, the harness, the records or the state. "
             "Write what you do on a remote machine in the board, so the team and the boss can follow it.\n")
print(text.rstrip("\n") + "\n" + tail)
