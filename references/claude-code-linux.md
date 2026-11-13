# Worked example: Claude Code on Linux

How `example/` satisfies each rule in `SKILL.md`, and the quirks met along the way.
Everything on this page is specific to one setup: Claude Code 2.1.323 as the agent runtime,
one Linux machine, one OS account, with Docker, bubblewrap, tmux and uv installed.
Check flags and settings against your own version before relying on them.

## Rule by rule

| Rule | How the example does it | Where |
|---|---|---|
| 1. Whiteboard | Postgres in a Docker container, bound to localhost. The lead creates the five tables through the door. Helpers get SELECT, INSERT and UPDATE on the lead's tables through default privileges, and nothing else. | `setup.sh`, `harness/setup_db.py` |
| 2. Finish line | Frozen pytest files in `seed/tests`. The merge job merges the branch in a scratch worktree, rejects any path other than `kit/<name>.py` and `tests/lemmas/test_<name>.py`, runs pytest inside bubblewrap with no network, then moves `main`. A `pre-receive` hook refuses direct pushes. | `harness/gateway.py` (`do_mr`, `verify`) |
| 3. Identity | Each workspace has a request folder, `.gw/req`. The gateway treats a request as coming from the agent whose folder it arrived in, and opens the database under that agent's own role, so `current_user` is the identity. | `harness/gateway.py` (`serve`, `Db`) |
| 4. One door | The `team` command writes a request file and waits for the reply file. | `bin/team` |
| 5. Walls | Claude Code's shell sandbox, set per agent: writes only inside the workspace; the harness, records, other workspaces and the rest of the home directory hidden; no network domains allowed. | `harness/mk_settings.py` |
| 6. Monitor | Two layers. A `PreToolUse` hook applies fixed rules and writes the pause flag. Claude Code's auto mode supplies the model classifier, and a `PermissionDenied` hook turns its denials into the same pause. While the flag exists, the hook and the gateway refuse everything. | `harness/hook.py`, `harness/denied.py` |
| 7. Keep going | A `Stop` hook refuses to let an agent stop until every statement is on `main`, time is up, or the team is paused. A timer types a time-left reminder into the lead's window every five minutes. | `harness/keepgoing.py`, `harness/remind.sh` |
| 8. Cold start | Each agent is its own `claude` process in its own tmux window, started with the brief as the first user message and only shell and file tools. | `harness/run-agent.sh`, `docs/` |
| 9. Records | The hook logs every tool call and the gateway logs every request and merge, in a directory the sandbox hides. | `records/`, `harness/offline_monitor.py` |

## What is weaker than the original design

- **One OS account.** All agents, the gateway and the operator run as the same user with
  the same Claude login. The sandbox confines each agent's shell commands. The agent
  process itself sits outside it.
- **File tools rely on the hook.** The sandbox was set up and tested for shell commands.
  Paths given to Read, Edit, Write, Glob and Grep are checked by the fixed rules in
  `hook.py`. That path was never exercised: in every run the agents used only the shell.
- **Tests, not proofs.** Code that passes the frozen tests can still be wrong, and code
  under test could tamper with the test process. The merge job limits which paths may
  change; it does not inspect what the code does.
- **Helpers can write to `announce`.** Every agent gets INSERT and UPDATE on all of the
  lead's tables. A helper's row is stamped with the helper's own identity, so it cannot
  pass as the lead's, but readers have to look at the author. A stricter build would
  grant writes on `announce` and `assign` to the lead alone.
- **Removal is only half built.** `operator.sh remove` makes the hook and the gateway
  refuse a helper. Reopening its claimed tasks is left to the lead, and no helper was
  ever removed in a run.
- **Fixed rules are easy to dodge.** They exist to catch honest mistakes early and to
  trigger the pause. The sandbox is what holds.

## Quirks worth knowing

- **The door is a file relay because the sandbox blocks the alternatives.** Sandboxed
  commands could not reach localhost, and connecting to an existing Unix socket failed
  with "Operation not permitted" (both tested). A request file inside the workspace needs
  no permission at all.
- **tmux is out of the agents' reach.** Inside the sandbox, `tmux ls` cannot connect to
  the server's socket (tested), so an agent cannot type into another agent's window. The
  fixed rules in `hook.py` also block the command.
- **Headless sessions work without tmux.** Two `claude -p` sessions started at once from a
  plain shell, with no terminal, both ran and replied. The full team has not been run
  that way; it would need another way to tell agents that a pause is cleared.
- **Stub dotfiles appear inside each workspace.** Within the sandbox, protected names such
  as `.bashrc` and `.gitmodules` show up as untracked files, and Git warns that it cannot
  read `.gitmodules`. `setup.sh` adds `/.*` to each clone's `.git/info/exclude`.
- **New workspaces trigger the trust prompt.** An interactive session in a new folder asks
  whether to trust it, with "No" selected. Someone has to answer in each window before
  the run starts.
- **`--tools` takes a list and will swallow the prompt.** Put `--` before the prompt.
- **The classifier's path is untested.** `autoAllowBashIfSandboxed` is false so that
  sandboxed commands are not approved automatically, and the agents run in auto mode. The
  classifier never denied anything in any run, so the `PermissionDenied` hook and the
  pause it sets have not fired for real.
- **Stop hooks have a cap** on consecutive blocks, according to the documentation. The
  example raises it with `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, and `keepgoing.py` has its own guard against an agent
  that stops six times in ninety seconds.
- **Plain absolute paths worked** in the sandbox's `denyRead` and `denyWrite` lists.
- **Hooks run outside the sandbox.** That is why they can write the records and the pause
  flag where the agent's shell cannot.
- **The brief goes in the first user message**, so that a classifier judging each action
  against what the user asked for can see that the door was authorized.
- **Tools are cut to shell and files** with `--tools`, `--strict-mcp-config` and
  `--disable-slash-commands`. That removes web access, subagents, cross-session messaging
  and connectors, which is how "no messaging" is kept.
- **The statement time limit needs two locks.** A role-level `statement_timeout` can be
  reset by the agent, so the gateway also cancels the query from a timer.

## Running it

Prerequisites: `git`, `python3`, `uv`, `docker`, `bwrap`, `tmux`, `claude` (signed in, with
auto mode available).

    cd example
    ./setup.sh                  # venvs, database container, central repo, workspaces, settings
    harness/test_gateway.sh     # 15 checks on the gateway and merge job; resets afterwards
    harness/selftest.sh         # one short agent session that tries to break out; compare with "expected"
    ./launch.sh                 # tmux session: gateway, board, lead, h1, h2, h3, reminders
    tmux attach -t sealed-team  # answer the trust prompt in each agent window; watch "board"
    harness/operator.sh status  # also: resume | remove <id> | end | say <id> "<text>"
    python3 harness/offline_monitor.py
    ./teardown.sh --purge       # stop the session, remove the container, delete runtime files

Set `TEAM_REMOTE_CONTROL=1` before `./launch.sh` to start each agent with Remote Control.
Names, ports, team size and the time budget are in `config.json`. The briefs in `docs/`
name three helpers and a 45-minute budget; change them together with the config.

`setup.sh` hides from the agents every folder beside the path from your home directory
down to `example/`, plus common credential files. Add anything else private to
`extra_private_paths` in `config.json`.
