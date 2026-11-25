# How the template uses Claude Code

Which feature implements each part, and the quirks met on Claude Code 2.1.323 on Linux.
Check flags and settings against your own version.

| Part | Implementation | File |
|---|---|---|
| Separate sessions | One `claude` process per tmux window, started with the brief as its first message | `harness/run-agent.sh`, `launch.sh` |
| Profiles | `--tools` gets the profile's list; `sealed`, `research` and `allied` add `--disable-slash-commands`, `open` leaves it out and adds `Skill`. `--strict-mcp-config` with no server keeps connectors off in every profile (a plugin's tools may still be offered; the monitor refuses them). The default, `sealed`, is `--tools Bash,Edit,Read,Write,Glob,Grep`: no web access, subagents, Claude Code's own cross-session messaging or connectors. Messages between agents go through the gateway instead (`team msg`) | `harness/profiles.py`, `harness/run-agent.sh` |
| Walls | The shell sandbox, per agent: `denyRead` on the harness, records, state, task files, other workspaces and the rest of the home directory (every entry of `~/.claude` but `shell-snapshots/`, every dot-entry of `~` but a short list); no network domains, and the monitor refuses a Bash call that asks for some (`allowed_domains`) | `harness/mk_settings.py`, `harness/hook.py` |
| Door | `team` writes a request file into `.gw/req` in the workspace and waits for the reply in `.gw/resp` | `bin/team` |
| Board | One SQLite file in `state/`, opened only by the gateway. `me()` is a SQL function the gateway binds per agent; an authorizer limits what helpers may run, and refuses every write to the gateway's own tables (`messages`, `message_reads`) | `harness/gateway.py` (`Board`) |
| Merge job | Scratch worktree, path allowlist, the task's check inside bubblewrap with no network | `harness/gateway.py` (`do_mr`, `run_check`) |
| Monitor | `PreToolUse` hook with fixed rules; auto mode's classifier, whose denials reach a `PermissionDenied` hook; both write the pause flag | `harness/hook.py`, `harness/denied.py` |
| Keep going | `Stop` hook; a timer types a reminder into the lead's window. The hook lets agents stop once the run is done, out of time, paused or stalled (`state/STALLED`, written by the gateway) | `harness/keepgoing.py`, `harness/remind.sh` |
| Pre-launch test | `selftest.sh [agent]` runs two short `claude -p` sessions with that agent's settings (Stop hook removed) and its profile's `--tools` and slash setting, from `profiles.py`, as `run-agent.sh` does | `harness/selftest.sh` |
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
- **New workspaces trigger the trust prompt.** The cursor has been seen on either answer, and
  once an answer of "No, exit" quit the session while the old `boss.sh trust` reported
  "answered yes". `harness/boss.sh trust` now moves the cursor only when it is not on "Yes",
  and reports `started` only once the session's name (`team-<id>`) is on screen and the
  prompt is gone. Once a folder is trusted the prompt does not return.
- **`--tools` takes a list and will swallow the prompt.** Put `--` before the prompt.
- **Hooks run outside the sandbox.** That is why they can write the records and the pause
  flag where the agent's shell cannot.
- **The Bash tool takes `allowed_domains`.** On 2.1.331 and 2.1.332 a Bash call with
  `allowed_domains: ["example.com"]` fetched the page from the shell (HTTP 200) in every
  profile, although the settings allow no domain. So `hook.py` pauses the team on a non-empty
  `allowed_domains`, and on any Bash parameter but `command`, `description`, `timeout` and
  `run_in_background` (the only ones the proof runs' 1,866 recorded calls carried, besides
  `allowed_domains`). The last step of `selftest.sh` shows it before launch.
- **`"sandbox": false` writes `"enabled": false` and keeps the rest.** In an unwalled run the
  settings keep the `denyRead` list, the empty `allowedDomains` and both flags below; with
  `enabled` false Claude Code applies none of them, so the shell runs as the OS user with the
  network. The hooks and `env` are unchanged: hooks never ran inside the sandbox, and
  `GIT_CONFIG_GLOBAL=/dev/null` keeps every agent's Git on its own workspace config. In the
  owner's trials, the `bridge` CLI worked at once with the sandbox off; with it on, it failed
  on the Unix socket. Not yet run as a whole team.
- **`autoAllowBashIfSandboxed` is false**, so that sandboxed commands are not approved
  automatically and the agents' commands go through auto mode.
