"""Gateway: the only way out of an agent workspace.

One thread per agent polls that agent's spool directory (ws/<id>/.gw/req).
Identity is the spool a request arrived in, so an agent cannot speak as
another agent unless it can write outside its own workspace (the Bash
sandbox and the action-monitor hook forbid that).

Relays:  sql    -> shared Postgres, connected as the agent's own role
         push   -> central.git refs/heads/agent/<id>   (own branch only)
         mr     -> merge job: merge into main only if the verifier accepts
Every request is appended to records/gateway.jsonl (run records).
"""
import json
import os
import re
import shutil
import subprocess
import threading
import time
import uuid

import psycopg

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = json.load(open(R + "/config.json"))
PW = json.load(open(R + "/harness/secrets/db.json"))
AGENTS = CFG["agents"]
STATEMENTS = CFG["statements"]
CENTRAL = R + "/central.git"
STATE = R + "/state"
RECORDS = R + "/records/gateway.jsonl"
VENV_PY = R + "/tools/venv/bin/python"
PY_BASE = subprocess.run([VENV_PY, "-c", "import sys; print(sys.base_prefix)"],
                         capture_output=True, text=True).stdout.strip()

LOG_LOCK = threading.Lock()
MERGE_LOCK = threading.Lock()
GITENV = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
              GIT_TERMINAL_PROMPT="0")


def log(agent, op, detail, code, ms, out):
    rec = dict(ts=round(time.time(), 3), agent=agent, op=op, detail=detail[:4000],
               code=code, ms=ms, out=out[:1500])
    with LOG_LOCK:
        with open(RECORDS, "a") as f:
            f.write(json.dumps(rec) + "\n")
    print("%s %-4s %-6s code=%s %5dms  %s" % (time.strftime("%H:%M:%S"), agent, op, code, ms,
                                               detail.replace("\n", " ")[:110]), flush=True)


def git(*args, cwd=None):
    p = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, env=GITENV)
    return p.returncode, (p.stdout + p.stderr).strip()


# ---------------------------------------------------------------- run state
def time_left():
    try:
        return float(open(STATE + "/deadline").read()) - time.time()
    except OSError:
        return None


def halted():
    try:
        return json.load(open(STATE + "/HALT"))
    except (OSError, ValueError):
        return None


def landed():
    try:
        return json.load(open(STATE + "/landed.json"))
    except (OSError, ValueError):
        return []


