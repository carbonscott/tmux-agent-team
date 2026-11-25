"""Action monitor (rule layer) + run records. PreToolUse hook: runs before every tool call.

  usage: hook.py <agent>          (stdin: Claude Code PreToolUse JSON)

- Appends every call to records/actions.jsonl, outside the agent workspaces.
- HARD violation: deny and write state/HALT, which pauses the whole team
  (fail-closed) until the boss reviews it.
- SOFT violation: deny only (the thing is simply not available in the sandbox).
- While HALT exists, or the agent has been removed, everything is denied.
- A tool the agent's profile (profiles.py) does not grant is refused. WebFetch may reach only
  http(s) hosts on the public internet: never this machine or its private network.
- A Bash call that asks for network access (allowed_domains) or carries any parameter beyond
  BASH_KEYS is a HARD violation: the shell stays offline in every profile.
The LLM layer is Claude Code's auto-mode classifier; its denials reach
denied.py, which also pauses the team.
"""
import ipaddress
import json
import os
import re
import socket
import sys
import threading
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import profiles  # noqa: E402

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = json.load(open(R + "/config.json"))
AGENT = sys.argv[1]
OTHERS = [a for a in CFG["agents"] if a != AGENT]
WS = "%s/ws/%s" % (R, AGENT)
HOME = os.path.expanduser("~")
STATE = R + "/state"
ROOTNAME = re.escape(os.path.basename(R))

SENSITIVE = [R + "/harness", R + "/records", R + "/state", R + "/task", HOME + "/.claude", HOME + "/.ssh",
             HOME + "/.config", HOME + "/.aws", "/run/user"] + ["%s/ws/%s" % (R, a) for a in OTHERS]
if os.environ.get("CLAUDE_CONFIG_DIR"):
    SENSITIVE.append(os.path.realpath(os.environ["CLAUDE_CONFIG_DIR"]))
READ_OK = [WS, R + "/bin", R + "/docs", R + "/tools", R + "/central.git"]
PROFILE = profiles.profile_of(CFG, AGENT)
GRANTED = set(profiles.PROFILES.get(PROFILE, ([], False))[0])   # an unknown profile grants nothing

CMD = r"(?:^|[;&|(`]\s*|\b(?:xargs|env|exec|nohup|timeout\s+\S+)\s+)"
HARD_BASH = [
    (CMD + r"(sudo|su|docker|podman|tmux|screen|claude|curl|wget|ssh|scp|sftp|rsync|telnet|nc|ncat|netcat|socat)(?:\s|$)",
     "command not allowed in the sandbox"),
    (r"\bgit\s+(?:-\S+\s+)*push\b", "direct git push (use `team push` / `team mr`)"),
    (r"\bgit\s+remote\s+(?:add|set-url|rename|remove)\b", "changing git remotes"),
    (ROOTNAME + r"/(?:harness|records|state|task)\b", "touching harness, records, state or task files"),
    (r"(?:%s/ws/|\.\./)(?:%s)\b" % (ROOTNAME, "|".join(OTHERS)), "touching another agent's workspace"),
    # The bare word, not only a path: a path can be quoted or built (~/'.claude', ~/{.claude,x},
    # d=.claude; ~/$d), and the rule cannot tell those apart from a mention. So a command that
    # merely mentions .claude (grep -r .claude) pauses the team too: a known false alarm, and the
    # price of failing closed. The shell sandbox (mk_settings.py) hides the files themselves.
    (r"\.claude\b|\.ssh\b|/run/user\b", "touching the agent loop or credentials"),
    (r"\bboard\.db\b", "reaching the board directly (use `team sql`)"),
]
# The parameters a normal Bash call carries (every call recorded in the proof runs had only
# these). allowed_domains asks Claude Code to open the sandbox's network to those hosts, and it
# did: the shell fetched a page in every profile. So a non-empty allowed_domains, and any other
# parameter, is a HARD block.
BASH_KEYS = {"command", "description", "timeout", "run_in_background"}
SOFT_BASH = [
    (r"\b(?:pip3?|uv)\s+(?:pip\s+)?install\b|\bapt(?:-get)?\s+install\b|\bnpm\s+i", "no network: nothing can be installed"),
    (CMD + r"(kill|pkill|killall)(?:\s|$)", "process control is not available"),
]


