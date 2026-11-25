"""Write harness/settings/<agent>.json: the monitor hooks and the shell sandbox for each agent.

Claude Code specific. The sandbox hides (denyRead) the harness, the records, the state, the task
files and the other agents' workspaces, and in the home directory everything except:
- the folders on the path from the home directory down to this work directory (their other
  entries are hidden; when this folder is not under the home directory, nothing is on the path);
- SHELL_DOTS, the few entries under the home directory's dot-folders that a shell and its tools
  need (the shell's own start files, user-installed programs, the uv and pip caches), plus
  config.json: extra_readable_home_paths;
- shell-snapshots/ inside Claude Code's config folder (~/.claude, or $CLAUDE_CONFIG_DIR):
  Claude Code starts every Bash command by sourcing a file from there. Every other entry of that
  folder (history.jsonl, projects/, settings, credentials) is hidden.
Only entries that exist when this runs can be named, so launch.sh runs it again before every
launch. Add machine-specific extras in config.json: extra_private_paths.
"""
import json
import os
import shutil

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cfg = json.load(open(R + "/config.json"))
HOME = os.path.expanduser("~")
PY = shutil.which("python3") or "/usr/bin/python3"
# What a sandboxed shell may read under the home directory's dot-entries, as paths relative to
# it. Everything else that starts with a dot there (.ssh, .aws, .config, .gitconfig, .claude.json,
# histories, the rest of .local and .cache, anything new) is hidden. ~/.gitconfig is among the
# hidden: Git treats a global config it cannot open as fatal, so the agents' environment points
# Git at an empty one (GIT_CONFIG_GLOBAL below; each workspace has its own user.name).
SHELL_DOTS = [".bashrc", ".profile", ".bash_profile", ".bash_logout",   # read when a shell starts
              ".local/bin", ".local/lib",   # programs and Python packages installed for the user
              ".local/share/uv",            # Pythons and tools installed by uv (~/.local/bin links here)
              ".local/share/claude",        # Claude Code's own program: the shell's rg function runs it
              ".cache/uv", ".cache/pip"]    # package caches
SHELL_DOTS += [os.path.relpath(os.path.join(HOME, os.path.expanduser(p)), HOME)
               for p in cfg.get("extra_readable_home_paths", [])]
CLAUDE_DIR = os.path.abspath(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude"))
CLAUDE_KEEP = ["shell-snapshots"]   # sourced at the start of every Bash command


def inside(p, root):
    return p == root or p.startswith(root + os.sep)


def hide_all_but(top, keep):
    """The entries to hide so that nothing under top can be read except the paths in keep and
    the folders on the way to them."""
    if any(inside(top, k) for k in keep):
        return []
    if not any(inside(k, top) for k in keep) or not os.path.isdir(top):
        return [top]
    out = []
    for n in sorted(os.listdir(top)):
        out += hide_all_but(os.path.join(top, n), keep)
    return out


def private_paths():
    claude_keep = [os.path.join(CLAUDE_DIR, k) for k in CLAUDE_KEEP]
    out = hide_all_but(HOME, [R] + [os.path.join(HOME, n) for n in SHELL_DOTS] + claude_keep)
    if not inside(CLAUDE_DIR, HOME) and os.path.isdir(CLAUDE_DIR):    # $CLAUDE_CONFIG_DIR elsewhere
        out += hide_all_but(CLAUDE_DIR, claude_keep)
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
        "env": {"CLAUDE_CODE_STOP_HOOK_BLOCK_CAP": "100000",
                # ~/.gitconfig is hidden, and Git stops on a global config it cannot open
                "GIT_CONFIG_GLOBAL": "/dev/null"},
    }
    json.dump(s, open("%s/harness/settings/%s.json" % (R, a), "w"), indent=1)
print("settings written for %s (%d private paths hidden)" % (" ".join(cfg["agents"]), len(private)))