def status_text(agent):
    left = time_left()
    got = landed()
    lines = ["you: %s" % agent,
             "time left: %s" % ("not started" if left is None else "%d min" % max(0, left // 60)),
             "landed on main (%d/%d): %s" % (len(got), len(STATEMENTS), " ".join(got) or "-"),
             "still open: %s" % (" ".join(s for s in STATEMENTS if s not in got) or "-")]
    rc, head = git("rev-parse", "--short", "refs/heads/main", cwd=CENTRAL)
    lines.append("main: %s" % head)
    if os.path.exists(STATE + "/DONE"):
        lines.append("RUN COMPLETE: every statement is on main. You may stop.")
    elif left is not None and left <= 0:
        lines.append("TIME IS UP: the run has ended. Stop working.")
    return "\n".join(lines)


# ---------------------------------------------------------------------- sql
_size = dict(t=0.0, big=False)


def db_too_big():
    if time.time() - _size["t"] > 10:
        try:
            with psycopg.connect(host=CFG["db"]["host"], port=CFG["db"]["port"], dbname=CFG["db"]["name"],
                                 user="postgres", password=PW["admin"], autocommit=True) as c:
                n = c.execute("SELECT pg_database_size(current_database())").fetchone()[0]
            _size.update(t=time.time(), big=n > CFG["db_cap_bytes"])
        except psycopg.Error:
            pass
    return _size["big"]


class Db:
    def __init__(self, agent):
        self.agent, self.conn = agent, None

    def connect(self):
        self.conn = psycopg.connect(host=CFG["db"]["host"], port=CFG["db"]["port"], dbname=CFG["db"]["name"],
                                    user=self.agent, password=PW[self.agent], autocommit=True,
                                    application_name="gw:" + self.agent)

    def run(self, q):
        if self.conn is None or self.conn.closed or self.conn.broken:
            self.connect()
        ro = db_too_big()
        out, code = [], 0
        timer = threading.Timer(CFG["sql_timeout_s"] + 0.5, self.conn.cancel)
        try:
            self.conn.execute("SET statement_timeout = '%ds'" % CFG["sql_timeout_s"])
            self.conn.execute("SET default_transaction_read_only = %s" % ("on" if ro else "off"))
            cur = self.conn.cursor()
            timer.start()
            cur.execute(q)
            while True:
                if cur.description:
                    cols = [d.name for d in cur.description]
                    rows = cur.fetchmany(201)
                    out.append(" | ".join(cols))
                    for r in rows[:200]:
                        out.append(" | ".join("NULL" if v is None else str(v) for v in r))
                    out.append("(%d row%s%s)" % (min(len(rows), 200), "" if len(rows) == 1 else "s",
                                                 ", truncated" if len(rows) > 200 else ""))
                else:
                    out.append(cur.statusmessage or "OK")
                if not cur.nextset():
                    break
        except psycopg.Error as e:
            code = 1
            out.append("ERROR: " + str(e).strip())
        finally:
            timer.cancel()
        try:
            if self.conn.info.transaction_status != psycopg.pq.TransactionStatus.IDLE:
                self.conn.rollback()
                out.append("NOTE: open transaction rolled back; each request must be self-contained.")
        except psycopg.Error:
            self.conn = None
        if ro:
            out.append("NOTE: database is above 256 MiB; writes are refused.")
        text = "\n".join(out)
        return code, text[:20000]


# ---------------------------------------------------------------------- git
ALLOWED = [re.compile(r"kit/[A-Za-z0-9_]+\.py"), re.compile(r"tests/lemmas/test_[A-Za-z0-9_]+\.py")]


def path_ok(p):
    return p != "kit/__init__.py" and any(rx.fullmatch(p) for rx in ALLOWED)


def do_push(agent):
    ws = "%s/ws/%s" % (R, agent)
    rc, head = git("rev-parse", "HEAD", cwd=ws)
    if rc:
        return 1, "push failed: " + head, None
    rc, out = git("fetch", "--no-tags", "--quiet", ws, "+HEAD:refs/heads/agent/%s" % agent, cwd=CENTRAL)
    if rc:
        return 1, "push failed: " + out, None
    msg = "pushed %s to branch agent/%s" % (head[:10], agent)
    rc, dirty = git("status", "--porcelain", cwd=ws)
    if dirty:
        msg += "\nWARNING: uncommitted changes were NOT pushed:\n" + dirty[:600]
    return 0, msg, head


def verify(tree):
    """Run the frozen statement tests for every kit module present, sandboxed, no network."""
    present = [s for s in STATEMENTS if os.path.exists("%s/kit/%s.py" % (tree, s))]
    targets = ["tests/test_%s.py" % s for s in present]
    lem = tree + "/tests/lemmas"
    if os.path.isdir(lem) and any(f.startswith("test_") and f.endswith(".py") for f in os.listdir(lem)):
        targets.append("tests/lemmas")
    if not targets:
        return True, "no tests selected", present
    # Linux only: a throwaway root with the system directories read-only, the merged tree
    # writable at /work, no network. Agents' code runs here, never with the gateway's reach.
    cmd = ["bwrap", "--ro-bind", "/usr", "/usr"]
    for d in ("/lib", "/lib64", "/lib32", "/bin", "/sbin"):
        if os.path.islink(d):
            cmd += ["--symlink", os.readlink(d), d]
        elif os.path.isdir(d):
            cmd += ["--ro-bind", d, d]
    cmd += ["--ro-bind", "/etc", "/etc", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
            "--ro-bind", R + "/tools", R + "/tools"]
    if PY_BASE and not PY_BASE.startswith("/usr"):
        # the interpreter behind the venv; its parent is bound so version-alias symlinks resolve
        cmd += ["--ro-bind", os.path.dirname(PY_BASE), os.path.dirname(PY_BASE)]
    cmd += ["--bind", tree, "/work", "--chdir", "/work", "--unshare-net", "--unshare-pid", "--unshare-ipc",
            "--die-with-parent", "--new-session", "--setenv", "PYTHONDONTWRITEBYTECODE", "1",
            "--setenv", "HOME", "/tmp",
            VENV_PY, "-m", "pytest", "-q", "-x", "--no-header", "-p", "no:cacheprovider", *targets]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        ok, out = p.returncode == 0, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        ok, out = False, "verifier timed out after 180 s"
    return ok, out[-2500:], present


def do_mr(agent, title):
    code, msg, head = do_push(agent)
    if code:
        return code, msg
    with MERGE_LOCK:
        _, main = git("rev-parse", "refs/heads/main", cwd=CENTRAL)
        if git("merge-base", "--is-ancestor", head, main, cwd=CENTRAL)[0] == 0:
            return 1, msg + "\nREJECTED: nothing new, your HEAD is already contained in main."
        tree = "%s/ci/%s" % (STATE, uuid.uuid4().hex[:12])
        rc, out = git("worktree", "add", "--detach", tree, main, cwd=CENTRAL)
        if rc:
            return 1, "merge job error: " + out
        try:
            safe_title = re.sub(r"[^\x20-\x7e]", " ", title)[:120]
            rc, out = git("-c", "user.name=merge-job", "-c", "user.email=merge-job@team.local", "merge", "--no-ff",
                          "-m", "Merge agent/%s: %s" % (agent, safe_title), head, cwd=tree)
            if rc:
                return 1, (msg + "\nREJECTED: merge conflict with main.\n" + out[-800:] +
                           "\nFix: git fetch origin main && git merge origin/main, resolve, commit, team mr again.")
            _, changed = git("diff", "--name-only", main, "HEAD", cwd=tree)
            bad = [p for p in changed.splitlines() if not path_ok(p)]
            if bad:
                return 1, (msg + "\nREJECTED: these paths may not be changed (only kit/<name>.py and "
                           "tests/lemmas/test_<name>.py are allowed; statements are frozen):\n  " + "\n  ".join(bad))
            ok, vout, present = verify(tree)
            lost = [s for s in landed() if s not in present]
            if lost:
                return 1, msg + "\nREJECTED: this would remove landed statements: " + " ".join(lost)
            if not ok:
                return 1, msg + "\nREJECTED by the verifier:\n" + vout
            _, new = git("rev-parse", "HEAD", cwd=tree)
            rc, out = git("update-ref", "refs/heads/main", new, main, cwd=CENTRAL)
            if rc:
                return 1, "merge job error: " + out
            with open(STATE + "/landed.json.tmp", "w") as f:
                json.dump(present, f)
            os.rename(STATE + "/landed.json.tmp", STATE + "/landed.json")
            with LOG_LOCK:
                with open(R + "/records/merges.jsonl", "a") as f:
                    f.write(json.dumps(dict(ts=round(time.time(), 3), agent=agent, title=safe_title, head=head,
                                            main=new, files=changed.splitlines(), landed=present)) + "\n")
            done = all(s in present for s in STATEMENTS)
            if done and not os.path.exists(STATE + "/DONE"):
                with open(STATE + "/DONE", "w") as f:
                    f.write(str(time.time()))
            return 0, (msg + "\nACCEPTED: merged into main as %s.\nverifier: %s\nlanded on main: %s%s" %
                       (new[:10], vout.splitlines()[-1] if vout else "", " ".join(present) or "-",
                        "\nRUN COMPLETE: every statement is on main." if done else ""))
        finally:
            git("worktree", "remove", "--force", tree, cwd=CENTRAL)
            shutil.rmtree(tree, ignore_errors=True)
            git("worktree", "prune", cwd=CENTRAL)


# -------------------------------------------------------------------- serve
def handle(agent, db, req):
    op = str(req.get("op"))
    h = halted()
    if h:
        return 3, ("TEAM PAUSED by the action monitor (%s: %s). Stop working and wait for the human operator."
                   % (h.get("agent"), h.get("reason"))), op
    if os.path.exists("%s/removed/%s" % (STATE, agent)):
        return 3, "You have been removed from the team by the operator. Stop working.", op
    if op == "whoami":
        return 0, agent, op
    if op == "status":
        return 0, status_text(agent), op
    left = time_left()
    if left is not None and left <= 0 and op in ("sql", "push", "mr"):
        return 3, "TIME IS UP: the run has ended. Stop working.", op
    if op == "sql":
        q = str(req.get("sql", ""))
        code, out = db.run(q)
        return code, out, q
    if op == "push":
        code, out, _ = do_push(agent)
        return code, out, op
    if op == "mr":
        title = str(req.get("title", ""))
        code, out = do_mr(agent, title)
        return code, out, title
    return 2, "unknown op", op


def serve(agent):
    base = "%s/ws/%s/.gw" % (R, agent)
    req_dir, resp_dir = base + "/req", base + "/resp"
    db = Db(agent)
    while True:
        try:
            names = sorted(n for n in os.listdir(req_dir) if n.endswith(".json"))
        except OSError:
            names = []
        for n in names:
            path = os.path.join(req_dir, n)
            try:
                if os.path.islink(path) or os.path.getsize(path) > 1 << 20:
                    raise ValueError("bad request file")
                req = json.load(open(path))
                if not isinstance(req, dict):
                    raise ValueError("bad request")
            except (OSError, ValueError):
                req = None
            try:
                os.unlink(path)
            except OSError:
                pass
            if req is None:
                continue
            rid = re.sub(r"[^0-9a-f]", "", str(req.get("id", "")))[:32] or "x"
            t0 = time.time()
            try:
                code, out, detail = handle(agent, db, req)
            except Exception as e:  # fail closed, keep serving
                code, out, detail = 70, "gateway error: %r" % (e,), str(req.get("op"))
            log(agent, str(req.get("op")), detail, code, int((time.time() - t0) * 1000), out)
            if os.path.realpath(resp_dir) != resp_dir:
                continue
            tmp = os.path.join(resp_dir, rid + ".tmp")
            with open(tmp, "w") as f:
                json.dump(dict(code=code, out=out), f)
            os.rename(tmp, os.path.join(resp_dir, rid + ".json"))
        time.sleep(0.05)


if __name__ == "__main__":
    import fcntl
    import sys
    # One gateway per directory: a second one would race the first for every request.
    _lock = open(R + "/config.json")
    try:
        fcntl.flock(_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit("another gateway is already serving " + R)
    os.makedirs(STATE + "/ci", exist_ok=True)
    print("gateway up for agents:", " ".join(AGENTS), flush=True)
    for a in AGENTS:
        threading.Thread(target=serve, args=(a,), daemon=True).start()
    while True:
        time.sleep(3600)