def inside(p, root):
    return p == root or p.startswith(root + os.sep)


def strip_data(cmd):
    """Drop heredoc bodies and quoted prose/SQL so the rules judge commands, not the text
    an agent writes (orders that say "never run git push" are not a git push)."""
    out, lines, i = [], cmd.split("\n"), 0
    while i < len(lines):
        out.append(lines[i])
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", lines[i])
        if m:
            i += 1
            while i < len(lines) and lines[i].strip() != m.group(2):
                i += 1
        i += 1
    return re.sub(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"",
                  lambda q: q.group(0) if not re.search(r"\s", q.group(0)) else '""', "\n".join(out))


def record(d, decision, reason=""):
    ti = d.get("tool_input") or {}
    small = {k: (v if not isinstance(v, str) else v[:4000]) for k, v in ti.items()}
    rec = dict(ts=round(time.time(), 3), agent=AGENT, session=d.get("session_id"), tool=d.get("tool_name"),
               input=small, decision=decision, reason=reason)
    if d.get("agent_id") or d.get("agent_type"):     # the call came from inside a subagent
        rec["subagent"] = d.get("agent_type") or d.get("agent_id")
    with open(R + "/records/actions.jsonl", "a") as f:
        f.write(json.dumps(rec) + "\n")


def deny(d, reason, hard):
    if hard:
        try:
            fd = os.open(STATE + "/HALT", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            os.write(fd, json.dumps(dict(ts=time.time(), agent=AGENT, by="rules", tool=d.get("tool_name"),
                                         reason=reason, input=d.get("tool_input"))).encode())
            os.close(fd)
        except FileExistsError:
            pass
        msg = ("BLOCKED by the action monitor: %s. The whole team is now paused until the boss has "
               "reviewed this. Stop working and wait." % reason)
    else:
        msg = "Not available in this sandbox: %s." % reason
    record(d, "block" if hard else "refuse", reason)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": msg}}))
    sys.exit(0)


def check_read(d, path, search):
    p = os.path.realpath(path)
    if any(inside(p, r) for r in READ_OK):
        return
    if any(inside(p, s) for s in SENSITIVE):
        deny(d, "reading %s (outside your sandbox)" % path, True)
    if inside(p, HOME) or (search and (inside(HOME, p) or inside(R, p))):
        deny(d, "path %s is outside your workspace" % path, False)


def check_write(d, path):
    p = os.path.realpath(path)
    if inside(p, WS):
        if inside(p, WS + "/.claude"):
            deny(d, "editing .claude settings (the agent loop)", True)
        if inside(p, WS + "/.gw") or inside(p, WS + "/.git"):
            deny(d, "edit .gw/.git only through the team and git commands", False)
        return
    if inside(p, R) or any(inside(p, s) for s in SENSITIVE):
        deny(d, "writing %s (outside your workspace)" % path, True)
    deny(d, "writes are limited to your workspace (%s)" % path, False)


def as_ip(host):
    """The address a host names, if it is written as one. inet_aton also reads the short and
    numeric forms (127.1, 2130706433, 0x7f.0.0.1) that a fetcher may accept."""
    try:
        return ipaddress.ip_address(host)
    except ValueError:
        pass
    try:
        return ipaddress.IPv4Address(socket.inet_aton(host))
    except (OSError, ValueError):
        return None


def resolve(host, limit=2.0):
    """Best effort: the addresses a name resolves to, or [] if that takes longer than limit."""
    found = []

    def look():
        try:
            for info in socket.getaddrinfo(host, None):
                ip = as_ip(info[4][0].split("%")[0])
                if ip is not None:
                    found.append(ip)
        except (OSError, UnicodeError):
            pass
    t = threading.Thread(target=look, daemon=True)
    t.start()
    t.join(limit)
    return list(found)


def local_host(host):
    """True for this machine and its private network: loopback, link-local (the cloud metadata
    address), private ranges, and names that are only meaningful here."""
    h = host.lower().rstrip(".")
    if not h or h == "localhost" or h.endswith((".localhost", ".local", ".internal", ".lan", ".home.arpa")):
        return True
    if h == socket.gethostname().lower():
        return True
    ip = as_ip(h)
    if ip is not None:
        return not ip.is_global
    return any(not a.is_global for a in resolve(h))


def check_url(d, url):
    if re.search(r"[\\\s\x00-\x1f]", url):
        deny(d, "WebFetch of a URL with backslashes, spaces or control characters", True)
    u = urllib.parse.urlsplit(url)
    if u.scheme.lower() not in ("http", "https"):
        deny(d, "WebFetch of a %s: URL (only http and https)" % (u.scheme or "relative"), True)
    if "@" in u.netloc:
        deny(d, "WebFetch of a URL with a user name in it", True)
    if local_host(u.hostname or ""):
        deny(d, "WebFetch of %s, which is this machine or its private network" % (u.hostname or url), True)


def main():
    d = json.load(sys.stdin)
    tool, ti = d.get("tool_name", ""), d.get("tool_input") or {}
    cwd = d.get("cwd") or WS
    try:
        h = json.load(open(STATE + "/HALT"))
    except (OSError, ValueError):
        h = None
    if h is not None:
        record(d, "paused")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
              "permissionDecisionReason": "TEAM PAUSED by the action monitor. Stop working and wait for the boss."}}))
        return
    if os.path.exists("%s/removed/%s" % (STATE, AGENT)):
        record(d, "removed")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
              "permissionDecisionReason": "You have been removed from the team. Stop working."}}))
        return

    def ab(p):
        return p if os.path.isabs(p) else os.path.join(cwd, p)

    # A subagent hands its result back to its parent through SubagentHandback, a tool of the
    # subagent's own. It is passed where the profile grants Agent, and only from inside a subagent.
    handback = tool == "SubagentHandback" and "Agent" in GRANTED and bool(d.get("agent_id") or d.get("agent_type"))
    if tool not in GRANTED and not handback:
        deny(d, "tool %s (not in the %s profile)" % (tool, PROFILE), False)
    if tool in ("Edit", "Write", "NotebookEdit"):
        check_write(d, ab(ti.get("file_path") or ti.get("notebook_path") or ""))
    elif tool == "Read":
        check_read(d, ab(ti.get("file_path") or ""), False)
    elif tool in ("Glob", "Grep"):
        check_read(d, ab(ti.get("path") or cwd), True)
    elif tool == "Bash":
        if ti.get("allowed_domains"):
            deny(d, "a shell command that asks for network access (allowed_domains: %s)"
                 % json.dumps(ti["allowed_domains"])[:200], True)
        odd = sorted(str(k) for k in ti if k not in BASH_KEYS and k != "allowed_domains")
        if odd:
            deny(d, "a shell command with a parameter the monitor does not know (%s)" % ", ".join(odd)[:200], True)
        cmd = strip_data(ti.get("command") or "")
        for rx, why in HARD_BASH:
            if re.search(rx, cmd, re.M):
                deny(d, why, True)
        for rx, why in SOFT_BASH:
            if re.search(rx, cmd, re.M):
                deny(d, why, False)
    elif tool == "WebFetch":
        check_url(d, str(ti.get("url") or ""))
    elif tool == "Skill" and re.search(r"tmux-agent-team", str(ti.get("skill") or ""), re.I):
        deny(d, "the team skill: an agent may not start another team", False)
    elif tool not in ("WebSearch", "Agent", "Skill", "SubagentHandback"):
        deny(d, "tool %s" % tool, False)
    record(d, "pass")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # fail closed
        print("action monitor error: %r" % (e,), file=sys.stderr)
        sys.exit(2)
