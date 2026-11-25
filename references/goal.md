# Running `/goal` with the team

Claude Code's `/goal` loop keeps a session working until a condition holds. There are two
ways to use it with the team, and both are allowed:

| Way | Who runs `/goal` | What the loop's condition is | Use it when |
|---|---|---|---|
| The boss under `/goal` | The boss, in its own session | `harness/verify.py` prints PASS for every statement | The whole task is the boss's goal (the main way) |
| An agent under `/goal` | One agent with the `skills` knob on (`open`), inside the team | The agent's own part is merged | An agent wants its own loop for the statement it claimed |

Neither way starts a new tmux session or a new Claude Code session from inside the team.

## The boss under `/goal`

The boss may drive its loop with a make-goal contract it wrote itself (`.goal/<slug>.json`).

### 1. The boss's own condition

The proof of the whole task is the output of `harness/py harness/verify.py`: it clones
`main` fresh, runs every statement's own check in the merge job's sandbox, and confirms the
frozen files are unchanged. The `/goal` evaluator reads conversation text only, so the
boss must print that output. Under each statement that has its own check, `verify.py`
prints `check: <command>`, so the evaluator sees the item's command, its last output line
and `PASS` together. A condition that fits:

> Every statement passes on a fresh checkout of main, proven by printing the output of
> `harness/py harness/verify.py`, whose last line reads `<m> of <m> statements pass`.

Do not prove an item by running its command in a workspace: only `main` counts. Each turn
of the loop is one round of `SKILL.md` step 6 (`wait-run.sh`, then act on what it printed).

### 2. What to watch for

- **A pause is not the loop's to clear.** `/goal` keeps the boss working; it does not
  authorize `harness/boss.sh resume` without reading the blocked action (`SKILL.md`, step 6).
- **No coaching.** The boss's messages to the team carry facts about the run, never hints
  about the work, however long the loop runs.
- **Bound the loop by the run.** Choose `budget_min` so the team's time ends before the
  contract's ceiling. When `wait-run.sh` prints `TIME UP` or `STALLED`, the run is over:
  print `verify.py`'s output as the gap report, with the ledger digest and the claims file,
  and stop. That is the contract's bounded termination, not a reason to launch a second run.
- **No new goals mid-run** unless the user approved an envelope for them up front.
- **Set the iteration floor to 1.** make-goal's ledger item asks for at least N completed
  iterations (3 in the live run). For a boss contract the merge job is already the checker:
  in the live run the team was done in 3.0 minutes, and the floor of 3 cost about 13 more
  minutes of turns that only re-checked a finished result. Write the ledger item with a
  floor of 1 before you start.
- **Archive inside the guardrails.** `./teardown.sh --archive` writes beside the work
  directory by default, which can break a contract's "do not write outside ..." guardrail.
  Pass the folder: `./teardown.sh --archive <a folder the contract allows>`.
- **Not unattended.** Claude Code's own safety checks can stop the loop. In the live run's
  first attempt an API safety classifier stopped the boss seven minutes in, after the team
  was already done ("Goal paused · send a message to continue"), and it stayed there until a
  person sent a message. Tell the user to look in on a boss under `/goal`.

## An agent under `/goal`

With the `skills` knob on (the `open` and `remote` presets, or any profile that turns it on) an
agent has slash commands and skills, so it may run under
`/goal` in its own session for its own part of the work. It is allowed, not expected:
nothing in the briefs asks for it.

An agent cannot start `/goal` by itself. In the live profiles proof run (Claude Code 2.1.331)
an `open` agent that tried was told "goal is a UI command, not a skill" before the monitor
was reached: `/goal` is typed into the session's prompt. `boss.sh say` cannot type it either,
because it puts `[boss] ` in front. So the boss puts an agent under `/goal` with

    harness/boss.sh slash <id> "/goal <condition>"

which types that one line as it is and presses Enter. It is refused for an agent whose profile
does not have the `skills` knob on, for a removed agent, for `all`, and for anything but one line of printable text
that starts with `/`. Agree the condition with the user first (see "Done means merged" below),
and treat it like any other message to the team: facts and a bound, not hints about the work.
Not yet shown live: no agent has been put under `/goal` this way, and how its loop and the
harness's Stop hook take turns is unproven.

- **Done means merged.** The agent's condition should be "`team mr` printed ACCEPTED for
  `<statement>`" (or `team status` lists it as done), not only that a local check passed.
  The merge job is a stronger judge than the evaluator, which reads text only.
- **Two loops.** The Stop hook keeps the agent going until the run is over; `/goal` keeps it
  going until its condition. When the goal is met first, the Stop hook sends the agent back
  to the board, which is what the team wants. When the run ends first (complete, time up,
  stalled, paused, removed), the Stop hook lets go but `/goal` may not; every door request
  is then refused, so the loop can only spin. Give the goal a small bound, such as "or
  `team status` shows TEAM PAUSED, STALLED, TIME IS UP or RUN COMPLETE".
- **Claims still go quiet.** A helper inside its own goal loop must still post progress to
  the board; the lead reopens a claim that goes quiet, whatever the goal loop thinks.
- **Wake-ups during a pause.** `/loop` or a goal turn can wake a paused agent. The monitor
  refuses every tool call while the team is paused, skills included, so a wake-up costs
  tokens and does nothing.
- **Subagents.** make-goal's casts delegate to subagents. The monitor and the shell sandbox
  apply to the tool calls made inside them (shown live in the profiles proof run; see
  `references/design.md`), and a subagent's report comes back through `SubagentHandback`,
  which the monitor passes on `open`. What a subagent reads and decides is still out of the
  agent's sight. The merge job still checks everything that lands.
- **Its files.** The contract, ledger and claims files live in the agent's workspace under
  `.goal/`. They are not part of the work: `setup.sh` excludes every dot-file at the top of
  a workspace from Git, and a merge that adds them is refused unless the allowed paths
  happen to cover `.goal/`.

## What stays forbidden, in every profile and either way

- Starting `tmux`, another `claude` session, or make-goal's own launcher (`launch-tmux.sh`)
  from inside the team. The monitor blocks `tmux` and `claude` and pauses the team.
- Invoking the team skill itself from inside the team (the monitor refuses it).
- Network from the shell, writes outside the agent's workspace, direct pushes. Only the
  merge job moves `main`.
- Connectors (MCP servers).

## Shown live

A boss under `/goal` (the live goal proof run, template at commit 7caf0a9, Claude Code
2.1.332): its second attempt reached "Goal achieved" in 21.2 minutes over 3 turns, of which
the team itself needed 3.0 minutes for 7 of 7 statements; the evaluator quoted `verify.py`'s
"7 of 7 statements pass" as its evidence. The first attempt was paused by a safety classifier
after the team was done (see "Not unattended" above).

## Not yet shown

No agent has run `/goal` inside the team (`boss.sh slash` is tested with the stub tmux only).
The merge job's report without `task.attempted_if`, and `test_gateway.sh` on such a task,
are tested with stubs only (`tests/team/test_fixes.sh`, section T).
