"""Gateway: the only way out of an agent workspace.

One thread per agent polls that agent's spool directory (ws/<id>/.gw/req). Identity is the
spool a request arrived in, so an agent cannot speak as another agent unless it can write
outside its own workspace (the shell sandbox and the action-monitor hook forbid that).

Relays:  sql    -> the shared SQLite board; me() returns the caller's identity
         push   -> central.git refs/heads/agent/<id>   (own branch only)
         mr     -> merge job: lands on main only if the task's check accepts it
Every request is appended to records/gateway.jsonl. Standard library only.
"""
import fcntl
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import uuid

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = json.load(open(R + "/config.json"))
TASK = CFG["task"]
AGENTS = CFG["agents"]
STATEMENTS = TASK["statements"]
ALLOWED = [re.compile(p) for p in TASK["allowed_paths"]]
CENTRAL = R + "/central.git"
STATE = R + "/state"
DBFILE = STATE + "/board.db"
RECORDS = R + "/records/gateway.jsonl"

LOG_LOCK = threading.Lock()
MERGE_LOCK = threading.Lock()
GITENV = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")


def log(agent, op, detail, code, ms, out):
    rec = dict(ts=round(time.time(), 3), agent=agent, op=op, detail=detail[:4000], code=code, ms=ms, out=out[:1500])
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
    left, got = time_left(), landed()
    lines = ["you: %s" % agent,
             "time left: %s" % ("not started" if left is None else "%d min" % max(0, left // 60)),
             "done on main (%d/%d): %s" % (len(got), len(STATEMENTS), " ".join(got) or "-"),
             "still open: %s" % (" ".join(s for s in STATEMENTS if s not in got) or "-")]
    lines.append("main: %s" % git("rev-parse", "--short", "refs/heads/main", cwd=CENTRAL)[1])
    if os.path.exists(STATE + "/DONE"):
        lines.append("RUN COMPLETE: every statement is on main. You may stop.")
    elif left is not None and left <= 0:
        lines.append("TIME IS UP: the run has ended. Stop working.")
    return "\n".join(lines)


# -------------------------------------------------------------------- board
A = sqlite3
LEAD_ONLY = {A.SQLITE_DELETE, A.SQLITE_ALTER_TABLE, A.SQLITE_REINDEX, A.SQLITE_ANALYZE,
             A.SQLITE_CREATE_INDEX, A.SQLITE_CREATE_TABLE, A.SQLITE_CREATE_TRIGGER, A.SQLITE_CREATE_VIEW,
             A.SQLITE_CREATE_TEMP_INDEX, A.SQLITE_CREATE_TEMP_TABLE, A.SQLITE_CREATE_TEMP_TRIGGER,
             A.SQLITE_CREATE_TEMP_VIEW, A.SQLITE_CREATE_VTABLE, A.SQLITE_DROP_INDEX, A.SQLITE_DROP_TABLE,
             A.SQLITE_DROP_TRIGGER, A.SQLITE_DROP_VIEW, A.SQLITE_DROP_TEMP_INDEX, A.SQLITE_DROP_TEMP_TABLE,
             A.SQLITE_DROP_TEMP_TRIGGER, A.SQLITE_DROP_TEMP_VIEW, A.SQLITE_DROP_VTABLE}
NOBODY = {A.SQLITE_ATTACH, A.SQLITE_DETACH, A.SQLITE_TRANSACTION, A.SQLITE_SAVEPOINT}
READ_PRAGMAS = {"table_info", "table_xinfo", "table_list", "index_list", "index_info", "foreign_key_list"}


def split_sql(q):
    out, buf = [], ""
    for part in q.split(";"):
        buf += part + ";"
        if sqlite3.complete_statement(buf):
            out.append(buf)
            buf = ""
    if buf.strip(" ;\n\t"):
        out.append(buf.rstrip("; \n\t"))
    return [s for s in out if s.strip(" ;\n\t")]


class Board:
    """One SQLite connection per agent. The gateway, not the agent, decides who me() is and
    what kinds of statement are allowed."""

    def __init__(self, agent):
        self.agent, self.internal, self.deadline = agent, True, 0.0
        c = self.conn = sqlite3.connect(DBFILE, timeout=10, isolation_level=None)
        c.execute("PRAGMA journal_mode = WAL")
        c.execute("PRAGMA busy_timeout = 8000")
        c.execute("PRAGMA trusted_schema = ON")          # lets DEFAULT (me()) work
        page = c.execute("PRAGMA page_size").fetchone()[0]
        c.execute("PRAGMA max_page_count = %d" % (CFG["db_cap_bytes"] // page))
        c.create_function("me", 0, lambda: agent)
        c.set_authorizer(self.authorize)
        c.set_progress_handler(lambda: 1 if self.deadline and time.time() > self.deadline else 0, 20000)
        self.internal = False

    def authorize(self, action, arg1, arg2, dbname, source):
        if self.internal:
            return A.SQLITE_OK
        if action in NOBODY or (action == A.SQLITE_FUNCTION and arg2 == "load_extension"):
            return A.SQLITE_DENY
        if action == A.SQLITE_PRAGMA:
            return A.SQLITE_OK if arg1 in READ_PRAGMAS else A.SQLITE_DENY
        if action in LEAD_ONLY and self.agent != "lead":
            return A.SQLITE_DENY
        return A.SQLITE_OK

    def _own(self, sql):
        self.internal = True
        try:
            self.conn.execute(sql)
        finally:
            self.internal = False

    def run(self, q):
        stmts = split_sql(q)
        if not stmts:
            return 1, "ERROR: empty request"
        if re.search(r"\bvacuum\b", q, re.I):
            return 1, "ERROR: not allowed: VACUUM"
        out, code = [], 0
        self.deadline = time.time() + CFG["sql_timeout_s"]
        try:
            self._own("BEGIN IMMEDIATE")
            for st in stmts:
                cur = self.conn.execute(st)
                if cur.description:
                    rows = cur.fetchmany(201)
                    out.append(" | ".join(d[0] for d in cur.description))
                    for r in rows[:200]:
                        out.append(" | ".join("NULL" if v is None else str(v) for v in r))
                    out.append("(%d row%s%s)" % (min(len(rows), 200), "" if len(rows) == 1 else "s",
                                                 ", truncated" if len(rows) > 200 else ""))
                else:
                    out.append("OK" if cur.rowcount < 0 else "OK (%d row%s changed)" %
                               (cur.rowcount, "" if cur.rowcount == 1 else "s"))
            self._own("COMMIT")
        except sqlite3.Error as e:
            code, msg = 1, str(e)
            if "interrupted" in msg:
                msg = "statement cancelled after %d s" % CFG["sql_timeout_s"]
            elif "not authorized" in msg or "authorization denied" in msg:
                msg = ("not allowed. Helpers may SELECT, INSERT and UPDATE; only the lead may create, alter, drop "
                       "or delete. Nobody may ATTACH, use PRAGMA to change settings, or write BEGIN/COMMIT: each "
                       "request already runs as one transaction.")
            elif "full" in msg:
                msg = "the board is at its size limit; writes are refused"
            out = ["ERROR: " + msg]
            if len(stmts) > 1:
                out.append("NOTE: nothing in this request was applied.")
            try:
                self._own("ROLLBACK")
            except sqlite3.Error:
                pass
        finally:
            self.deadline = 0.0
        return code, "\n".join(out)[:20000]


# ---------------------------------------------------------------------- git
def path_ok(p):
    return any(rx.fullmatch(p) for rx in ALLOWED)


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


def run_check(tree, name):
    """Run the task's check for one statement inside a throwaway root: system directories and
    tools/ read-only, the merged tree writable at /work, no network. Linux (bubblewrap)."""
    cmd = ["bwrap", "--ro-bind", "/usr", "/usr"]
    for d in ("/lib", "/lib64", "/lib32", "/bin", "/sbin"):
        if os.path.islink(d):
            cmd += ["--symlink", os.readlink(d), d]
        elif os.path.isdir(d):
            cmd += ["--ro-bind", d, d]
    cmd += ["--ro-bind", "/etc", "/etc", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp"]
    for p in [R + "/tools"] + list(TASK.get("toolchain_paths", [])):
        if os.path.exists(p):
            cmd += ["--ro-bind", p, p]
    cmd += ["--bind", tree, "/work", "--chdir", "/work", "--unshare-net", "--unshare-pid", "--unshare-ipc",
            "--die-with-parent", "--new-session", "--setenv", "HOME", "/tmp", "--setenv", "PYTHONDONTWRITEBYTECODE", "1",
            "--setenv", "PATH", R + "/tools/bin:/usr/local/bin:/usr/bin:/bin",
            "sh", "-c", TASK["check"].format(name=name)]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TASK.get("check_timeout_s", 180))
        return p.returncode == 0, (p.stdout + p.stderr).strip()[-2000:]
    except subprocess.TimeoutExpired:
        return False, "check timed out"


def verify(tree):
    """A statement that has been attempted must pass its check. Returns (ok, report, passing)."""
    probe = TASK.get("attempted_if")
    passing = []
    for s in STATEMENTS:
        attempted = (not probe) or os.path.exists(os.path.join(tree, probe.format(name=s)))
        if not attempted:
            continue
        ok, out = run_check(tree, s)
        if ok:
            passing.append(s)
        elif probe:
            return False, "statement `%s` does not pass its check:\n%s" % (s, out), passing
    return True, "checked: %s" % (" ".join(passing) or "nothing attempted yet"), passing


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
                return 1, (msg + "\nREJECTED: these paths may not be changed (everything outside the task's "
                           "allowed paths is frozen):\n  " + "\n  ".join(bad))
            ok, report, passing = verify(tree)
            if not ok:
                return 1, msg + "\nREJECTED by the check: " + report
            lost = [s for s in landed() if s not in passing]
            if lost:
                return 1, msg + "\nREJECTED: this would break statements that are already done: " + " ".join(lost)
            _, new = git("rev-parse", "HEAD", cwd=tree)
            rc, out = git("update-ref", "refs/heads/main", new, main, cwd=CENTRAL)
            if rc:
                return 1, "merge job error: " + out
            with open(STATE + "/landed.json.tmp", "w") as f:
                json.dump(passing, f)
            os.rename(STATE + "/landed.json.tmp", STATE + "/landed.json")
            with LOG_LOCK:
                with open(R + "/records/merges.jsonl", "a") as f:
                    f.write(json.dumps(dict(ts=round(time.time(), 3), agent=agent, title=safe_title, head=head,
                                            main=new, files=changed.splitlines(), landed=passing)) + "\n")
            done = all(s in passing for s in STATEMENTS)
            if done and not os.path.exists(STATE + "/DONE"):
                with open(STATE + "/DONE", "w") as f:
                    f.write(str(time.time()))
            return 0, (msg + "\nACCEPTED: merged into main as %s.\n%s\ndone on main: %s%s" %
                       (new[:10], report, " ".join(passing) or "-",
                        "\nRUN COMPLETE: every statement is on main." if done else ""))
        finally:
            git("worktree", "remove", "--force", tree, cwd=CENTRAL)
            shutil.rmtree(tree, ignore_errors=True)
            git("worktree", "prune", cwd=CENTRAL)


# -------------------------------------------------------------------- serve
def handle(agent, board, req):
    op = str(req.get("op"))
    h = halted()
    if h:
        return 3, ("TEAM PAUSED by the action monitor (%s: %s). Stop working and wait for the boss."
                   % (h.get("agent"), h.get("reason"))), op
    if os.path.exists("%s/removed/%s" % (STATE, agent)):
        return 3, "You have been removed from the team by the boss. Stop working.", op
    if op == "whoami":
        return 0, agent, op
    if op == "status":
        return 0, status_text(agent), op
    left = time_left()
    if left is not None and left <= 0 and op in ("sql", "push", "mr"):
        return 3, "TIME IS UP: the run has ended. Stop working.", op
    if op == "sql":
        q = str(req.get("sql", ""))
        code, out = board.run(q)
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
    board = Board(agent)
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
                code, out, detail = handle(agent, board, req)
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
