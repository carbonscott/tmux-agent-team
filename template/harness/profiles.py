"""Capability profiles: which tools an agent's Claude Code session is started with.

  profiles.py <agent>     print that agent's profile label, its --tools list, and "slash-on" or "slash-off"
  profiles.py --check     exit non-zero if config.json gives a profile that does not resolve (each problem on stderr)
  profiles.py --list      print <agent>=<label> for every agent, on one line

A profile is a set of four knobs (KNOBS):
  web        the WebSearch and WebFetch tools
  subagents  the Agent tool (and SubagentHandback from inside a subagent)
  skills     the Skill tool and slash commands (no --disable-slash-commands)
  shell_net  the shell's network commands (NET_CMDS) in the monitor; only with "sandbox": false

config.json gives a profile in "profile" (the team default, sealed if absent), in each value of
"agent_profiles" (agent -> profile) and in each value of "profiles" (named custom profiles). A value
is a name (a preset in PRESETS or a key of "profiles") or an object of knobs: an optional "base" (a
name; sealed when absent) and any knob as true or false, which overrides the base. Anything else
does not resolve: --check (and so setup.sh) refuses it, and the monitor grants such an agent nothing.

The sandbox is team-wide (top-level "sandbox"), never a knob. The shell has no network unless
shell_net is on and the sandbox is off; the monitor (hook.py) pauses the team on a Bash call that
asks for a domain (allowed_domains) or runs a network command (ssh, curl, ...) anywhere else.

Every reader of a profile (hook.py, run-agent.sh, selftest.sh, boss.sh, offline_monitor.py,
report.py, archive.py) goes through resolve() / label_of() here.
"""
import json
import os
import re
import sys

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEALED = ["Bash", "Edit", "Read", "Write", "Glob", "Grep"]
KNOBS = ("web", "subagents", "skills", "shell_net")
KNOB_TOOLS = {"web": ["WebSearch", "WebFetch"], "subagents": ["Agent"], "skills": ["Skill"], "shell_net": []}
PRESETS = {
    "sealed": (),
    "research": ("web",),
    "allied": ("web", "subagents"),
    "open": ("web", "subagents", "skills"),
    "remote": ("web", "subagents", "skills", "shell_net"),
}
NAME_RE = re.compile(r"[a-z][a-z0-9_-]*")   # always used with fullmatch: "$" would let "reader\n" through
# Names no custom profile may take: the presets, and the words a label uses for something else
RESERVED = ("custom", "invalid")
# load_cfg() puts here the keys config.json gives twice (json keeps only the last, silently):
# problems() refuses them and resolve() resolves nothing while any is present.
DUPS = "__duplicate_keys__"
# The shell commands that reach other machines, which the monitor passes only where shell_net is on
NET_CMDS = ["ssh", "scp", "sftp", "rsync", "curl", "wget"]


class ProfileError(ValueError):
    pass


def load_cfg(path=None):
    """config.json, with any key given twice in one object listed under DUPS."""
    dups = []

    def pairs(kv):
        d = {}
        for k, v in kv:
            if k in d:
                dups.append(k)
            d[k] = v
        return d
    cfg = json.load(open(path or R + "/config.json"), object_pairs_hook=pairs)
    if dups and isinstance(cfg, dict):
        cfg[DUPS] = dups
    return cfg


def tools_for(knobs):
    """The tools a set of knobs grants, in the fixed order."""
    out = list(SEALED)
    for k in KNOBS:
        if k in knobs:
            out += KNOB_TOOLS[k]
    return out


def sandbox_on(cfg):
    """config.json "sandbox": true (the default, also when absent) keeps every agent's shell in
    Claude Code's sandbox; false runs the team unwalled (see mk_settings.py). Only exactly false
    turns it off, so a bad value never opens the walls (problems() refuses it before setup)."""
    return cfg.get("sandbox", True) is not False


def profile_of(cfg, agent):
    """The raw profile value config.json gives this agent (a name or an object)."""
    ap = cfg.get("agent_profiles")
    if isinstance(ap, dict) and agent in ap:
        return ap[agent]
    return cfg.get("profile", "sealed")


def _custom(cfg):
    c = cfg.get("profiles", {})
    if not isinstance(c, dict):
        raise ProfileError("\"profiles\" must be an object of named profiles, not %s" % json.dumps(c))
    return c


def _knobs_of(cfg, value, seen):
    """(set of knobs on) for a raw value. Raises ProfileError."""
    if isinstance(value, str):
        if value in PRESETS:
            return set(PRESETS[value])
        custom = _custom(cfg)
        if not NAME_RE.fullmatch(value) or value in RESERVED or value not in custom:
            raise ProfileError("profile %s is neither a preset (%s) nor a name in \"profiles\""
                               % (json.dumps(value), ", ".join(PRESETS)))
        if value in seen:
            raise ProfileError("profiles %s form a cycle of bases" % " -> ".join(seen + [value]))
        return _knobs_of(cfg, custom[value], seen + [value])
    if isinstance(value, dict):
        for k, v in value.items():
            if k == "sandbox":
                raise ProfileError("a profile may not set \"sandbox\": the sandbox is team-wide, set the "
                                   "top-level \"sandbox\" in config.json")
            if k == "base":
                continue
            if k not in KNOBS:
                raise ProfileError("unknown knob %s (knobs: %s)" % (json.dumps(k), ", ".join(KNOBS)))
            if v is not True and v is not False:
                raise ProfileError("knob %s must be true or false, not %s" % (k, json.dumps(v)))
        base = value.get("base", "sealed")
        if not isinstance(base, str):
            raise ProfileError("base must be a profile name, not %s" % json.dumps(base))
        knobs = _knobs_of(cfg, base, seen)
        for k in KNOBS:
            if k in value:
                (knobs.add if value[k] else knobs.discard)(k)
        return knobs
    raise ProfileError("a profile must be a name or an object of knobs, not %s" % json.dumps(value))


