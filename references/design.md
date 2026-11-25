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
| 1 | **A board instead of private messages.** Agents share a database and a Git repository and nothing else. Five tables: `announce` (orders), `assign` (who is on what), `notes` (plans and progress), `subtasks` (the to-do list), `landed` (finished work). Claiming a task is one atomic update. A directed message (`team msg`) is a row in a sixth table, `messages`, that only the gateway writes. | A board survives an agent dying, makes nobody wait for a reply, can be read by a latecomer, and is a full record afterwards. Messages give a quick question to one peer without a private channel: every agent and the boss can read them. |
| 2 | **A fixed finish line that a machine checks.** The goal is split into statements. Work counts only when the merge job accepts it onto `main`: it merges the branch, refuses changes outside the allowed paths, runs the check where agents cannot reach, then moves `main`. | Agents report success optimistically, and nobody can read every diff. The merge job turns "done" from a claim into a fact. |
| 3 | **Identity comes from the channel.** Who sent a request is decided by where it arrived, never by a name the agent writes. | Records can be attributed, a claim means something, and orders can be told from notes. |
| 4 | **One door out.** One command (`team`) for everything shared, served by a gateway outside the agents' reach that stamps identity, enforces limits and logs. | One place to enforce, one place to log. |
| 5 | **Walls.** An agent writes only in its own workspace, cannot see the others or the harness, and has no network. Tools that cannot be walled are removed. | Without walls, rules 1 to 4 are only requests. |
| 6 | **Check before acting, and fail closed.** A monitor sees every command and edit first. A block pauses the whole team until the boss has reviewed it. | A team that keeps running while you investigate has time to try the next thing. |
| 7 | **Keep going until the check says done.** No agent may stop while statements are open and time remains, unless the run has stalled: no merge accepted for `stall_min`. | Agents stop early, after their own task or while waiting. The stall limit ends a team that is stuck instead of letting it idle until the budget is gone. |
| 8 | **A cold start from a brief.** Each agent is a separate session that starts from a short written brief. A helper's brief says only where the orders are. | Inherited context is a private channel the board does not record. |
| 9 | **Records out of reach.** Every tool call, gateway request and merge is logged where agents cannot read or write. | The monitor catches only what it was built for. The records catch the rest. |

The lead designs the tables and writes the orders. Helpers start knowing only where the
orders are, which keeps the briefs short and shows that the board carries everything.

## Python comes from uv

Every script of the harness is plain Python with no packages beyond the standard library. So
that a run does not depend on which `python3` a machine has, or on having one at all,
`setup.sh` has `uv` make one environment, `tools/py`, and everything runs on it: the shell
scripts call `harness/py`, the monitor's hooks name `tools/py/bin/python`, `bin/team` starts
itself with it, and `tools/bin/python3` gives it to the agents and to the merge job's check.
`uv` is called only at setup, never inside an agent's sandbox, so it needs no network and no
writable cache there. When `uv` has to download a Python it goes into `tools/python`, inside the
work directory, where the agents' sandbox and the merge job's sandbox can both read it.

## Writing a good task

- **A merge must be able to pass before the whole goal does.** If the only check is global,
  nothing can land until the end. Give each statement its own check.
- **Freeze the check's settings** along with the statements, and make the check reject its
  own escape hatches (skipped tests, suppressed errors).
- **Give every shared file one owner.** A file several statements must change is either
  prepared by the boss before launch or assigned to exactly one statement.
- **A check speaks through its exit status.** The merge job reads nothing else. A proof
  that only prints (`wc -l`, `cat`) convinces a reader, not the merge job.
- **Know how strong the check is.** A proof checker cannot be satisfied by a wrong proof.
  A test suite can be passed by wrong code.
- **Size it.** If one agent could finish in a few minutes, the team exercises nothing.

## What the template enforces, and what it only requests

