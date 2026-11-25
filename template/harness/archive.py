"""Seal a stopped run into one file: team-archive-<session>-<YYYYmmdd>-<HHMMSS>.tar.gz

  usage: archive.py --check DIR   say whether DIR can take the archive; changes nothing
         archive.py DIR           write the archive into DIR (teardown.sh --archive runs this
                                  after the run has been stopped)

The file holds only what lasts: the bare repository (central.git, the work), the records (the
audit) and STATUS.txt, whose first line says what the run came to. Two files are added to the
records: run.json, the run's facts that lived in state/ and config.json (when it started and
ended, what was done, the agents and their profiles), so that report.py can show the archived
run truthfully, and report.html, that page as it was when the run was put away. Workspaces, the board, the
tools and the settings stay out: they are the stale-but-plausible parts a later reader could
mistake for live state. Everything is under one folder named like the file.

Progress goes to stderr; the full path of the file is the only thing printed on stdout. The
archive is read back before this exits 0, and teardown.sh deletes nothing unless it does.
"""
import glob
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import report  # noqa: E402

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = json.load(open(R + "/config.json"))
STATEMENTS = CFG["task"]["statements"]
STATE = R + "/state"


def say(msg):
    print(msg, file=sys.stderr, flush=True)


def read(path, default=""):
    try:
        return open(path).read().strip()
    except OSError:
        return default


def when(ts):
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(float(ts)))
    except (TypeError, ValueError):
        return "unknown"


def destination(arg):
    """The folder the archive goes into, or exit with the reason it cannot."""
    if not os.path.isdir(R + "/central.git"):
        sys.exit("archive: nothing to archive in %s: there is no central.git (setup.sh never ran, or the run "
                 "was already purged)" % R)
    dest = os.path.realpath(arg)
    if not os.path.isdir(dest):
        sys.exit("archive: no such folder: %s (create it first; nothing was stopped or deleted)" % arg)
    if dest == R or dest.startswith(R + os.sep):
        sys.exit("archive: %s is inside the work directory. The archive must live outside it, so that a search "
                 "of the work directory cannot mistake an old run for live state. Nothing was stopped or deleted."
                 % arg)
    if not os.access(dest, os.W_OK | os.X_OK):
        sys.exit("archive: cannot write to %s (nothing was stopped or deleted)" % dest)
    return dest


def status_text(verify_ok, verify_out, stopped):
    try:
        got = [s for s in json.load(open(STATE + "/landed.json")) if s in STATEMENTS]
    except (OSError, ValueError):
        got = []
    finished = len(got) == len(STATEMENTS)
    head = "%s run, stopped %s, %d of %d done, %s" % ("finished" if finished else "abandoned", when(stopped),
                                                       len(got), len(STATEMENTS),
                                                       "verified" if verify_ok else "not verified")
    main = subprocess.run(["git", "rev-parse", "main"], cwd=R + "/central.git", capture_output=True,
                          text=True).stdout.strip() or "unknown"
    removed = sorted(os.listdir(STATE + "/removed")) if os.path.isdir(STATE + "/removed") else []
    flags = [f for f in ("DONE", "HALT", "STALLED") if os.path.exists(STATE + "/" + f)]
    reopened = len(glob.glob(R + "/records/stalled.*.json"))      # stalls reopened with boss.sh unstall
    resumes = read(R + "/records/resumes.jsonl").splitlines()
    sent = 0
    for line in read(R + "/records/gateway.jsonl").splitlines():
        if '"op": "msg"' in line:
            try:
                sent += json.loads(line).get("code") == 0
            except ValueError:
                pass
    lines = [
        head,
        "",
        "This is a sealed archive of a finished or stopped run of a tmux agent team. Nothing in it is live:",
        "the agents, the gateway and the board were stopped and deleted when it was made.",
        "",
        "session:          %s" % CFG["session"],
        "work directory:   %s (the run's files there were deleted)" % R,
        "agents:           %s" % " ".join(CFG["agents"]),
        "budget:           %s min" % CFG.get("budget_min"),
        "started:          %s" % (when(read(STATE + "/started")) if read(STATE + "/started") else "never launched"),
        "stopped:          %s" % when(stopped),
        "finished at:      %s" % (when(read(STATE + "/DONE")) if "DONE" in flags else "-"),
        "statements:       %s" % " ".join(STATEMENTS),
        "done on main:     %s" % (" ".join(got) or "-"),
        "not done:         %s" % (" ".join(s for s in STATEMENTS if s not in got) or "-"),
        "main:             %s" % main,
        "removed helpers:  %s" % (" ".join(removed) or "-"),
        "state at stop:    %s" % (" ".join(flags) or "-"),
        "stalls:           %d%s" % (reopened + ("STALLED" in flags),
                                     " (%d reopened with boss.sh unstall)" % reopened if reopened else ""),
        "resumes:          %d" % len([r for r in resumes if r.strip()]),
        "messages:         %d (team msg; each is in records/gateway.jsonl)" % sent,
    ]
    if "HALT" in flags:
        lines += ["", "The team was paused when it stopped. The blocked action:", read(STATE + "/HALT")[:2000]]
    lines += ["", "harness/verify.py when the archive was made (%s):" % ("passed" if verify_ok else "failed")]
    lines += ["  " + l for l in verify_out.splitlines()[-40:]] or ["  (no output)"]
    lines += ["",
              "Contents:",
              "  STATUS.txt    this file",
              "  central.git/  the bare repository; the result is its main branch: git clone central.git <dir>",
              "  records/      every tool call (actions.jsonl), gateway request (gateway.jsonl) and merge",
              "                (merges.jsonl) of the run, every message (gateway.jsonl, op msg), any",
              "                reviewed pauses (halt.*.json), stalls reopened with boss.sh unstall",
              "                (stalled.*.json) and resumes after a crash (resumes.jsonl);",
              "                run.json, the run's facts (started, ended, done, agents, profiles); and",
              "                report.html, the run's page. Rebuild the page with any copy of the template:",
              "                python3 harness/report.py --records <this folder>/records",
              ""]
    return "\n".join(lines)


