# How the template uses Claude Code

Which feature implements each part, and the quirks met on Claude Code 2.1.323 on Linux.
Check flags and settings against your own version.

| Part | Implementation | File |
|---|---|---|
| Separate sessions | One `claude` process per tmux window, started with the brief as its first message | `harness/run-agent.sh`, `launch.sh` |
| Profiles | `--tools` gets the profile's list; `sealed`, `research` and `allied` add `--disable-slash-commands`, `open` leaves it out and adds `Skill`. `--strict-mcp-config` with no server keeps connectors off in every profile. The default, `sealed`, is `--tools Bash,Edit,Read,Write,Glob,Grep`: no web access, subagents, Claude Code's own cross-session messaging or connectors. Messages between agents go through the gateway instead (`team msg`) | `harness/profiles.py`, `harness/run-agent.sh` |
| Walls | The shell sandbox, per agent: `denyRead` on the harness, records, state, task files, other workspaces and the rest of the home directory; no network domains | `harness/mk_settings.py` |
| Door | `team` writes a request file into `.gw/req` in the workspace and waits for the reply in `.gw/resp` | `bin/team` |
| Board | One SQLite file in `state/`, opened only by the gateway. `me()` is a SQL function the gateway binds per agent; an authorizer limits what helpers may run, and refuses every write to the gateway's own tables (`messages`, `message_reads`) | `harness/gateway.py` (`Board`) |
| Merge job | Scratch worktree, path allowlist, the task's check inside bubblewrap with no network | `harness/gateway.py` (`do_mr`, `run_check`) |
| Monitor | `PreToolUse` hook with fixed rules; auto mode's classifier, whose denials reach a `PermissionDenied` hook; both write the pause flag | `harness/hook.py`, `harness/denied.py` |
| Keep going | `Stop` hook; a timer types a reminder into the lead's window. The hook lets agents stop once the run is done, out of time, paused or stalled (`state/STALLED`, written by the gateway) | `harness/keepgoing.py`, `harness/remind.sh` |
| Rejoining after a crash | `launch.sh --resume` starts every agent as a new session (`run-agent.sh <id> --resume`) with the rejoining brief from `render.py --resume`; `claude --continue` is not used | `launch.sh`, `harness/runstate.py`, `docs/*-rejoin.md` |
| Records | Hook and gateway logs in `records/`, which the sandbox hides | `harness/offline_monitor.py` |
| Goal contracts | A make-goal contract for `/goal` becomes the task (`task.checks`); the boss may run under `/goal` with `verify.py` as its proof | `harness/from-goal.py`, `references/goal.md` |

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
- **`/goal`'s evaluator reads conversation text only.** It cannot run the check itself, so
  `verify.py` prints a statement's own check command under its `PASS` or `FAIL` line: one
  printed block then shows the command, its last output line and the verdict.
- **`WebFetch` may be missing from a session.** On Claude Code 2.1.331 a session started with
  `--tools Bash,WebSearch,WebFetch,Agent,Skill` reported Agent, Bash, Skill and WebSearch,
  and no WebFetch; pages were fetched by a `web-fetch` subagent, which needs `Agent`. The
  profiles keep `WebFetch` (the name is valid and harmless where absent), so on such a build
  only `allied` and `open` can fetch pages.
- **Subagent tool calls and the hook.** It is not known whether `PreToolUse` fires for calls
  made inside a subagent. `hook.py` records a call that carries `agent_id` or `agent_type`
  with a `subagent` field, so the first real `allied` run will show it either way.
- **Tool names the monitor knows:** `WebSearch` (input `query`), `WebFetch` (`url`, `prompt`),
  `Agent` (`prompt`, `description`, `subagent_type`), `Skill` (`skill`, `args`).
- **Headless sessions work without tmux.** Two `claude -p` sessions started at once from a
  plain shell both ran. The team has not been run that way.
