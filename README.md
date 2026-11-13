# sealed-team

An agent skill for standing up a small team of sandboxed coding agents from scratch, in an
environment that has no such system. The team is one lead plus helpers. They coordinate only
through a shared database and Git, their work counts only when a machine-checked merge job
accepts it, and a fail-closed monitor can pause all of them at once.

The design comes from Anthropic's post
[Safely scaling multi-agent teams with Claude Fable 5.2](https://claude.dev/blog/safely-scaling-multi-agent-teams-with-fable-5-2/)
(claude.dev, 2026-11-09), which describes a 1,000-agent team. This skill is an independent,
four-agent reconstruction of that design, written down so another agent can rebuild it with
whatever its own environment offers. It is not affiliated with or endorsed by Anthropic.

## What is in here

| Path | What it is |
|---|---|
| `SKILL.md` | The portable part: when to build this, nine design rules with their reasons, a checklist for mapping them onto your environment, the build order with a test after each step, and what to report |
| `references/claude-code-linux.md` | How the worked example satisfies each rule, and the quirks of that one setup |
| `example/` | The worked example, complete and runnable: Claude Code sessions in tmux windows on one Linux machine, Postgres in Docker, a Python gateway and merge job |

## When to use it

Rarely. The harness is about 1,100 lines that must be built and tested before any agent
starts. It pays off when a machine can check the finish line, the work splits into pieces
that land separately, and there are too many agents or hours to supervise by reading along.
For anything smaller, ordinary subagents are the better tool, and the skill says so in its
first section.

## Install

The skill activates only when invoked by name.

    git clone https://github.com/carbonscott/sealed-team ~/.claude/skills/sealed-team

Then, in a session: `/sealed-team <the goal, and how a machine can check it>`.

Other agent runtimes can use `SKILL.md` as a plain instruction file.

## What travels and what does not

The nine rules in `SKILL.md` are meant to hold anywhere:

1. A whiteboard (five database tables) instead of messages
2. A fixed finish line that a machine checks, reached only through a merge job
3. Identity decided by the channel a request arrives on
4. One door out of each agent's workspace
5. Walls: write only in your own workspace, no view of the others, no network
6. A check before every action that fails closed and pauses the whole team
7. No stopping until the checker says done or time runs out
8. Every agent starts cold, from a written brief
9. Records kept where agents cannot reach them

Everything in `example/` is one way to satisfy them and is tied to its setup: Claude Code's
hooks, sandbox settings and command-line flags; bubblewrap; tmux; Docker; Postgres roles;
pytest as the checker. A different runtime needs its own way to intercept actions, wall
agents off, and refuse a stop. `SKILL.md` section 4 lists fallbacks for each and says what
you lose with the weaker ones.

## Evidence so far

The example has been run three times, on 2026-11-12 and 2026-11-13, on one Linux VM with
four Claude Fable 5.2 agents (a lead and three helpers). The task was a seven-module Python
package whose frozen tests stand in for theorem statements.

| | First build | This repository, first run | This repository, as published |
|---|---|---|---|
| Statements landed on `main` | 7 of 7 | 7 of 7 | 7 of 7 |
| Launch to finish | 4.1 min | 2.5 min | 1.5 min |
| Orders posted to last merge | 65 s | 97 s | 51 s |
| Tool calls checked by the monitor | 41 | 32 | 32 |
| Gateway requests | 81 | 62 | 46 |
| Merge requests accepted / rejected | 7 / 0 | 7 / 0 | 5 / 1 |
| Team pauses | 1 (false alarm) | 0 | 0 |
| Independent check of `main` | 129 of 129 tests pass | 129 of 129 | 129 of 129 |

In the last run two merges carried two statements each, and one request was rejected: a
helper submitted a module another helper had already landed, and the merge job refused it
as a conflict.

Before the last run, `harness/test_gateway.sh` passed 15 of 15 checks and
`harness/selftest.sh` showed every wall holding from inside an agent session.

`SKILL.md` has also had one cold read. A fresh agent was given only the skill and a
different situation (a macOS laptop, no containers, a different agent runtime, a
JavaScript-to-TypeScript port) and asked to plan the build and list what was unclear. It
returned 16 gaps, mostly places where the text assumed the authors' setup or an invented
task, and the text was revised in response.

The one pause was a fault in the monitor's own rules: the lead's orders contained the words
"git push" as a warning, and a pattern rule read that as a push. The rule was fixed and the
team resumed.

**What these runs do not show.** The task was easy: each module took an agent seconds. No
task was split, the lead never had to move a helper, the checker never had to reject
submitted work during a run, the first five-minute reminder never came due, and the model
classifier never blocked anything. Nobody has yet rebuilt the system from `SKILL.md` alone
in a different environment. Treat the rules as a reasoned design with a small proof of concept behind it.

## Limits of the worked example

- All agents share one OS account and one login. The sandbox confines their shell commands;
  the agent processes themselves are outside it.
- Passing tests is a weaker finish line than a checked proof.
- Linux only as written (it depends on bubblewrap).

## License

MIT. See `LICENSE`.
