# tmux-agent-team

A skill and a ready-to-run template for setting up a team of Claude Code agents in tmux.

One **lead** and any number of **helpers** each run in their own tmux window and their own
sandboxed workspace. They never message each other. They coordinate through a shared board
(a SQL database) and Git, and their work counts only when a merge job has checked it. A
monitor looks at every command first and can pause the whole team. The agent that sets all
of this up and supervises it is the **boss**.

## Requirements

Linux with `tmux`, `git`, `python3`, `bwrap` (bubblewrap) and Claude Code. No Docker and no
database server.

## Install

    git clone https://github.com/carbonscott/tmux-agent-team ~/.claude/skills/tmux-agent-team

Then, in a Claude Code session: `/tmux-agent-team <the goal, and the command that checks one piece of it>`.
The skill activates only when invoked by name.

## Try the bundled example by hand

    cp -r template ~/team-trial && cd ~/team-trial
    ./setup.sh                    # tools, central repository, one workspace per agent
    harness/test_gateway.sh       # 15 checks on the board and the merge job
    harness/selftest.sh           # one agent session tries to break out of its sandbox
    ./launch.sh && harness/boss.sh trust
    tmux attach -t team           # watch; the "board" window shows the team's board
    python3 harness/verify.py     # afterwards: check the result on a fresh checkout
    ./teardown.sh --purge

The example task is a seven-module Python package whose frozen tests are the statements.
Four agents finish it in about two minutes.

## What is in here

| Path | What it is |
|---|---|
| `SKILL.md` | The runbook the boss follows: describe a task, set up, test, launch, supervise, finish |
| `template/` | The team, ready to copy: gateway and merge job, monitor hooks, briefs, scripts, and the example task under `template/task/` |
| `references/design.md` | Why each part exists, what is enforced and what is only requested, how to adapt it |
| `references/claude-code.md` | Which Claude Code feature implements each part, and its quirks |

Your own task plugs in through `template/task/` and the `task` section of
`template/config.json`: a list of statements, one check command, and the paths agents may
change. Nothing else in the template is specific to the example.

## Evidence

All runs used four Claude Fable 5.2 agents on one Linux VM, on 2026-11-12 and 2026-11-13,
with the example task. Each result was confirmed on a fresh checkout.

| Version | Who ran it | Result | Launch to finish |
|---|---|---|---|
| First build (Postgres in Docker) | The author agent | 7 of 7 | 4.1 min, including one false-alarm pause |
| Same design, relocatable (git tag `postgres-docker`) | The author agent, twice | 7 of 7, 7 of 7 | 2.5 min, 1.5 min |
| This template (SQLite, no Docker) | The author agent | 7 of 7 | 2.0 min |
| This template | A fresh agent given only `SKILL.md` | 7 of 7 | 1.5 min |
| This template, as published | The author agent, in a new directory | 7 of 7 | 1.4 min |

The fresh agent's run is the one that matters most: it set up, tested, launched, verified
and tore down the team from the runbook alone, and no command failed. It reported nine
places where the runbook was vague, and those were fixed before publishing.

**Not yet shown.** The example task is easy, so no run has had to split a task, move a
helper between crews, reach the five-minute reminder, or survive a helper dying. The model
classifier has never blocked anything. No team larger than four has been run, and no task
other than the example.

## Limits

- All agents run as one OS user with one Claude login. The sandbox confines their shell
  commands; the agent processes themselves are outside it.
- A test suite is a weaker check than a proof: wrong code can pass tests.
- Linux only as written (it depends on bubblewrap), and Claude Code only.

## Credit

The design follows Anthropic's post
[Safely scaling multi-agent teams with Claude Fable 5.2](https://claude.dev/blog/safely-scaling-multi-agent-teams-with-fable-5-2/)
(claude.dev, 2026-11-09), which ran it with 1,000 agents. This repository is an independent
reconstruction and is not affiliated with or endorsed by Anthropic.

## License

MIT. See `LICENSE`.
