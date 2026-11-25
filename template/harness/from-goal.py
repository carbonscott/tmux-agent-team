"""Turn a make-goal contract (.goal/<slug>.json) into the team's task.

  python3 harness/from-goal.py <contract.json>
      print the plan as JSON and write nothing
  python3 harness/from-goal.py <contract.json> --apply --allowed <regex> [<regex> ...] [--replace-statements]
      write the plan into config.json and task/seed/STATEMENTS.md (only before setup.sh). Text that
      was in STATEMENTS.md before is kept below the generated statements, under "## Earlier text of
      this file", unless --replace-statements is given.

It never writes task/probe/: it cannot know a right answer. A probe whose files the new allowed
paths freeze cannot answer the new task, so it is removed; any other probe is kept for the boss
to confirm. Without one, test_gateway.sh skips the step that shows the check can tell a right
answer from a wrong one.

Each done_when item that names a command in backticks becomes a statement, and that command
becomes the statement's own check (task.checks). The merge job judges a check by its exit
status alone, so the command must fail when the item is not met. Items without a command, and
the contract's own bookkeeping (its ledger and claims files under .goal/), stay with the boss:
they are listed under "skipped". An exploratory contract, or one with no command in any item,
is refused, because the merge job would have nothing to run.

The allowed paths are not guessed from the guardrails' prose: give them with --allowed.
"""
import argparse
import json
import os
import re
import shutil
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STOP = set("""a an the of to in on at by for and or is are be been being must should will all every each
any no not this that these those with from into under over its it file files line lines holds hold
contains contain single exists exist passes pass printing printed print output proven shows show
showing has have least most than""".split())
# Commands that exit 0 whatever they print: as a check they would accept anything.
ALWAYS_ZERO = {"cat", "echo", "printf", "ls", "wc", "head", "tail", "find", "du", "tree", "true", "date", "pwd"}


def die(msg, code=2):
    print("from-goal: " + msg, file=sys.stderr)
    sys.exit(code)


def slug(s):
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")[:30].strip("_")


def command_of(item):
    """The command an item names: the first backtick span after its last "proven by", or else
    its first backtick span. None if it names none."""
    tail = re.split(r"proven by", item)[-1] if "proven by" in item else item
    spans = re.findall(r"`([^`\n]+)`", tail) or re.findall(r"`([^`\n]+)`", item)
    spans = [x.strip() for x in spans if x.strip()]
    return spans[0] if spans else None


def name_of(item, taken):
    """A short name from the item's own words: the stem of the first path it names (out/alpha.txt
    gives alpha), or else its first three words that carry meaning. Unique within the plan."""
    head = re.split(r",?\s*proven by", item)[0]
    prose = re.sub(r"`[^`]*`", " ", head)
    base = ""
    for p in re.findall(r"[\w-]+(?:/[\w.*-]+)+|\b[\w-]+\.[A-Za-z][A-Za-z0-9]{0,4}\b", prose):
        stem = slug(os.path.splitext(os.path.basename(p.rstrip("/*")))[0])
        if len(stem) >= 2:
            base = stem
            break
    if not base:
        words = [w for w in re.findall(r"[a-z0-9]+", prose.lower()) if w not in STOP]
        base = slug("_".join(words[:3]))
    base = base or "statement"
    name, n = base, 2
    while name in taken:
        name, n = "%s_%d" % (base, n), n + 1
    return name


def plan(contract):
    if not isinstance(contract, dict):
        die("the contract is not a JSON object")
    if contract.get("type") == "exploratory":
        die("this contract is exploratory: its end states are findings or decisions, not commands the "
            "merge job can run. Run it under /goal in one session instead of with the team.")
    items = contract.get("done_when")
    if not isinstance(items, list) or not items:
        die("the contract has no done_when list")
    statements, skipped, taken = [], [], set()
    for item in items:
        if not isinstance(item, str):
            skipped.append(dict(text=json.dumps(item), why="not a sentence"))
            continue
        cmd = command_of(item)
        if cmd is None:
            skipped.append(dict(text=item, why="names no command: the boss proves it, not the merge job"))
        elif ".goal/" in item:
            skipped.append(dict(text=item, why="the contract's own bookkeeping under .goal/: the boss keeps it"))
        else:
            name = name_of(item, taken)
            taken.add(name)
            statements.append(dict(name=name, check=cmd, text=item))
    if not statements:
        die("no done_when item names a command in backticks, so there is nothing the merge job can check")
    return dict(goal=contract.get("goal", ""), statements=statements, skipped=skipped,
                guardrails=[g for g in contract.get("guardrails") or [] if isinstance(g, str)])


