---
name: tmux-agent-team
description: Set up and run a team of Claude Code agents in tmux. One lead plus helpers, each in its own tmux window and sandboxed workspace, coordinating only through a shared board and Git, with a merge job that accepts only work that passes the task's check. Gives the exact steps to describe a task, set up, test, launch, supervise and finish a run with the bundled template. Activate ONLY when the user explicitly invokes /tmux-agent-team or names this skill. Do NOT infer activation from a request to parallelize work or spawn subagents.
argument-hint: <the goal, and the command that checks one piece of it>
---

# tmux agent team

You are the **boss**. You set the team up, start it, watch it, and check the result.

| Role | Who | Does |
|---|---|---|
| Boss | You | Describes the task, builds and starts the team, reviews pauses, verifies the result |
| Lead | One Claude Code session | Sets up the board, writes the orders, assigns work, keeps helpers moving. Does not do the work. |
| Helpers | The other sessions | Read the orders, claim a task, do it, get it merged, report. Repeat. |

How the team works:

- Each agent runs in its own tmux window, in its own sandboxed workspace (a Git clone on its own branch).
- Agents coordinate only through a shared board (a SQL database) and a Git repository, both reached through one command, `team`. There are no private messages: everything one agent tells another is on the board, where every agent and the boss can read it, and where it survives a restart. A quick question to one peer goes through the gateway as a message (`team msg`), stored on the board and logged under its true sender.
- Work counts only when the merge job accepts it onto `main`, and the merge job runs your check.
- A monitor looks at every command before it runs. A violation pauses the whole team until you have reviewed it.
- Nobody stops until every statement is done, time runs out, or the run stalls (no merge accepted for `stall_min`).

## Requirements

Linux with `tmux`, `git`, `python3`, `bwrap` (bubblewrap) and `claude` (Claude Code, signed in, with auto mode). The team itself needs nothing else: no Docker and no database server.

Your task's check may need tools of its own. They are installed during setup, which is the only step that may use the network. The example task installs `pytest` with `uv` or `pip`.

## Steps

### 1. Copy the template

    cp -r <this skill's folder>/template <work dir> && cd <work dir>

Everything below happens in the work directory. The template ships with a small example task and runs as it is. To try the example first, skip step 2.

### 2. Describe the task

A task is a list of **statements** (pieces that can be checked one at a time) and one **check** command.

| What | Where | Notes |
|---|---|---|
| The starting repository | `task/seed/` | Must contain `STATEMENTS.md`, which says what each statement requires. Add the files agents may not change (tests, specs, configuration) and any starting code. |
| The task settings | `config.json`, under `task` | See the table below |
| The check's tools | `task/install.sh` | Installs what the check needs into `tools/`; put commands in `tools/bin/`. Agents have no network, so everything is installed here. Delete the script if nothing is needed. |
| One right and one wrong answer | `task/probe/good/`, `task/probe/bad/` | Files to lay over a workspace: a correct answer to one statement, and a wrong one. The pre-launch test uses them to show the check can tell the difference. |

Settings in `config.json`:

| Setting | Meaning |
|---|---|
| `agents` | Names of the agents. One must be `lead`; every other name is a helper. Any number. |
| `budget_min` | Time budget for the run, in minutes. A ceiling: see "Time" below. |
| `stall_min` | Minutes without an accepted merge after which the run ends as `STALLED` (fractions allowed; `0` or absent switches it off). The template sets 30. |
| `model`, `effort` | The model and the effort level every agent runs with. An empty `model` means Claude Code's default; `effort` defaults to `medium`. |
| `session` | Name of the tmux session |
| `profile`, `agent_profiles` | What every agent may use, and per-agent exceptions: `"agent_profiles": {"h1": "research"}`. Default `sealed`. See "Profiles" below; `setup.sh` refuses a name it does not know. |
| `task.statements` | Names of the statements |
| `task.check` | Shell command that checks one statement in the repository root. `{name}` is replaced by the statement's name. Exit status 0 means done. |
| `task.checks` | Optional map from a statement's name to its own check command, used exactly as written (no `{name}`). A statement in the map is checked with its command, the others with `task.check`. The merge job, `verify.py` and the briefs all follow it. |
| `task.attempted_if` | Optional path, with `{name}`. A statement is checked once this path exists, and from then on it must pass or the merge is rejected. Without this setting every statement is checked on every merge, and a merge is rejected only if it breaks a statement that was already done. |
| `task.allowed_paths` | Regular expressions. A merge may change only paths that match one of them. Everything else is frozen. |
| `task.toolchain_paths` | Extra directories the check must be able to read, beyond `/usr` and `tools/` |
| `extra_private_paths` | More paths to hide from the agents |

