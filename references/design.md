# Design notes

Background for `SKILL.md`: where the design comes from, why each part exists, what the
template enforces and what it only requests, and how to adapt it elsewhere.

## Where it comes from

Anthropic's post "Safely scaling multi-agent teams with Claude Fable 5.2" (claude.dev,
2026-11-09) describes a team of 1,000 agents that coordinated only through a shared
database and Git, inside sandboxes, under a monitor that checked every action. This
template is an independent reconstruction of that design on one Linux machine. The design
has no size limit. The template has been run with four agents.

## The nine rules

| # | Rule | Why |
|---|---|---|
| 1 | **A board instead of messages.** Agents share a database and a Git repository and nothing else. Five tables: `announce` (orders), `assign` (who is on what), `notes` (plans and progress), `subtasks` (the to-do list), `landed` (finished work). Claiming a task is one atomic update. | A board survives an agent dying, makes nobody wait for a reply, can be read by a latecomer, and is a full record afterwards. |
| 2 | **A fixed finish line that a machine checks.** The goal is split into statements. Work counts only when the merge job accepts it onto `main`: it merges the branch, refuses changes outside the allowed paths, runs the check where agents cannot reach, then moves `main`. | Agents report success optimistically, and nobody can read every diff. The merge job turns "done" from a claim into a fact. |
| 3 | **Identity comes from the channel.** Who sent a request is decided by where it arrived, never by a name the agent writes. | Records can be attributed, a claim means something, and orders can be told from notes. |
| 4 | **One door out.** One command (`team`) for everything shared, served by a gateway outside the agents' reach that stamps identity, enforces limits and logs. | One place to enforce, one place to log. |
| 5 | **Walls.** An agent writes only in its own workspace, cannot see the others or the harness, and has no network. Tools that cannot be walled are removed. | Without walls, rules 1 to 4 are only requests. |
| 6 | **Check before acting, and fail closed.** A monitor sees every command and edit first. A block pauses the whole team until the boss has reviewed it. | A team that keeps running while you investigate has time to try the next thing. |
| 7 | **Keep going until the check says done.** No agent may stop while statements are open and time remains. | Agents stop early, after their own task or while waiting. |
| 8 | **A cold start from a brief.** Each agent is a separate session that starts from a short written brief. A helper's brief says only where the orders are. | Inherited context is a private channel the board does not record. |
| 9 | **Records out of reach.** Every tool call, gateway request and merge is logged where agents cannot read or write. | The monitor catches only what it was built for. The records catch the rest. |

The lead designs the tables and writes the orders. Helpers start knowing only where the
orders are, which keeps the briefs short and shows that the board carries everything.

## Writing a good task

- **A merge must be able to pass before the whole goal does.** If the only check is global,
  nothing can land until the end. Give each statement its own check.
- **Freeze the check's settings** along with the statements, and make the check reject its
  own escape hatches (skipped tests, suppressed errors).
- **Give every shared file one owner.** A file several statements must change is either
  prepared by the boss before launch or assigned to exactly one statement.
- **Know how strong the check is.** A proof checker cannot be satisfied by a wrong proof.
  A test suite can be passed by wrong code.
- **Size it.** If one agent could finish in a few minutes, the team exercises nothing.

## What the template enforces, and what it only requests

| Part | Status |
|---|---|
| Writes outside the workspace, reading other workspaces or the harness, network access, reaching tmux | Enforced for shell commands by the sandbox (tested from inside an agent session) |
| Board permissions, statement time limit, atomic claims, one transaction per request | Enforced by the gateway (tested) |
| Only checked work reaches `main`; frozen paths; no direct pushes | Enforced by the merge job (tested) |
| Pause on a rule violation | Enforced by the hook (tested) |
| Pause when the model classifier denies an action | Built, never triggered in a run |
| Paths given to the file tools (Read, Edit, Write, Glob, Grep) | Checked by fixed rules in `hook.py` only; never exercised, since agents used the shell |
| Authorship of board rows | A helper's rows default to its own name, and every request is logged under the true sender. A helper can still type another name into a column; the log shows who really wrote it. |
| Removing a helper | The gateway and monitor refuse it. Reopening its tasks is left to the lead. Never exercised. |
| Agents isolated from the boss's account | Not enforced. All sessions run as one OS user with one login. The sandbox confines their shell commands; the agent processes themselves are outside it. |
| Honest results | A test suite is a weaker check than a proof. The merge job limits which paths change; it does not inspect what the code does. |

Not yet exercised in any run: splitting a task, moving a helper between crews, the
five-minute reminder, a slow check, a helper dying mid-task, and teams larger than four.

## Adapting it

What each part needs, strongest option first. The last option in a row makes that part a
request that nothing enforces.

| Need | Options |
|---|---|
| Separate sessions | A VM or container per agent. Separate processes of an agent CLI, one per tmux window. Subagents inside one session. |
| Walls | A VM or container. An OS sandbox around the agent's shell. A separate OS user per agent. Instructions only. |
| Board | A database server with one account per agent. A single-file database only the gateway can open (the template). Files with atomic rename behind the gateway. |
| Identity and door | Credentials held only by the gateway. A per-agent channel inside that agent's walls (the template). A name the agent supplies. |
| Check isolation | A throwaway container or sandbox with no network (the template). A subprocess under another OS user. A plain subprocess. |
| Check before acting | A hook on every tool call plus a model classifier (the template). A hook with fixed rules. Nothing. |
| Stop control | A hook that can refuse a stop (the template). An outer loop that prompts again. Nudges by hand. |

If the walls cannot be enforced, the board, identity and records are requests too, because
an agent that can reach the files behind them can go around them. In that case the merge
job is the piece that keeps most of its value, and ordinary subagents behind it may be all
that is worth building.

tmux is the convenient way to run the sessions: it gives an agent a terminal it can create
itself, keeps sessions alive, lets a person watch, and lets the boss type into a running
session. Headless sessions also work without it, but give up the live view and the way in.

For a very large team, a database server with one account per agent is the stronger board.
An earlier version of this repository used Postgres in Docker that way; it is kept under
the git tag `postgres-docker`.

## Lessons from building it

- **Monitor rules must judge commands, not text.** The lead's first orders said "never run
  git push" and a pattern rule read that as a push. The rules now ignore quoted text and
  here-document bodies.
- **A test can pass for the wrong reason.** "A wrong answer is rejected" once passed because
  the check had failed to start. The pre-launch test therefore also requires a right
  answer to be accepted.
- **Stop test gateways.** A gateway left behind by an interrupted test answered later
  requests with stale state. One gateway per directory is now enforced with a lock.
- **Keep reference solutions away from the agents.** `task/` is hidden from them.