def warnings(p):
    out = []
    for s in p["statements"]:
        first = s["check"].split()[0]
        if first in ALWAYS_ZERO and "|" not in s["check"] and "&&" not in s["check"]:
            out.append("the check of `%s` is `%s`, which exits 0 whatever it prints. The merge job judges by exit "
                       "status only: change task.checks.%s in config.json to a command that fails when the item "
                       "is not met (test, grep -q, a script)." % (s["name"], s["check"], s["name"]))
    return out


def statements_md(p, source, allowed):
    names = ", ".join("`%s`" % s["name"] for s in p["statements"])
    out = ["# Statements", "",
           "This task comes from a goal contract (`%s`)." % source + (" Its goal: %s" % p["goal"] if p["goal"] else ""),
           "",
           "There are %d statements: %s. A statement is done when its check command exits 0 in the "
           "repository root. The merge job runs that command on every merge." % (len(p["statements"]), names), ""]
    for s in p["statements"]:
        out += ["## `%s`" % s["name"], "", s["text"], "", "Check: `%s`" % s["check"], ""]
    out += ["## Guardrails", ""]
    out += ["- %s" % g for g in p["guardrails"]] or ["- None stated in the contract."]
    out += ["", "The merge job accepts changes only to paths that match one of these regular expressions; "
            "everything else is frozen:", ""]
    out += ["- `%s`" % a for a in allowed]
    out += ["", "The contract's other end states (%d) belong to the boss, not to the team." % len(p["skipped"]), ""]
    return "\n".join(out)


MARK = "<!-- written by harness/from-goal.py"
KEPT = "## Earlier text of this file"


def nested(text):
    """Markdown text with its headings two levels deeper (code blocks left alone), to sit under KEPT."""
    out, code = [], False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            code = not code
        out.append("##" + line if not code and re.match(r"#{1,4} ", line) else line)
    return "\n".join(out)


def statements_file(path, generated, source, replace):
    """The new STATEMENTS.md, and a line saying what happened to the text that was there."""
    old = open(path).read() if os.path.exists(path) else ""
    head = "%s from the contract %s; text above the heading \"%s\" is generated -->\n" % (MARK, source, KEPT[3:])
    if old.startswith(MARK):           # written by an earlier --apply: keep what that one kept
        i = old.find("\n" + KEPT + "\n")
        kept = "" if replace or i < 0 else old[i + 1:]
        did = "rewritten" + (" (its kept earlier text dropped: --replace-statements)" if replace and i >= 0 else
                             ", with the earlier text it kept" if kept else "")
    elif old.strip() and replace:
        kept, did = "", "replaced: the %d lines that were there are dropped (--replace-statements)" % len(old.splitlines())
    elif old.strip():
        kept = (KEPT + "\n\n<!-- kept by harness/from-goal.py --apply -->\nThis was the text of this file before the "
                "goal contract was applied. It may describe the task in more detail than the contract does, or belong "
                "to another task: keep what applies, and delete the rest before ./setup.sh.\n\n" + nested(old).strip()
                + "\n")
        did = ("written from the contract; the %d lines that were there are kept below it, under \"%s\" "
               "(--replace-statements drops them)" % (len(old.splitlines()), KEPT[3:]))
    else:
        kept, did = "", "written from the contract"
    return head + generated.rstrip("\n") + "\n" + ("\n" + kept if kept else ""), did