| Part | Status |
|---|---|
| Writes outside the workspace, reading other workspaces or the harness, network access, reaching tmux | Enforced for shell commands by the sandbox (tested from inside an agent session) |
| No network for the shell, in every profile without `shell_net` | Enforced twice. The sandbox allows no domain. The monitor pauses the team on a Bash call that asks for network with `allowed_domains` (Claude Code 2.1.331 honoured that parameter: the shell fetched a page in all four profiles) or carries any parameter but `command`, `description`, `timeout` and `run_in_background`. The monitor rule is tested with stubs and by `selftest.sh` (its last step); not yet seen in a live session. |
| Reading the owner's files in the home directory (`~/.claude/history.jsonl`, `~/.claude/projects/`, credentials, any dot-folder) | Enforced for shell commands by the sandbox: every entry of `~/.claude` but `shell-snapshots/` and every dot-entry of `~` but the shell's own files, user-installed programs under `.local` and the uv and pip caches are hidden (`mk_settings.py`, run again at every launch). `~/.gitconfig` is hidden too, so the agents' environment sets `GIT_CONFIG_GLOBAL=/dev/null`. The monitor also pauses the team on the bare words `.claude` and `.ssh`, which a quoted or built path can get past. |
| The three rows above, in an unwalled run (`"sandbox": false`) | Requested for that run, not enforced: the sandbox is off, so only the monitor's fixed rules stand between the shell and those places, and they judge the command text. See "An unwalled run" below for every guarantee that changes. |
| Board permissions, statement time limit, atomic claims, one transaction per request | Enforced by the gateway (tested) |
| Every request answered | A request file the gateway cannot serve (over 1 MiB, not JSON, a link) is answered with an error and logged, never dropped (tested with stubs) |
| Only checked work reaches `main`; frozen paths; no direct pushes | Enforced by the merge job (tested) |
| `main` is closed once the run is complete | Enforced by the gateway: after `state/DONE`, `team mr` and `team precheck` are refused, also for a request that was waiting for the merge lock when the run completed; `status`, `sql`, `msg` and `push` (to the agent's own branch) still answer. Chosen after the live proof run, where a merge was accepted three minutes after completion: a late merge could only land if every statement still passed, but it would move `main` under the boss's `verify.py` and hand-back. Tested with stubs. |
| A statement's own check (`task.checks`) | Enforced by the merge job and `verify.py` exactly like `task.check`; shown only by stub-based tests |
| The boss under `/goal`, or an agent's own `/goal` with the `skills` knob on | Requested only (`references/goal.md`). The harness does not see the goal loop; it sees the tool calls and merges it causes. |
| Pause on a rule violation | Enforced by the hook (tested) |
| Agents learn that the run is over | `team status` and `team wait` exit 3 while the team is paused and 4 once the run is over for the agent (complete, stalled, out of time, removed), with the reason on stderr as well as stdout; `team wait` waits in the gateway and returns at once when either happens, so `team wait 100 \| grep ...` cannot hide the end. That an agent acts on it is only requested by the briefs. Tested with stubs. |
| Ending a stalled run (`stall_min`) | Enforced by the gateway: it writes `state/STALLED` from its 2-second watch loop and then refuses `sql`, `push` and `mr`; the Stop hook lets agents go. Pauses and down time before a resume are moved out of the stall clock (`state/stall_from`) the same way they are moved out of the deadline. A merge being checked when the limit passes gets its answer first. Tested with the stub tmux only; never seen in a real run. Agents are not shown the stall clock, so landing filler to reset it is not invited; nothing stops it either, beyond the check. A stall reopened with `boss.sh unstall` is kept as `records/stalled.<when reopened>.json`; `report.py`, `offline_monitor.py` and the archive's `STATUS.txt` list every stall, reopened ones included. |
| Pause when the model classifier denies an action | Built, never triggered in a run |
| Paths given to the file tools (Read, Edit, Write, Glob, Grep) | Checked by fixed rules in `hook.py` only; never exercised, since agents used the shell |
| Messages (`team msg`, `team inbox`) | Enforced by the gateway (tested with stubs, not yet in a real run): the sender is the spool the request came in by; unknown recipients, removed senders, a pause and the end of the time are refused; so is a body with a control or format character (an escape sequence or a carriage return could draw a forged header on the boss's screen), refused rather than cleaned so that what is stored under a sender's name is what it sent; every display (`team inbox`, `boss.sh messages`, the board window, the gateway window) also writes such characters as escapes and indents the lines of a body; the log holds every accepted message whole; `messages` and `message_reads` refuse every write, trigger, index, alter and drop through `team sql`, the lead's included. That an agent reads its inbox when `team status` says `unread messages` is only requested. |
| Authorship of board rows | A helper's rows default to its own name, and every request is logged under the true sender. A helper can still type another name into a column; the log shows who really wrote it. |
| Removing a helper | The gateway and monitor refuse it. Reopening its tasks is left to the lead. Never exercised. |
| Agents isolated from the boss's account | Not enforced. All sessions run as one OS user with one login. The sandbox confines their shell commands; the agent processes themselves are outside it. |
| Resuming after a crash | `launch.sh --resume` refuses unless the run is interrupted and its files check out, and gives back the time down measured from the gateway's heartbeat (tested with stubs). That the lead reopens the claims of helpers that do not return is only requested by its rejoining brief. A real crash and resume has never been run. |
| Putting a run away | `teardown.sh --archive` keeps only the repository, the records (with `run.json`, the run's facts, and `report.html`, its page) and `STATUS.txt`, writes beside the work directory and never into it, refuses to overwrite, and deletes nothing until the file has been read back. Tested with the stub tmux only; never used on a real run. Nothing stops a boss from leaving a run's files lying around instead. |
| Dry run of the merge job (`team precheck`) | Read-only by construction: the same merge, path rule and checks as `team mr`, in a private clone of `main` that is then deleted. It never moves `main`, is not recorded as a merge, and is refused whenever the door is (pause, removal, time up). It does not take the merge lock, so its verdict is for `main` at that moment and something else may land before `team mr`. Tested with stubs only; not yet used in a real run. |
| Honest results | A test suite is a weaker check than a proof. The merge job limits which paths change; it does not inspect what the code does. |
| Tools outside the agent's profile | Enforced twice: the session is started with only the profile's tools (`--tools`), and the monitor refuses any other tool. Tested with stubs only. |
| `WebFetch` only to public `http(s)` hosts | Enforced by fixed rules in `hook.py` (scheme, user names in URLs, loopback, link-local, private and other non-global addresses in any spelling, local-only names, and names that resolve to such an address within 2 s). A name that does not resolve in time is passed, and a name whose address changes between the check and the fetch is not caught. Tested with stubs only. |
| Pages read by agents with the `web` knob on | Not checked. A page can carry instructions; the monitor judges the agent's next action, not what it read. |
| A subagent's report to its agent (`SubagentHandback`) | Passed by the monitor where the profile grants `Agent`, from inside a subagent only, and recorded. Tested with stubs; not yet shown live (before the fix every report was refused). |
| Tool calls made inside a subagent (`subagents` on) | Shown live (the profiles proof run, Claude Code 2.1.331 and 2.1.332): the `PreToolUse` hook fires for them and the shell sandbox applies to them. A subagent's `head -1 harness/gateway.py` and its `Write` outside the workspace were blocked and paused the team, the pause named the parent agent, and the records tag each such call with a `subagent` field (19 recorded; `offline_monitor.py` counts them). |
| Skills and slash commands (`skills` on) | Each skill call passes the monitor and is recorded; the team skill itself is refused. What a skill then asks for goes through the monitor call by call. `/loop` and `/goal` are a second loop beside the Stop hook: they can keep an agent busy, never let it past a pause, a removal or the merge job. |
| Connectors (MCP servers) | Off in every profile (`--strict-mcp-config`, no server given). A connector acts outside the shell sandbox with its own credentials, and the monitor cannot judge what it does. Live sessions were still offered `EndConversation` and a plugin's tool (`mcp__easel__chart`) in every profile; the monitor refuses both, as it refuses every tool a profile does not grant. |

Exercised since: every profile, in the profiles proof run (one probe session per profile, and
one live team of the example task with a `sealed` lead and `research`, `allied` and `open`
helpers, 7 of 7 done), including pages fetched through a `web-fetch` subagent (whose report
the monitor then refused; fixed since, not yet re-shown). Not yet exercised in any run: an
`open` agent under `/goal`, splitting a task, moving a helper between crews, the
five-minute reminder, a slow check, a helper dying mid-task, a stalled run, teams larger than four,
resuming a run after a real crash (`launch.sh --resume` has run only against stub tmux and
claude), and archiving a real run (`teardown.sh --archive`). The run report (`report.py`) has been
rendered from a real run's records (seven agents, 33 minutes) and from a real archive older than
`run.json` (through its `STATUS.txt`); an archive with `run.json` has been written only in
stub-based tests.

A boss running under `/goal` and an agent running `/goal` inside the team have not been
exercised either.

## An unwalled run (`"sandbox": false`)

`"sandbox": false` in `config.json` writes every agent's settings with the shell sandbox's
`enabled` set to `false`. It exists for teams whose shell must reach other machines (SSH to an
HPC facility, for example): the sandbox forbids that, and opening only Unix sockets
(`allowAllUnixSockets`) also opened the boss's tmux server to a one-line script, which is
worse. It is a choice per run, made by the owner, on the view that agents are not
adversaries and the walls mostly guard against mistakes.

What stays exactly as in a walled run: the monitor hook on every tool call (same rules, same
records, same pause), the keep-going and permission-denied hooks, the profiles' tool lists,
the gateway (identity by spool, board permissions, limits) and the merge job, whose check
still runs in its own no-network `bwrap` sandbox. `GIT_CONFIG_GLOBAL=/dev/null` stays too.

What becomes a request in an unwalled run, because rule 5 (walls) is gone and rules 1 to 4
and 9 leaned on it:

| Guarantee | Walled run | Unwalled run |
|---|---|---|
| An agent writes only in its own workspace | Enforced (sandbox) | Requested. The monitor pauses on a command that names the harness, another workspace, `.claude`, `.ssh` or `board.db`; a script written with Write and then run is not looked into. |
| Agents cannot read the harness, records, state, task, other workspaces or the owner's home | Enforced (sandbox) | Requested, same monitor rules. Every other file the OS user can read is readable. |
| The shell has no network | Enforced twice | Requested. The monitor still pauses on `curl`, `wget`, `ssh` and the like, and on `allowed_domains` (meaningless with the sandbox off); any program can still open a connection. |
| tmux is out of reach | Enforced (sandbox) | Requested. The `tmux` rule sees the word; a script can reach the socket under `/tmp/tmux-<uid>/`. |
| One door: the board only through `team` | Enforced | Requested. An agent can open `state/board.db` directly, bypassing permissions and identity. |
| Identity comes from the channel | Enforced | Requested. An agent can write into another agent's spool and speak as it. |
| Only the merge job moves `main` | Enforced | Requested. The pre-receive hook refuses pushes, but `central.git` can be written directly. The merge job's checks can be edited. |
| A pause holds | Enforced | Requested. `state/HALT` can be deleted. |
| Records out of reach | Enforced | Requested. `records/` can be rewritten. |

An unwalled run says so wherever the boss looks: `setup.sh` and `launch.sh` print a warning,
`boss.sh status` and `offline_monitor.py` print a line, the run's page and the archive's
`STATUS.txt` name it, and `records/run.json` keeps `"sandbox": false`. `selftest.sh` skips its
wall steps (with the sandbox off they would reach the boss's tmux and the owner's prompt
history) and tests only the monitor. A resumed run reads `config.json` again, so it stays
unwalled; changing the flag between crash and resume changes the run, and `launch.sh` warns
again. Shown only by stub-based tests; no real unwalled run has been made.

## Resuming after a crash

Everything a run needs lives on disk: `main` in `central.git`, the board in `state/board.db`
(write-ahead log, survives a killed process), the clock and removals in `state/`, and each
agent's unmerged work in its workspace. The tmux session holds nothing that cannot be
rebuilt, so `launch.sh --resume` rebuilds it. The choices made:

- **Time down is given back, measured by a heartbeat.** The gateway writes `state/heartbeat`
  every 2 s; the time down is now minus that beat. The deadline (and the stall clock, when
  there is one) moves by that amount, the way `boss.sh resume` gives back a pause. A resume
  writes a fresh beat at once, so a second crash before the gateway beats cannot give the
  same time back twice. Without a heartbeat (a run older than it) the newest file in
  `state/` and `records/` stands in, and the record says so.
- **No second gateway.** A serving gateway holds an exclusive lock on `config.json`, so a
  resume goes ahead as soon as that lock is free, even a second after the gateway stopped,
  and is refused while anything holds it, even a gateway that has stopped beating. Only where
  the lock cannot be tested does the old guess (no beat in the last 10 s) decide.
- **Interrupted, ended, complete.** A run that had run out of time or stalled before it died
  is `ended`, not interrupted: nothing is resumed, it is archived. A paused run resumes
  paused, and gives back no time at resume: clearing the pause gives back both.
- **Fresh sessions with a rejoining brief, not `claude --continue`.** It keeps the cold-start
  rule (8): what an agent knows comes from the board and its workspace, not from a
  transcript the harness does not control. The cost is that each agent spends its first
  minutes finding its place.
- **Removed helpers stay removed** and get no window; the lead's rejoining brief names them
  so their claims are reopened at once.

What a resume does not cover: a lost disk (copy `central.git`, `records/` and a `sqlite3
.backup` of the board elsewhere), a crash in the middle of a merge (the scratch worktree
under `state/ci/` is left behind; `main` moves only by one atomic ref update, so it is
either merged or not), and an agent's train of thought.

## Profiles

The sealed team is the default because every wall in it has been tested from inside a
session. Each wider profile adds one kind of reach and keeps every wall of the narrower
one: the shell sandbox is identical in the first four (no network domains, and the monitor pauses the
team on a Bash call that asks for one with `allowed_domains`), and the monitor
refuses whatever the profile does not grant. `remote`, below, is the exception.

A profile is a set of four knobs: `web` (`WebSearch`, `WebFetch`), `subagents` (`Agent`, and
`SubagentHandback` from inside a subagent), `skills` (`Skill` and slash commands) and
`shell_net` (the shell's `profiles.NET_CMDS`, unwalled runs only). The five named profiles are
presets for knob sets (`sealed` none, `research` `web`, `allied` adds `subagents`, `open` adds
`skills`, `remote` all four), and each starts exactly the session it did when they were a fixed
list. `config.json` may also give a knob object (`{"base": "open", "web": false}`) or a
name from its `"profiles"` map. One function in `harness/profiles.py` resolves every one of
them; the monitor, `run-agent.sh`, `selftest.sh`, `boss.sh`, `offline_monitor.py`, `report.py`
and the archive's `run.json` all call it, so the session's `--tools` and what the monitor passes
cannot drift apart. A value it cannot resolve fails closed: `setup.sh` refuses it, and the
monitor grants such an agent no tool at all. The knobs are independent because each one adds a
tool the monitor already judges call by call; whether a combination nobody had thought
through weakens anything was tested, not assumed: `references/decisions/knobs.md` records the
hypotheses, experiments and verdicts. The sandbox is not a knob: it stays one setting for the
whole team, because one unwalled agent could reach the board file, `central.git` and the other
workspaces that the walls protect for everyone.

What still holds with `skills` on (`open`): the monitor sees every tool call the session and its subagents make, a pause
refuses them all (skills included), `tmux` and `claude` are blocked in the shell, and only
the merge job moves `main`. What does not: the agent sees the owner's installed skills, a
skill brings its own instructions into the session, and `/loop` or `/goal` can keep an
agent working on its own schedule. The Stop hook still refuses to let it stop early, and
still lets it stop when the run is over.

`shell_net` (in the `remote` preset: `open` plus this knob) gives a shell that may run `ssh`, `scp`, `sftp`, `rsync`, `curl` and `wget`
(`profiles.NET_CMDS`), for work on another machine. It is the one knob that does not keep
every wall of the narrower profile, so it exists only in an unwalled run (`"sandbox": false`):
with the sandbox on those commands could reach nothing, and `setup.sh` refuses it (`profiles.py
--check`); the monitor also passes them only while the sandbox is off, as a second lock. Every
other monitor rule holds for it (`tmux`, `screen`, `claude`, `sudo`, `su`, `nc` and `socat`,
`git push`, the harness paths, `board.db`, `.ssh`, other workspaces, the pause), and so does a
rule only it has: a network command aimed at this machine (`localhost`, `127.*`, `::1`, its own
host name) pauses the team, since `ssh localhost 'tmux ls'` would run what the `tmux` rule
refuses. That rule reads the command text and is easy to get past (an alias in `~/.ssh/config`,
an address the rule does not list): it guards against mistakes, as everything does in an
unwalled run. `allowed_domains` means nothing with the sandbox off, so with `shell_net` it is
refused without a pause. What the agent does on the other machine is out of the monitor's
sight: it sees the command line, not what runs there. Tested with stubs
only.

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

## Putting a run away

A finished or abandoned run leaves two kinds of file. The repository and the records have
lasting value: one is the work, the other the audit. The workspaces, the board, the tools
and the settings do not, and they are worse than useless afterwards, because they look
live. A later boss session that searches the work directory and finds a board saying "h2
owns intervals" may act on it. The agents are not at risk: they cannot read `records/` or
`state/`.

So `./teardown.sh --archive` seals the two lasting parts into one dated file outside the
work directory, puts a plain status line on top (`abandoned run, stopped 14:41, 4 of 7
done, not verified`), and then deletes the rest. The facts the run report needs that lived in
`state/` and `config.json` (when the run started and ended and how, what was done, the agents and
their profiles, removals) go into the archived records as `run.json`, and the final page as
`report.html`, so the archive alone can show the run truthfully. "Verified" is judged by running
`verify.py` when the archive is made, not taken from the merge job's word. `--purge`
remains for runs with nothing to keep; it is not offered where unverified work may be
lost, such as after a crash.

## Reading a run afterwards

`harness/offline_monitor.py` is text for the boss to scan for trouble. `harness/report.py` is
a page for the owner: it shows at a glance how much was done, a timeline of the run to scale
(each agent's activity, every merge, block, pause, removal and time down), and the tables
behind it. Its time is the running time: pauses and the time down before a resume are given
back to the deadline, so they are stated beside it and do not count (`harness/runclock.py`;
`boss.sh status` uses it for "RUN COMPLETE in N min" too). It reads `config.json`, `state/`
and `records/` and writes nothing else, so it can be run at any time. On an archive it reads `records/` alone, and the run's facts from
`records/run.json` (or, for an archive older than that, from `STATUS.txt`, which does not say
the profiles or when a helper was removed). It is one file with no external scripts, styles
or fonts, so it can be mailed or opened offline, and everything taken from the records is
escaped: a merge title or a blocked command is text an agent wrote, and the page must not run
it.

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
- **A narrower monitor rule is a hole.** The rule for `.claude` and `.ssh` was once narrowed to
  "a path into them", so that an agent could grep for the word. A quoted or built path
  (`wc -c ~/'.claude'/history.jsonl`) then passed, and the sandbox did not hide that file: a
  session read the owner's prompt history with no pause. The bare-word rule is back, and the
  sandbox now hides the files themselves; a mention of the word is a known false alarm.