**From a make-goal contract.** If the user has a contract from the make-goal skill (`.goal/<slug>.json`), let it write the task instead of filling the tables by hand. Only a `deterministic` contract works, and only before `./setup.sh`:

    python3 harness/from-goal.py .goal/<slug>.json                          # prints the plan, writes nothing
    python3 harness/from-goal.py .goal/<slug>.json --apply --allowed 'out/.*'   # writes config.json and task/seed/STATEMENTS.md

Each `done_when` item that names a command in backticks becomes a statement, checked by that command (`task.checks`). Items without one (the contract's claims and ledger items) are listed under `skipped`: they stay yours. Read every warning: a check such as `wc -l` exits 0 whatever it prints, so the merge job would accept anything; rewrite it in `config.json`. Turn the contract's guardrails into `--allowed` patterns yourself. Text already in `STATEMENTS.md` is kept below the generated statements (`--replace-statements` drops it): keep what still describes the task. Then fill `task/seed/`, `task/install.sh` and `task/probe/` as the first table says; `references/goal.md` says what the probe must hold for such a task, and why `test_gateway.sh` reports it as merged-but-not-counted. To run yourself under `/goal` while the team works, and for an agent that runs `/goal` itself, read `references/goal.md` first.

#### Time

`budget_min` is a **ceiling, not a floor**. A run ends as soon as every statement is done; the budget only ends a run that cannot finish, because agents are not allowed to stop before then. Setting it high costs nothing when the team succeeds and only costs idle time when it is stuck, so err high.

Rule of thumb: estimate how long one agent needs for one statement, multiply by the number of statements, divide by the number of helpers, multiply by 2 to 3 for coordination and rejected merges, and add about 5 minutes for the lead's setup.

`stall_min` caps the stuck case directly: when no merge has been accepted for that long, the gateway writes `state/STALLED` and the run is over (the door refuses work, agents may stop, what landed stays on `main`). Count it from the launch or the last accepted merge. Pauses and the time a run was down before `--resume` do not count. Make it about twice the time one statement should take, and longer than the lead's setup plus the first statement. Agents are not shown the stall clock; `boss.sh status` shows it to you.

The other limits guard single operations against a hang; none of them limits the work:

| Limit | What it is for |
|---|---|
| `task.check_timeout_s` (180 s) | One check in the merge job: a hung test cannot block every merge |
| `sql_timeout_s` (5 s) | One board request: a runaway query cannot lock the board for everyone |
| `wait-run.sh` 540 s | Claude Code caps one command at 10 minutes, so you wait in slices |
| `team wait` 110 s | The same cap, on the agents' side. The wait ends at once when the team is paused (exit status 3) or the run is over for the agent (4: complete, stalled, out of time, removed); `team status` exits the same way, with the reason on stderr too |

#### Profiles

Each agent's session is started with the tools of its profile, and the monitor refuses every
tool the profile does not grant. Choose the smallest profile the task needs.

| Profile | Gives the agent | Use it when | What it gives up |
|---|---|---|---|
| `sealed` (default) | `Bash`, `Edit`, `Read`, `Write`, `Glob`, `Grep`; slash commands off | The repository and the check are all the task needs | Nothing: this is the tested team |
| `research` | `sealed` plus `WebSearch`, `WebFetch` | Agents must read documentation or look things up | The team is no longer offline. A page can carry instructions to the agent, and what the agent puts in a search or URL leaves the machine. |
| `allied` | `research` plus `Agent` (subagents) | An agent has large reading or search jobs to hand off | A subagent works out of the agent's sight. Its tool calls pass the monitor and the sandbox like the agent's own (shown live); its report comes back through `SubagentHandback`, which the monitor passes on `allied` and `open` (not yet re-shown live) |
| `open` | `allied` plus `Skill`; slash commands on | An agent should run its own `/goal` or `/loop`, or use skills | The agent sees your installed skills, and `/loop` and `/goal` add a second control loop beside the harness's own |

In every profile: the shell has no network (the sandbox allows no domain, and a Bash call that asks
for one with `allowed_domains` pauses the team), connectors (MCP servers) are off, a pause refuses
every tool call, `tmux` and `claude` stay blocked, and only the merge job moves `main`.
`WebFetch` may fetch only `http` and `https` pages on the public internet; a URL for this
machine, its private network or a file pauses the team. On Claude Code 2.1.331 a `research`
session has the `WebFetch` tool itself; where `Agent` is present (`allied`, `open`) Claude Code
drops it and fetches pages through a `web-fetch` subagent, whose fetches the monitor checks the
same way. `harness/boss.sh status` lists each agent as `<agent>=<profile>`. An agent cannot
start `/goal` itself (Claude Code treats it as a command typed by a person); put an `open` agent
under `/goal` with `harness/boss.sh slash <id> "/goal <condition>"`, which `references/goal.md`
explains. Not yet shown live. `references/design.md` says what is enforced.

### 3. Set up

    ./setup.sh

This runs `task/install.sh`, creates the central repository from `task/seed/`, and makes one workspace and one settings file per agent.

### 4. Test before launch

    harness/test_gateway.sh     # the board and the merge job: every line must say PASS
    harness/selftest.sh [agent] # the sandbox and the monitor, tried from inside that agent's sessions (default: the last agent)

`selftest.sh` prints what each of its steps should show, then the agent's table of what happened (two short sessions), then PASS or FAIL lines. The sessions are started with the agent's profile, as at launch, so run it once for an agent of each profile in use. Compare the table with the expectations row by row, judging by the output text. Do not launch until both tests are clean.

### 5. Launch

    ./launch.sh
    harness/boss.sh trust       # run right after launch; it waits for each agent to start

A new workspace folder makes Claude Code ask whether to trust it, and the agent does not start until someone answers. `boss.sh trust` answers yes in each agent window, waits to see each session running, and reports one line per agent: `answered yes, started`, or that the session did not start. If it did not, look at that window; if the session quit, start it again there with `tmux send-keys -t '=<session>:<id>' "bash $PWD/harness/run-agent.sh <id>" Enter` and run `boss.sh trust` once more. Tell the user you did this.

Tell the user they can watch with `tmux attach -t <session>`. The windows are `gateway` (request log), `board` (live view of the board), one per agent, and `reminders`. Set `TEAM_REMOTE_CONTROL=1` before `./launch.sh` to start each agent with Remote Control.

### 6. While it runs

Run the wait command as a background job, so that you stay reachable and are woken when it exits:

    harness/wait-run.sh 540     # exits when the run completes, stalls, pauses or times out, or after 540 s
    harness/boss.sh status      # one-line state of the run, at any time

The first line `wait-run.sh` prints is `DONE`, `STALLED`, `HALT`, `TIME UP` or `STILL RUNNING`. On `STILL RUNNING`, start it again. If you run under `/goal`, each turn is one round of this step (`references/goal.md`).

On **STALLED**, no merge was accepted for `stall_min` minutes and the run is over: go to step 7, Finish. If the limit was plainly too short for the task (a check that legitimately takes long, say), `harness/boss.sh unstall` reopens the run with a fresh stall clock; then `harness/boss.sh say all "The run is reopened. Carry on."`.

If it returns **HALT**, the monitor blocked something and the whole team is paused. `boss.sh status` shows the blocked action. Read it in full, then:

| What you find | What you do |
|---|---|
| A false alarm | Fix the rule in `harness/hook.py`, then `harness/boss.sh resume` and `harness/boss.sh say all "The pause is cleared: <why>. Carry on."` |
| A real violation by a helper | `harness/boss.sh remove <id>`, then resume and tell the others as above |
| A real violation by the lead | `harness/boss.sh end` |

Agents can send each other messages: `team msg <agent|all> "<text>"` stores one in the board's table `messages`, `team inbox` reads it, and `team status` shows `unread messages: <n>` to the recipient. The gateway sets the sender, refuses unknown recipients, removed senders, anything sent during a pause and any text with control or format characters (printable text, newlines and tabs only), and nobody can change the table through `team sql`. `harness/boss.sh messages` shows them all. Your own `say` messages are typed into a window instead and are not stored there.

Paused agents do not restart by themselves; the `say` step is required. Do not coach the team: your messages carry facts about the run (time, a pause cleared, a removal), never hints about the work.

### If the run was interrupted

When the machine restarts or the tmux session dies, the run is not lost: the board, `main`, the workspaces and the clock live on disk. `harness/boss.sh status` prints a line starting `INTERRUPTED` for a run that started, is not complete and has no session; its time left and stall clock are shown as they stood at the last heartbeat, since `--resume` gives the time down back (during a pause, as they stood when it began). A plain `./launch.sh` then refuses and starts nothing. Choose one:

    ./launch.sh --resume        # continue it
    ./teardown.sh --archive     # or put it away as one sealed file

`--resume` first checks the work directory (every workspace, `central.git` with `main`, the clock files, `landed.json`, the board's integrity, and that no gateway still serves it: the gateway's lock on `config.json` must be free, or, where the lock cannot be tested, no gateway may have beaten in the last 10 s) and refuses if anything is wrong. It then moves the deadline later by the time the run was down (now minus the gateway's last heartbeat, `state/heartbeat`), records it in `records/resumes.jsonl`, and starts the gateway, the board and one window per agent. Each agent is a fresh session started from its rejoining brief (`python3 harness/render.py <agent> --resume`): it remembers nothing and finds its place on the board and in its workspace. The lead keeps its tables and orders and reopens the claims of helpers that do not come back. Earlier removals hold: a removed helper gets no window. Run `harness/boss.sh trust` again, then go on with step 6.

- A run that was paused when it died resumes still paused. Review `state/HALT` as in step 6; `boss.sh resume` then gives back the pause and the time down together.
- A run that had run out of time or stalled before it died is not interrupted: `boss.sh status` says `ended`, and `--resume` refuses. Archive it.
- `launch.sh --resume` continues a run after a crash; `boss.sh resume` clears a pause in a live run. They are different commands.

### 7. Finish

1. **Check the result yourself:** `python3 harness/verify.py`. It clones `main` into a fresh directory, runs the check for every statement, and confirms the frozen files are unchanged. Every line must say PASS. Once the run is complete `main` is closed (the gateway refuses `team mr`), so what you check is what you hand back.
2. **Review the records:** `python3 harness/offline_monitor.py`. It lists every blocked or refused action, every failed board request and every rejected merge. Failed reads of `announce` at the very start are helpers arriving before the lead; they are harmless. `harness/boss.sh messages` prints what the agents said to each other with `team msg`; read it for pressure, coaching or work done outside the board.
3. **Write the run's page:** `python3 harness/report.py`. It writes one self-contained HTML page, `report.html` in the work directory (`-o FILE` for another place), and prints `report: <full path>` as its last line. The page shows how much is done, the running time (pauses and time down do not count), a timeline of the run to scale, every accepted and rejected merge, each agent's numbers and profile, and every pause, removal, resume, stall and message count. It also works during a run, as a fuller view than `boss.sh status`. Step 5 keeps the final page in the archive.
4. **Hand back the result.** It is the `main` branch of `<work dir>/central.git`.
5. **Stop the team and put the run away:** `./teardown.sh --archive [DIR]`. It stops everything, runs `verify.py` once more, writes one sealed file `team-archive-<session>-<YYYYmmdd>-<HHMMSS>.tar.gz` into DIR (default: the folder that holds the work directory), deletes the run's files from the work directory, and prints `archived: <full path>` as its last line. The file holds only `central.git` (the result: `git clone central.git <dir>`), `records/` (with `run.json`, the run's facts, and `report.html`, its page; `python3 harness/report.py --records <unpacked>/records` rebuilds the page) and `STATUS.txt`, whose first line says what the run came to, for example `abandoned run, stopped 2026-11-25 14:41:07 UTC, 4 of 7 done, not verified`. It deletes nothing unless the file was written and read back. Its output says "nothing from this run is still running" once every agent session has exited. Agents stop by themselves within a minute or two of the finish, so there is no need to wait for them first.
6. **Report to the user:** whether every statement is done and how you checked, each pause and what you decided, each prompt you answered for them, and anything still running. Give them the path of the page from step 3.

**Archive or purge.** Archive by default, and always when any work is unverified or the run did not finish: the archive keeps the work and the audit, and nothing else. A run's files left in the work directory hold a stale board that a later session can mistake for live state, so do not leave them lying around either. Purge (`./teardown.sh --purge`) only a run with nothing worth keeping, such as a trial launch, or once its result has been handed back and checked elsewhere: it deletes the repository and the records for good. A plain `./teardown.sh` stops the run and keeps every file, for when you mean to look before deciding.

## Commands

| Command | Does |
|---|---|
| `./setup.sh` | One-time setup |
| `harness/test_gateway.sh`, `harness/selftest.sh [agent]` | Pre-launch tests; both reset what they touch. `selftest.sh` tests one agent's profile. |
| `./launch.sh` | Starts the tmux session and the run clock |
| `./launch.sh --resume` | Continues an interrupted run: same board and `main`, time down given back |
| `harness/wait-run.sh [seconds]` | Blocks until the run completes, stalls, pauses, or times out |
| `harness/boss.sh status / trust / say <id or all> "<text>" / slash <id> "/<command>" / messages / resume / unstall / remove <id> / end` | The boss's controls. `messages` prints every message the agents sent each other; `slash` types a slash command into an `open` agent's window; `unstall` reopens a stalled run. |
| `python3 harness/verify.py` | Checks every statement on a fresh checkout of `main` |
| `python3 harness/from-goal.py <contract> [--apply --allowed <regex> ...]` | Turns a make-goal contract into the task, before `setup.sh` |
| `python3 harness/offline_monitor.py` | Summary of the run's records |
| `python3 harness/report.py [-o FILE]`, `--records DIR` | One HTML page showing what the run did; works before, during and after a run, and on an unpacked archive's `records/` |
| `./teardown.sh [--archive [DIR] \| --purge]` | Stops the session and the gateway; `--archive` seals the repository and records into one dated file in DIR and then deletes the run's files; `--purge` deletes them without keeping anything |
| `python3 harness/profiles.py [--list / --check / <agent>]` | Each agent's profile; `--check` validates `config.json` |
| `team help` | What agents can do: `whoami`, `status`, `sql`, `push`, `precheck`, `mr`, `wait`, `msg`, `inbox` |
| `team precheck [--quick]` | For agents: the merge job's verdict on their HEAD merged with the current `main`, without landing it. `--quick` stops after the merge and the path rule. |

## If something goes wrong

| Symptom | Cause and fix |
|---|---|
| `test_gateway.sh`: "the task's right answer is accepted" fails | The check cannot run inside the merge job's sandbox. Its tools must be under `tools/` or `/usr`, or listed in `task.toolchain_paths`. The failure output shows the check's own error. |
| Merge requests keep coming back with "merge conflict" | Agents are editing the same shared files. The briefs tell them to run `team precheck --quick` after merging `main`; if conflicts persist, give the shared file one owner. |
| An agent window sits at a trust prompt | `harness/boss.sh trust` |
| The team pauses in the first minutes | Usually a false alarm: the lead quoted a forbidden command inside its orders. Read the blocked action; if it is harmless, resume and tell the agents. |
| The team pauses on a command that only mentions `.claude`, `.ssh` or `board.db` (`grep -rn .claude .`, `git log --grep=.claude`) | A known false alarm. The rule blocks the bare word on purpose, because a quoted or built path (`~/'.claude'`, `d=.claude; ~/$d`) cannot be told from a mention. Do not loosen the rule: `harness/boss.sh resume`, then `harness/boss.sh say all "The pause is cleared: <why>. Carry on."` |
| Agents stay idle after a resume | `harness/boss.sh say all "..."` |
| Helpers keep waiting for `announce` | The lead has not posted orders yet. Look at the `lead` window. |
| "another gateway is already serving" | A gateway from an earlier attempt is still running. `./teardown.sh`. |
| Git warns about `.gitmodules` inside a workspace | Harmless. The sandbox shows stub dotfiles there; `setup.sh` already tells Git to ignore them. |
| An agent cannot find the check's command | `task/install.sh` did not put it in `tools/bin/` |

## More

- `references/design.md`: why each part exists, what is enforced and what is only requested, and how to adapt the design to a different environment.
- `references/claude-code.md`: which Claude Code feature implements each part, and its quirks.
- `references/goal.md`: a make-goal contract as the team's task, the boss under `/goal` (its proof is the output of `harness/verify.py`), and an agent that runs `/goal` for its own part.
