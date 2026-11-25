"""What state is this run in, and can it be resumed?

  runstate.py           print one line: the state word, then what it means
  runstate.py --resume  check the files a resume relies on, give back the time the run was down,
                        record it in records/resumes.jsonl and print what was done. Used by
                        launch.sh --resume; exits non-zero (and changes nothing) if a check fails.
  runstate.py --lock    say whether a process holds the gateway's lock on config.json; exit 0 if none
  runstate.py --stop-gateway   stop every gateway that holds that lock, however it was started
                        (used by teardown.sh)
  runstate.py --left    print the process ids whose working directory is in an agent workspace

A gateway holds an exclusive lock (flock) on config.json for as long as it serves, so "the lock
is free" is the certain test that no gateway is serving this directory.

States: new (never launched), running (its tmux session is up), complete (every statement is
on main), ended (it ran out of time or stalled, then its session went away), INTERRUPTED
(started, not complete, not ended, and its session is gone: a crash, a reboot, or a teardown).
"""
import fcntl
import json
import os
import signal
import sqlite3
import subprocess
import sys
import time

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = R + "/state"
CFG = json.load(open(R + "/config.json"))


def num(name):
    """A number kept in a state file, or None."""
    try:
        return float(open("%s/%s" % (STATE, name)).read().strip())
    except (OSError, ValueError):
        return None


CFGFILE = os.path.realpath(R + "/config.json")


def lock_state():
    """("free", []) when no process holds the gateway's lock on config.json, ("held", pids) when
    one does, (None, []) when that cannot be told."""
    try:
        f = open(CFGFILE)
    except OSError:
        return None, []
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(f, fcntl.LOCK_UN)
        return "free", []
    except BlockingIOError:
        return "held", lock_holders()
    except OSError:
        return None, []
    finally:
        f.close()


def has_open(pid, path):
    try:
        return any(os.path.realpath("/proc/%d/fd/%s" % (pid, fd)) == path for fd in os.listdir("/proc/%d/fd" % pid))
    except OSError:
        return False


def cmdline(pid):
    try:
        return open("/proc/%d/cmdline" % pid).read().split("\0")
    except OSError:
        return []


def lock_holders():
    """The processes that hold a flock on config.json: named by /proc/locks, and confirmed by an
    open file of theirs that is this config.json (an inode number alone could be another file's)."""
    try:
        ino = str(os.stat(CFGFILE).st_ino)
        lines = open("/proc/locks").read().splitlines()
    except OSError:
        return []
    pids = {int(f[4]) for f in (l.split() for l in lines)
            if len(f) >= 6 and f[1] == "FLOCK" and f[4].isdigit() and f[5].rsplit(":", 1)[-1] == ino}
    return sorted(p for p in pids if has_open(p, CFGFILE))


def is_gateway(pid):
    return any(a.endswith("gateway.py") for a in cmdline(pid))