- **Stop hooks have a cap** on consecutive blocks, according to the documentation. The
  template raises it with `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`, and `keepgoing.py` lets an
  agent go if it stops six times in ninety seconds.
- **The brief is the first user message**, so that a classifier judging each action against
  what the user asked for can see that the door was authorized.
- **Typing into a window takes two steps:** `tmux send-keys -l '<text>'`, a short pause,
  then `tmux send-keys Enter`.
- **`setup.sh` hides the home directory** (and `launch.sh` names it again before every launch,
  since only entries that exist can be named): every entry beside the path from the home
  directory down to the work directory (all of them when the work directory is elsewhere),
  every dot-entry of `~` except `.bashrc`, `.profile`, `.bash_profile`, `.bash_logout`,
  `.local/bin`, `.local/lib`, `.local/share/uv`, `.local/share/claude` (user-installed programs)
  and `.cache/uv`, `.cache/pip` (package caches; add more with `extra_readable_home_paths` in
  `config.json`), and every entry of
  Claude Code's config folder (`~/.claude`, or `$CLAUDE_CONFIG_DIR`, as `hook.py` reads it)
  except `shell-snapshots/`. That one must stay readable: Claude Code starts every Bash command
  by sourcing a snapshot of the owner's shell from there (functions, options and `PATH`). An
  entry made after the launch is not hidden. A hidden entry that is gone by the time a command
  runs is skipped (the 2.1.332 binary says so in its sandbox log text). Add anything else in
  `extra_private_paths`. Builds from 2.1.332 also know `sandbox.filesystem.allowRead` and
  `denyRead` globs, which could deny the whole folder and re-allow `shell-snapshots/`, covering
  later entries too; the template does not use them, because they have not been tried in a
  live session. `harness/selftest.sh` step 13 reads the history from inside a session
  (`c=.cla; wc -c < ~/${c}ude/history.jsonl`, spelled so that the monitor lets it through to the
  sandbox); it must print `0` or an error. Not yet run live with this list.
- **`/goal`'s evaluator reads conversation text only.** It cannot run the check itself, so
  `verify.py` prints a statement's own check command under its `PASS` or `FAIL` line: one
  printed block then shows the command, its last output line and the verdict.
- **`WebFetch` goes where `Agent` is.** Measured on 2.1.331 and 2.1.332: a `research` session
  (`--tools ...,WebSearch,WebFetch`) has the `WebFetch` tool and fetches pages itself. Where
  `Agent` is in the list too (`allied`, `open`), the session reports no `WebFetch`, and Claude
  Code fetches pages through a `web-fetch` subagent instead. The profiles keep `WebFetch` in
  every list (the name is valid and harmless where it is dropped).
- **Subagent tool calls and the hook.** Shown live: `PreToolUse` fires for calls made inside a
  subagent, and the shell sandbox applies to them. A subagent's `head -1 harness/gateway.py`
  and its `Write` outside the workspace were blocked, the pause (`state/HALT`) named the parent
  agent, and `hook.py` recorded each such call with a `subagent` field (`agent_type`, such as
  `general-purpose` or `web-fetch`).
- **`--tools` and `--strict-mcp-config` are not the whole list.** Live interactive sessions were
  also offered `EndConversation` and `mcp__easel__chart` (a tool a plugin registers) in every
  profile. The monitor refuses both, without a pause, as it refuses every tool a profile does
  not grant.
- **Tool names the monitor knows:** `WebSearch` (input `query`), `WebFetch` (`url`, `prompt`),
  `Agent` (`prompt`, `description`, `subagent_type`, `run_in_background`), `Skill` (`skill`, `args`),
  `SubagentHandback` (`message`).
- **A subagent reports through `SubagentHandback`.** That is the subagent's own tool, so no
  profile lists it and `--tools` is left as it is. The monitor refused it until the live
  profiles proof run showed that 0 of 5 subagent reports arrived: `Agent` was useless, and a
  page fetched by the `web-fetch` subagent never reached the agent. `hook.py` now passes it,
  and records it, when the profile grants `Agent` and the call comes from inside a subagent
  (it carries `agent_id` or `agent_type`, as all 17 recorded calls did). Not yet shown live:
  `harness/selftest.sh <an allied or open agent>` step 14 asks for a subagent that runs
  `echo handback-ok`; the reply must show `handback-ok`, and the PASS line says the monitor
  passed the report.
- **Headless sessions work without tmux.** Two `claude -p` sessions started at once from a
  plain shell both ran. The team has not been run that way.
