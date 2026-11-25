"""Capability profiles: which tools an agent's Claude Code session is started with.

  profiles.py <agent>     print that agent's profile, its --tools list, and "slash-on" or "slash-off"
  profiles.py --check     exit non-zero if config.json names a profile or an agent that does not exist
  profiles.py --list      print <agent>=<profile> for every agent, on one line

config.json: "profile" is the team's default (sealed if absent); "agent_profiles" maps an agent
name to a profile and overrides the default for that agent. The shell has no network in every
profile: the sandbox allows no domain, and the monitor (hook.py) pauses the team on a Bash call
that asks for one (allowed_domains). The monitor refuses every tool a profile does not grant.
"""
import json
import os
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEALED = ["Bash", "Edit", "Read", "Write", "Glob", "Grep"]
PROFILES = {
    # name: (tools the session is started with, slash commands and skills on)
    "sealed": (SEALED, False),
    "research": (SEALED + ["WebSearch", "WebFetch"], False),
    "allied": (SEALED + ["WebSearch", "WebFetch", "Agent"], False),
    "open": (SEALED + ["WebSearch", "WebFetch", "Agent", "Skill"], True),
}


def load_cfg():
    return json.load(open(R + "/config.json"))


def profile_of(cfg, agent):
    return (cfg.get("agent_profiles") or {}).get(agent) or cfg.get("profile") or "sealed"


def tools_of(cfg, agent):
    """The tools the monitor passes for this agent. Raises KeyError for an unknown profile."""
    return PROFILES[profile_of(cfg, agent)][0]


def sandbox_on(cfg):
    """config.json "sandbox": true (the default, also when absent) keeps every agent's shell in
    Claude Code's sandbox; false runs the team unwalled (see mk_settings.py). Only exactly false
    turns it off, so a bad value never opens the walls (problems() refuses it before setup)."""
    return cfg.get("sandbox", True) is not False


def problems(cfg):
    out = []
    if type(cfg.get("sandbox", True)) is not bool:
        out.append("sandbox must be true or false, not %s" % json.dumps(cfg.get("sandbox")))
    if cfg.get("profile", "sealed") not in PROFILES:
        out.append("profile %r is not one of: %s" % (cfg.get("profile"), ", ".join(PROFILES)))
    for a, p in (cfg.get("agent_profiles") or {}).items():
        if a not in cfg["agents"]:
            out.append("agent_profiles names %r, which is not in agents" % a)
        if p not in PROFILES:
            out.append("agent_profiles gives %s the profile %r, which is not one of: %s" % (a, p, ", ".join(PROFILES)))
    return out


def listing(cfg):
    return " ".join("%s=%s" % (a, profile_of(cfg, a)) for a in cfg["agents"])


if __name__ == "__main__":
    cfg = load_cfg()
    arg = sys.argv[1] if len(sys.argv) > 1 else "--list"
    bad = problems(cfg)
    if arg == "--check":
        for b in bad:
            print("config.json: " + b, file=sys.stderr)
        sys.exit(1 if bad else 0)
    if arg == "--list":
        print(listing(cfg))
        sys.exit(0)
    name = profile_of(cfg, arg)
    if name not in PROFILES:
        sys.exit("unknown profile %r for %s (known: %s)" % (name, arg, ", ".join(PROFILES)))
    tools, slash = PROFILES[name]
    print(name, ",".join(tools), "slash-on" if slash else "slash-off")