def session_up():
    return subprocess.run(["tmux", "has-session", "-t", "=" + CFG["session"]],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def last_beat():
    """When the run was last alive: the gateway's heartbeat, else the newest file it wrote."""
    beat = num("heartbeat")
    if beat is not None:
        return beat, "heartbeat"
    times = [os.path.getmtime(os.path.join(d, n)) for d in (STATE, R + "/records")
             if os.path.isdir(d) for n in os.listdir(d) if os.path.isfile(os.path.join(d, n))]
    return (max(times), "newest file in state/ and records/ (no heartbeat)") if times else (None, "nothing")


def ended_at(beat):
    """Why the run had already ended when it last beat, or None if it was still going."""
    if os.path.exists(STATE + "/STALLED"):
        return "it had STALLED"
    deadline = num("deadline")
    try:        # a pause stops the clock: boss.sh resume gives all of it back when it is cleared
        paused_since = float(json.load(open(STATE + "/HALT"))["ts"])
    except (OSError, ValueError, KeyError, TypeError):
        paused_since = None
    if deadline is not None and beat is not None and paused_since is not None:
        deadline += max(0.0, beat - paused_since)
    if deadline is not None and beat is not None and deadline <= beat:
        return "it had run out of time"
    return None


def classify():
    if not os.path.exists(STATE + "/started"):
        return "new", "not launched yet: ./launch.sh starts it"
    if session_up():
        return "running", "its tmux session %s is up" % CFG["session"]
    if os.path.exists(STATE + "/DONE"):
        return "complete", "every statement is on main; the session is stopped"
    why = ended_at(last_beat()[0])
    if why:
        return "ended", ("%s before its session went away; there is nothing to resume. Put it away with "
                         "./teardown.sh --archive%s" % (why, " (or reopen it: harness/boss.sh unstall, then "
                                                         "./launch.sh --resume)" if "STALLED" in why else ""))
    return "INTERRUPTED", ("started, not complete, and its tmux session is gone. Continue it with "
                           "./launch.sh --resume, or put it away with ./teardown.sh --archive")


def problems():
    """What a resume relies on. Each entry is a reason not to trust this directory."""
    bad = []
    for a in CFG["agents"]:
        if not os.path.isdir("%s/ws/%s/.git" % (R, a)):
            bad.append("workspace ws/%s is missing" % a)
    if not os.path.isdir(R + "/central.git"):
        bad.append("central.git is missing")
    elif subprocess.run(["git", "--git-dir", R + "/central.git", "rev-parse", "--verify", "-q", "refs/heads/main"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        bad.append("central.git has no main branch")
    for name in ("started", "deadline"):
        if num(name) is None:
            bad.append("state/%s is missing or not a number" % name)
    try:
        if not isinstance(json.load(open(STATE + "/landed.json")), list):
            raise ValueError
    except (OSError, ValueError):
        bad.append("state/landed.json is missing or not a JSON list")
    if os.path.exists(STATE + "/board.db"):
        try:
            db = sqlite3.connect("file:%s/board.db?mode=ro" % STATE, uri=True, timeout=5)
            res = db.execute("PRAGMA quick_check").fetchone()[0]
            db.close()
            if res != "ok":
                bad.append("the board fails its integrity check: " + res)
        except sqlite3.Error as e:
            bad.append("the board cannot be read: %s" % e)
    else:
        bad.append("state/board.db is missing")
    lock, holders = lock_state()
    if lock == "held":
        bad.append("the lock on config.json is held%s: a gateway may still be serving this directory. "
                   "Stop it with ./teardown.sh" % (" by pid " + ", ".join(map(str, holders)) if holders else ""))
    elif lock is None:      # the lock cannot be tested: fall back to the heartbeat, a guess
        beat, _ = last_beat()
        if beat is not None and time.time() - beat < 10:
            bad.append("the heartbeat is %.0f s old: a gateway may still be serving this directory"
                       % (time.time() - beat))
    return bad


def shift(name, by):
    v = num(name)
    if v is None:
        return None
    with open("%s/%s.tmp" % (STATE, name), "w") as f:
        f.write(str(v + by))
    os.rename("%s/%s.tmp" % (STATE, name), "%s/%s" % (STATE, name))
    return v + by


def resume():
    word, why = classify()
    if word != "INTERRUPTED":
        sys.exit("cannot resume: the run is %s: %s" % (word, why))
    bad = problems()
    if bad:
        sys.exit("cannot resume, the work directory does not look intact:\n  " + "\n  ".join(bad))
    now = time.time()
    beat, source = last_beat()
    down = max(0.0, now - beat)
    paused = os.path.exists(STATE + "/HALT")
    before = num("deadline")
    # While paused, the clock is given back by boss.sh resume when the pause is cleared, and
    # that already covers the time down. Giving it here as well would count it twice.
    given = 0.0 if paused else down
    after = shift("deadline", given)
    shift("stall_from", given)          # time down is not time without progress
    with open(STATE + "/heartbeat", "w") as f:  # a second resume before the gateway beats must not give it again
        f.write("%.3f\n" % now)
    removed = sorted(os.listdir(STATE + "/removed")) if os.path.isdir(STATE + "/removed") else []
    rec = dict(ts=round(now, 3), down_s=round(down, 1), given_back_s=round(given, 1), last_beat=beat,
               beat_from=source, paused=paused, deadline_before=before, deadline_after=after, removed=removed,
               landed=json.load(open(STATE + "/landed.json")))
    with open(R + "/records/resumes.jsonl", "a") as f:
        f.write(json.dumps(rec) + "\n")
    print("resuming: the run was down %d min %d s (last beat from the %s)" % (down // 60, down % 60, source))
    if paused:
        print("the team is still PAUSED: review state/HALT, then harness/boss.sh resume gives back the time")
    else:
        print("deadline moved later by %d s; time left: %d min" % (given, (after - now) // 60))
    if removed:
        print("removed earlier, not restarted: " + " ".join(removed))


def stop_gateway():
    """Stop the gateways that hold this directory's lock. A holder that is not a gateway is left
    alone: --lock and teardown.sh report it."""
    lock, holders = lock_state()
    for p in holders:
        if is_gateway(p):
            try:
                os.kill(p, signal.SIGTERM)
                print("gateway stopped (pid %d)" % p)
            except OSError as e:
                print("gateway (pid %d) not stopped: %s" % (p, e))


def left():
    """Processes still working in an agent workspace (agent sessions take a few seconds to exit)."""
    ws = os.path.realpath(R + "/ws") + os.sep
    out = []
    for p in os.listdir("/proc"):
        try:
            if p.isdigit() and (os.readlink("/proc/%s/cwd" % p) + os.sep).startswith(ws):
                out.append(p)
        except OSError:
            pass
    return out


def lock_text():
    lock, holders = lock_state()
    if lock == "free":
        return 0, "free: no process holds the gateway's lock on config.json"
    if lock is None:
        return 1, "unknown: the lock on config.json cannot be tested"
    return 1, "the gateway's lock on config.json is held by %s" % (", ".join(
        "pid %d (%s)" % (p, " ".join(" ".join(cmdline(p)).split())[:80]) for p in holders) or "a process that cannot be named")


if __name__ == "__main__":
    if sys.argv[1:] == ["--resume"]:
        resume()
    elif sys.argv[1:] == ["--stop-gateway"]:
        stop_gateway()
    elif sys.argv[1:] == ["--left"]:
        print(" ".join(left()))
    elif sys.argv[1:] == ["--lock"]:
        rc, text = lock_text()
        print(text)
        sys.exit(rc)
    else:
        word, why = classify()
        print("%s: %s" % (word, why))