def write(dest):
    stopped = time.time()
    session = re.sub(r"[^A-Za-z0-9._-]", "_", str(CFG["session"]))
    name = "team-archive-%s-%s" % (session, time.strftime("%Y%m%d-%H%M%S", time.localtime(stopped)))
    final = os.path.join(dest, name + ".tar.gz")
    if os.path.exists(final):
        sys.exit("archive: %s already exists; it is not overwritten" % final)
    say("verifying main on a fresh checkout (harness/verify.py)...")
    try:
        p = subprocess.run([sys.executable, R + "/harness/verify.py"], capture_output=True, text=True,
                           timeout=60 + len(STATEMENTS) * CFG["task"].get("check_timeout_s", 180))
        verify_ok, verify_out = p.returncode == 0, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        verify_ok, verify_out = False, "verify.py timed out"
    status = status_text(verify_ok, verify_out, stopped)
    say(status.splitlines()[0])
    # what state/ and config.json knew, for report.py once they are gone; and the page itself
    facts = dict(report.live_facts(R, stopped), verified=verify_ok)
    added = {name + "/STATUS.txt": status.encode(), name + "/records/run.json": json.dumps(facts, indent=1).encode()}
    try:
        added[name + "/records/report.html"] = report.render(R + "/records", facts).encode()
    except Exception as e:      # the page is a convenience: without it the archive is still whole
        say("archive: the run's page was not written (%r); report.py --records can write it later" % (e,))
    try:
        with open(final, "xb") as f, tarfile.open(fileobj=f, mode="w:gz") as tar:
            for arc, data in added.items():
                info = tarfile.TarInfo(arc)
                info.size, info.mtime, info.mode = len(data), int(stopped), 0o644
                tar.addfile(info, io.BytesIO(data))
            tar.add(R + "/central.git", arcname=name + "/central.git")
            if os.path.isdir(R + "/records"):
                tar.add(R + "/records", arcname=name + "/records",
                        filter=lambda ti: None if ti.name in added else ti)
        with tarfile.open(final) as tar:          # read it back before anything is deleted
            names = tar.getnames()
        if not all(n in names for n in [name + "/central.git/HEAD"] + list(added)):
            raise OSError("the archive does not read back complete")
    except FileExistsError:
        sys.exit("archive: %s already exists; it is not overwritten" % final)
    except (OSError, tarfile.TarError) as e:
        try:
            os.unlink(final)
        except OSError:
            pass
        sys.exit("archive: could not write %s: %s" % (final, e))
    print(final)


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--check":
        destination(args[1])
    elif len(args) == 1 and not args[0].startswith("-"):
        write(destination(args[0]))
    else:
        sys.exit(__doc__.split("\n\n")[1])
