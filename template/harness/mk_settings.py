"""Write harness/settings/<agent>.json: the monitor hooks and the shell sandbox for each agent.

Claude Code specific. The sandbox hides (denyRead) the harness, the records, the other agents'
workspaces, the task files, and everything in the home directory that is not on the path down to this folder,
plus the usual credential files. Add machine-specific extras in config.json: extra_private_paths.
"""
import json
import os
import shutil

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cfg = json.load(open(R + "/config.json"))
HOME = os.path.expanduser("~")
PY = shutil.which("python3") or "/usr/bin/python3"
CREDS = [".ssh", ".aws", ".gnupg", ".config", ".docker", ".kube", ".netrc", ".npmrc", ".pypirc",
         ".git-credentials", ".bash_history", ".zsh_history", ".python_history", ".claude.json",
         ".claude/.credentials.json", ".claude/projects", ".claude/settings.json", ".codex", ".copilot"]


def private_paths():
    """Siblings of every folder on the way from $HOME down to this one."""
    out = [os.path.join(HOME, p) for p in CREDS if os.path.exists(os.path.join(HOME, p))]
    if R.startswith(HOME + os.sep):
        here = HOME
        for part in os.path.relpath(R, HOME).split(os.sep):
            for n in sorted(os.listdir(here)):
                if n != part and not (here == HOME and n.startswith(".")):
                    out.append(os.path.join(here, n))
            here = os.path.join(here, part)
    return out + list(cfg.get("extra_private_paths", []))


os.makedirs(R + "/harness/settings", exist_ok=True)
private = private_paths()
for a in cfg["agents"]:
    others = [x for x in cfg["agents"] if x != a]
    hook = "%s %s/harness/" % (PY, R)
    s = {
        "hooks": {
            "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": hook + "hook.py " + a, "timeout": 15}]}],
            "PermissionDenied": [{"matcher": "*", "hooks": [{"type": "command", "command": hook + "denied.py " + a, "timeout": 15}]}],
            "Stop": [{"hooks": [{"type": "command", "command": hook + "keepgoing.py " + a, "timeout": 15}]}],
        },
        "sandbox": {
            "enabled": True,
            "autoAllowBashIfSandboxed": False,   # the auto-mode classifier still judges each command
            "allowUnsandboxedCommands": False,
            "filesystem": {
                "denyRead": [R + "/harness", R + "/records", R + "/state", R + "/task"]
                            + ["%s/ws/%s" % (R, o) for o in others] + private,
                "denyWrite": ["%s/ws/%s/.claude" % (R, a)],
            },
            "network": {"allowedDomains": []},
        },
        "env": {"CLAUDE_CODE_STOP_HOOK_BLOCK_CAP": "100000"},
    }
    json.dump(s, open("%s/harness/settings/%s.json" % (R, a), "w"), indent=1)
print("settings written for %s (%d private paths hidden)" % (" ".join(cfg["agents"]), len(private)))
