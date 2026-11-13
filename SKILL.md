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
- Agents never message each other. They share a board (a SQL database) and a Git repository, both reached through one command, `team`.
- Work counts only when the merge job accepts it onto `main`, and the merge job runs your check.
- A monitor looks at every command before it runs. A violation pauses the whole team until you have reviewed it.
- Nobody stops until every statement is done or time runs out.

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
| `budget_min` | Time budget for the run, in minutes |
| `session` | Name of the tmux session |
| `task.statements` | Names of the statements |
| `task.check` | Shell command that checks one statement in the repository root. `{name}` is replaced by the statement's name. Exit status 0 means done. |
| `task.attempted_if` | Optional path, with `{name}`. A statement is checked once this path exists, and from then on it must pass or the merge is rejected. Without this setting every statement is checked on every merge, and a merge is rejected only if it breaks a statement that was already done. |
| `task.allowed_paths` | Regular expressions. A merge may change only paths that match one of them. Everything else is frozen. |
| `task.toolchain_paths` | Extra directories the check must be able to read, beyond `/usr` and `tools/` |
| `extra_private_paths` | More paths to hide from the agents |

### 3. Set up

    ./setup.sh

This runs `task/install.sh`, creates the central repository from `task/seed/`, and makes one workspace and one settings file per agent.

### 4. Test before launch

    harness/test_gateway.sh     # the board and the merge job: every line must say PASS
    harness/selftest.sh         # the sandbox and the monitor, tried from inside one agent session

`selftest.sh` prints what each of twelve steps should show, then the agent's table of what happened, then PASS or FAIL lines. Compare the table with the expectations row by row, judging by the output text. Do not launch until both tests are clean.

### 5. Launch

    ./launch.sh
    harness/boss.sh trust       # run right after launch; it waits for each agent to start

A new workspace folder makes Claude Code ask whether to trust it, and the agent does not start until someone answers. `boss.sh trust` answers yes in each agent window and reports one line per agent. Tell the user you did this.

Tell the user they can watch with `tmux attach -t <session>`. The windows are `gateway` (request log), `board` (live view of the board), one per agent, and `reminders`. Set `TEAM_REMOTE_CONTROL=1` before `./launch.sh` to start each agent with Remote Control.

### 6. While it runs

Run the wait command as a background job, so that you stay reachable and are woken when it exits:

    harness/wait-run.sh 540     # exits when the run completes, pauses or times out, or after 540 s
    harness/boss.sh status      # one-line state of the run, at any time

The first line `wait-run.sh` prints is `DONE`, `HALT`, `TIME UP` or `STILL RUNNING`. On `STILL RUNNING`, start it again.

If it returns **HALT**, the monitor blocked something and the whole team is paused. `boss.sh status` shows the blocked action. Read it in full, then:

| What you find | What you do |
|---|---|
| A false alarm | Fix the rule in `harness/hook.py`, then `harness/boss.sh resume` and `harness/boss.sh say all "The pause is cleared: <why>. Carry on."` |
| A real violation by a helper | `harness/boss.sh remove <id>`, then resume and tell the others as above |
| A real violation by the lead | `harness/boss.sh end` |

Paused agents do not restart by themselves; the `say` step is required. Do not coach the team: your messages carry facts about the run (time, a pause cleared, a removal), never hints about the work.

### 7. Finish

1. **Check the result yourself:** `python3 harness/verify.py`. It clones `main` into a fresh directory, runs the check for every statement, and confirms the frozen files are unchanged. Every line must say PASS.
2. **Review the records:** `python3 harness/offline_monitor.py`. It lists every blocked or refused action, every failed board request and every rejected merge. Failed reads of `announce` at the very start are helpers arriving before the lead; they are harmless.
3. **Hand back the result.** It is the `main` branch of `<work dir>/central.git`.
4. **Stop the team:** `./teardown.sh`. It ends with "nothing from this run is still running" once every agent session has exited. Agents stop by themselves within a minute or two of the finish, so there is no need to wait for them first. Add `--purge` to delete the run's files as well.
5. **Report to the user:** whether every statement is done and how you checked, each pause and what you decided, each prompt you answered for them, and anything still running.

## Commands

| Command | Does |
|---|---|
| `./setup.sh` | One-time setup |
| `harness/test_gateway.sh`, `harness/selftest.sh` | Pre-launch tests; both reset what they touch |
| `./launch.sh` | Starts the tmux session and the run clock |
| `harness/wait-run.sh [seconds]` | Blocks until the run completes, pauses, or times out |
| `harness/boss.sh status / trust / say <id or all> "<text>" / resume / remove <id> / end` | The boss's controls |
| `python3 harness/verify.py` | Checks every statement on a fresh checkout of `main` |
| `python3 harness/offline_monitor.py` | Summary of the run's records |
| `./teardown.sh [--purge]` | Stops the session and the gateway; with `--purge`, deletes the run's files |
| `team help` | What agents can do: `whoami`, `status`, `sql`, `push`, `mr`, `wait` |

## If something goes wrong

| Symptom | Cause and fix |
|---|---|
| `test_gateway.sh`: "the task's right answer is accepted" fails | The check cannot run inside the merge job's sandbox. Its tools must be under `tools/` or `/usr`, or listed in `task.toolchain_paths`. The failure output shows the check's own error. |
| An agent window sits at a trust prompt | `harness/boss.sh trust` |
| The team pauses in the first minutes | Usually a false alarm: the lead quoted a forbidden command inside its orders. Read the blocked action; if it is harmless, resume and tell the agents. |
| Agents stay idle after a resume | `harness/boss.sh say all "..."` |
| Helpers keep waiting for `announce` | The lead has not posted orders yet. Look at the `lead` window. |
| "another gateway is already serving" | A gateway from an earlier attempt is still running. `./teardown.sh`. |
| Git warns about `.gitmodules` inside a workspace | Harmless. The sandbox shows stub dotfiles there; `setup.sh` already tells Git to ignore them. |
| An agent cannot find the check's command | `task/install.sh` did not put it in `tools/bin/` |

## More

- `references/design.md`: why each part exists, what is enforced and what is only requested, and how to adapt the design to a different environment.
- `references/claude-code.md`: which Claude Code feature implements each part, and its quirks.