def _label(value, knobs):
    on = ",".join(k for k in KNOBS if k in knobs)
    if isinstance(value, str):
        return value if value in PRESETS else "%s(%s)" % (value, on)
    return "custom(%s)" % on


def resolve_value(cfg, value):
    """Resolve a raw profile value. Returns dict(label, knobs, tools, slash, shell_net); raises ProfileError.
    shell_net is True only where the knob is on and the sandbox is off."""
    if cfg.get(DUPS):
        raise ProfileError("config.json gives a key twice (%s): json would keep only the last one silently"
                           % ", ".join(json.dumps(k) for k in cfg[DUPS]))
    try:
        knobs = _knobs_of(cfg, value, [])
    except RecursionError:
        raise ProfileError("a chain of bases too deep to resolve") from None
    if "shell_net" in knobs and sandbox_on(cfg):
        raise ProfileError("shell_net needs the sandbox off: set \"sandbox\": false, and read what an "
                           "unwalled run gives up in SKILL.md")
    ks = tuple(k for k in KNOBS if k in knobs)
    return dict(label=_label(value, knobs), knobs=ks, tools=tools_for(knobs), slash="skills" in knobs,
                shell_net="shell_net" in knobs and not sandbox_on(cfg))


def resolve(cfg, agent):
    """The resolved profile of one agent (see resolve_value). Raises ProfileError."""
    for key in ("agent_profiles", "profiles"):   # not an object: refused, never read as absent
        if key in cfg and not isinstance(cfg[key], dict):
            raise ProfileError("%s must be an object, not %s" % (key, json.dumps(cfg[key])))
    return resolve_value(cfg, profile_of(cfg, agent))


def tools_of(cfg, agent):
    """The tools the monitor passes for this agent. Raises ProfileError for a profile that does not resolve."""
    return resolve(cfg, agent)["tools"]


def label_of(cfg, agent):
    """The label boss.sh status, offline_monitor.py and the run's page show; "invalid" if it does not resolve."""
    try:
        return resolve(cfg, agent)["label"]
    except ProfileError:
        return "invalid"


def problems(cfg):
    out = []
    if type(cfg.get("sandbox", True)) is not bool:
        out.append("sandbox must be true or false, not %s" % json.dumps(cfg.get("sandbox")))
    if cfg.get(DUPS):
        out.append("a key is given twice (%s): json keeps only the last one, so say each once"
                   % ", ".join(json.dumps(k) for k in cfg[DUPS]))
        return out
    custom = cfg.get("profiles", {})
    if not isinstance(custom, dict):
        out.append("\"profiles\" must be an object of named profiles, not %s" % json.dumps(custom))
        return out
    for n in custom:
        if n in PRESETS:
            out.append("profiles: %r is a preset's name; pick another name" % n)
        elif n in RESERVED:
            out.append("profiles: %r is reserved (labels use it); pick another name" % n)
        elif not NAME_RE.fullmatch(n):
            out.append("profiles: %r is not a valid name (lower-case letters, digits, - and _, starting with a letter)" % n)
        else:
            try:
                resolve_value(cfg, n)
            except ProfileError as e:
                out.append("profiles: %s: %s" % (n, e))
    if "profile" in cfg:
        try:
            resolve_value(cfg, cfg["profile"])
        except ProfileError as e:
            users = [a for a in cfg.get("agents", []) if not (isinstance(cfg.get("agent_profiles"), dict) and a in cfg["agent_profiles"])]
            out.append("profile%s: %s" % (" (the default of %s)" % ", ".join(users) if users else "", e))
    ap = cfg.get("agent_profiles", {})
    if not isinstance(ap, dict):
        out.append("agent_profiles must be an object, not %s" % json.dumps(ap))
        return out
    for a, p in ap.items():
        if a not in cfg.get("agents", []):
            out.append("agent_profiles names %r, which is not in agents" % a)
        try:
            resolve_value(cfg, p)
        except ProfileError as e:
            out.append("agent_profiles gives %s a profile that does not resolve: %s" % (a, e))
    return out


def listing(cfg):
    return " ".join("%s=%s" % (a, label_of(cfg, a)) for a in cfg["agents"])


if __name__ == "__main__":
    cfg = load_cfg()
    arg = sys.argv[1] if len(sys.argv) > 1 else "--list"
    if arg == "--check":
        bad = problems(cfg)
        for b in bad:
            print("config.json: " + b, file=sys.stderr)
        sys.exit(1 if bad else 0)
    if arg == "--list":
        print(listing(cfg))
        sys.exit(0)
    try:
        r = resolve(cfg, arg)
    except ProfileError as e:
        sys.exit("profile for %s does not resolve: %s" % (arg, e))
    print(r["label"], ",".join(r["tools"]), "slash-on" if r["slash"] else "slash-off")