def probe_note(allowed):
    """Deal with task/probe/ for the new task, and say what was done."""
    d = os.path.join(R, "task", "probe")
    files = sorted(os.path.relpath(os.path.join(w, f), os.path.join(d, side))
                   for side in ("good", "bad") for w, _, fs in os.walk(os.path.join(d, side)) for f in fs)
    write = ("Write task/probe/good/ (the files of a right answer to one of these statements, laid out as in the "
             "repository) and task/probe/bad/ (a wrong answer to the same statement) before ./setup.sh; see "
             "references/goal.md. Without them test_gateway.sh skips the step that shows the check can tell them apart.")
    if not os.path.isdir(d):
        return "note: there is no task/probe/. " + write
    if files and not any(any(re.fullmatch(a, f) for a in allowed) for f in files):
        shutil.rmtree(d)
        return ("removed task/probe/: its files (%s) lie outside the new allowed paths, so it cannot answer this task "
                "(it was the example task's). %s" % (", ".join(sorted(set(files))), write))
    return ("note: kept task/probe/ (%s). from-goal.py cannot check it: make sure good/ is a right and bad/ a wrong "
            "answer to one of these statements." % (", ".join(sorted(set(files))) or "empty"))


def apply(p, source, allowed, replace=False):
    for d in ("central.git", "ws"):
        if os.path.exists(os.path.join(R, d)):
            die("setup.sh has already run here (%s/ exists), so the task is fixed. Apply the contract to a fresh "
                "copy of the template, or run ./teardown.sh --purge first." % d)
    for a in allowed:
        try:
            re.compile(a)
        except re.error as e:
            die("--allowed %r is not a regular expression: %s" % (a, e))
    cfg_path = os.path.join(R, "config.json")
    cfg = json.load(open(cfg_path))
    task = cfg.setdefault("task", {})
    task["statements"] = [s["name"] for s in p["statements"]]
    task["checks"] = {s["name"]: s["check"] for s in p["statements"]}
    task["allowed_paths"] = list(allowed)
    task.pop("attempted_if", None)
    # Every statement has its own check; a statement added later by hand without one must fail.
    task["check"] = 'echo "statement {name} has no entry in task.checks" >&2; exit 1'
    seed = os.path.join(R, "task", "seed")
    os.makedirs(seed, exist_ok=True)
    text, did = statements_file(os.path.join(seed, "STATEMENTS.md"), statements_md(p, source, allowed), source, replace)
    with open(os.path.join(seed, "STATEMENTS.md"), "w") as f:
        f.write(text)
    with open(cfg_path + ".tmp", "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.rename(cfg_path + ".tmp", cfg_path)
    print("wrote config.json (task: %d statements, their checks, %d allowed path patterns)"
          % (len(p["statements"]), len(allowed)))
    print("task/seed/STATEMENTS.md: " + did)
    if any(re.fullmatch(a, "STATEMENTS.md") for a in allowed):
        print("WARNING: an allowed pattern matches STATEMENTS.md, so agents may rewrite their own statements")
    extra = sorted(n for n in os.listdir(seed) if n not in ("STATEMENTS.md", ".gitignore"))
    if extra:
        print("note: task/seed/ also holds %s. It all becomes the starting repository; remove what belongs to "
              "the example task." % ", ".join(extra))
    print(probe_note(allowed))
    if os.path.exists(os.path.join(R, "task/install.sh")):
        print("note: task/install.sh installs the check's tools; make it install what these checks need, or delete it")
    print("next: ./setup.sh")


def main():
    ap = argparse.ArgumentParser(description="Turn a make-goal contract into the team's task.")
    ap.add_argument("contract")
    ap.add_argument("--apply", action="store_true", help="write config.json and task/seed/STATEMENTS.md")
    ap.add_argument("--allowed", nargs="+", metavar="REGEX", help="paths agents may change (with --apply)")
    ap.add_argument("--replace-statements", action="store_true",
                    help="drop the text that was in task/seed/STATEMENTS.md (by default it is kept below)")
    a = ap.parse_args()
    if a.allowed and not a.apply:
        die("--allowed is used only with --apply")
    if a.replace_statements and not a.apply:
        die("--replace-statements is used only with --apply")
    if a.apply and not a.allowed:
        die("--apply needs --allowed <regex> ...: the paths agents may change (everything else is frozen)")
    try:
        contract = json.load(open(a.contract))
    except (OSError, ValueError) as e:
        die("cannot read the contract: %s" % e)
    p = plan(contract)
    for w in warnings(p):
        print("WARNING: " + w, file=sys.stderr)
    if a.apply:
        apply(p, os.path.basename(a.contract), a.allowed, a.replace_statements)
    else:
        print(json.dumps(p, indent=2))


if __name__ == "__main__":
    main()
