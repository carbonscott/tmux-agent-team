# How the template uses Claude Code

Which feature implements each part, and the quirks met on Claude Code 2.1.323 on Linux.
Check flags and settings against your own version.

| Part | Implementation | File |
|---|---|---|
| Separate sessions | One `claude` process per tmux window, started with the brief as its first message | `harness/run-agent.sh`, `launch.sh` |
| Only shell and file tools | `--tools Bash,Edit,Read,Write,Glob,Grep --strict-mcp-config --disable-slash-commands` removes web access, subagents, cross-session messaging and connectors | `harness/run-agent.sh` |
| Walls | The shell sandbox, per agent: `denyRead` on the harness, records, state, task files, other workspaces and the rest of the home directory; no network domains | `harness/mk_settings.py` |
| Door | `team` writes a request file into `.gw/req` in the workspace and waits for the reply in `.gw/resp` | `bin/team` |
| Board | One SQLite file in `state/`, opened only by the gateway. `me()` is a SQL function the gateway binds per agent; an authorizer limits what helpers may run | `harness/gateway.py` (`Board`) |
| Merge job | Scratch worktree, path allowlist, the task's check inside bubblewrap with no network | `harness/gateway.py` (`do_mr`, `run_check`) |
| Monitor | `PreToolUse` hook with fixed rules; auto mode's classifier, whose denials reach a `PermissionDenied` hook; both write the pause flag | `harness/hook.py`, `harness/denied.py` |
| Keep going | `Stop` hook; a timer types a reminder into the lead's window | `harness/keepgoing.py`, `harness/remind.sh` |
| Records | Hook and gateway logs in `records/`, which the sandbox hides | `harness/offline_monitor.py` |

## Quirks

- **The door is a file relay because the sandbox blocks the alternatives.** Sandboxed
  commands could not reach localhost, and connecting to a Unix socket failed with
  "Operation not permitted" (both tested).
- **For the same reason agents cannot reach tmux** (tested in `selftest.sh`, step 7).
- **Stub dotfiles appear inside each workspace.** Within the sandbox, protected names such
  as `.bashrc` and `.gitmodules` show up as untracked files, and Git warns that it cannot
  read `.gitmodules`. `setup.sh` adds `/.*` to each clone's `.git/info/exclude`.
- **New workspaces trigger the trust prompt**, with "No" selected. `harness/boss.sh trust`
  answers it in every agent window. Once a folder is trusted the prompt does not return.
- **`--tools` takes a list and will swallow the prompt.** Put `--` before the prompt.
- **Hooks run outside the sandbox.** That is why they can write the records and the pause
  flag where the agent's shell cannot.
- **`autoAllowBashIfSandboxed` is false**, so that sandboxed commands are not approved
  automatically and the agents' commands go through auto mode.
- **Stop hooks have a cap** on consecutive blocks, according to the documentation. The
  template raises it with `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, and `keepgoing.py` lets an
  agent go if it stops six times in ninety seconds.
- **The brief is the first user message**, so that a classifier judging each action against
  what the user asked for can see that the door was authorized.
- **Typing into a window takes two steps:** `tmux send-keys -l '<text>'`, a short pause,
  then `tmux send-keys Enter`.
- **`setup.sh` hides the home directory** by listing every folder beside the path from the
  home directory down to the work directory, plus common credential files. Add anything
  else in `extra_private_paths`.
- **Headless sessions work without tmux.** Two `claude -p` sessions started at once from a
  plain shell both ran. The team has not been run that way.
