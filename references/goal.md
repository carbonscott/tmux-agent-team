# Running the team from a make-goal contract

The make-goal skill writes a contract for Claude Code's `/goal` loop: a JSON file whose
`done_when` list holds checkable end states, each with its proof ("..., proven by printing
the output of `<command>`"). There are two ways to use such a contract with the team, and
both are allowed:

| Way | Who runs `/goal` | What the loop's condition is | Use it when |
|---|---|---|---|
| The boss under `/goal` | The boss, in its own session | `harness/verify.py` prints PASS for every statement | The whole contract is the team's task (the main way) |
| An agent under `/goal` | One agent on the `open` profile, inside the team | The agent's own part is merged | An agent wants its own loop for the statement it claimed |

Neither way starts a new tmux session or a new Claude Code session from inside the team.

## The boss under `/goal`

### 1. Turn the contract into the team's task

    python3 harness/from-goal.py .goal/<slug>.json            # prints the plan; writes nothing
    python3 harness/from-goal.py .goal/<slug>.json --apply --allowed '<regex>' [...]

Each `done_when` item that names a command in backticks becomes a statement whose check is
that command (`task.checks` in `config.json`). The command runs in the merge job's sandbox,
at the repository root, with no network, and must exit 0 exactly when the item holds:
`grep -x ok out/alpha.txt` does; a command that only prints something for a reader to judge
does not. Items without a command go to `skipped`. `--allowed` sets the paths a merge may
change; write it from the contract's guardrails (`Do not modify any file outside out/`
becomes `--allowed 'out/.*'`). `--apply` also writes `task/seed/STATEMENTS.md` with each
statement's text and the guardrails. Add the frozen files the checks need to `task/seed/`
yourself, then follow `SKILL.md` from step 3. `from-goal.py` refuses an `exploratory`
contract (findings and decisions have no exit status to check), a contract with no item
that names a command, and a work directory where `setup.sh` has already run.

### 2. The boss's own condition

The proof of the whole contract is the output of `python3 harness/verify.py`: it clones
`main` fresh, runs every statement's own check in the merge job's sandbox, and confirms the
frozen files are unchanged. The `/goal` evaluator reads conversation text only, so the
boss must print that output. A condition that fits:

> Every statement passes on a fresh checkout of main, proven by printing the output of
> `python3 harness/verify.py`, whose last line reads `<m> of <m> statements pass`.

### 3. What the boss still owns

The skipped items are about the runner's own record, not the work, so no agent can do them:

| Skipped item | How the boss meets it |
|---|---|
| The claims file | Write it from `records/merges.jsonl`: each accepted merge (its `main` commit) is `verified` evidence for its statement; what a helper wrote on the board is `inherited` |
| The ledger digest | One iteration is one `harness/wait-run.sh 540` cycle: `delegated` is the helpers, `new` is what landed in that cycle |

The contract's `operating_mode` asks the runner to delegate to subagents. With a team, the
helpers are the delegation, and the boss uses no subagents for the work. Say so in the
ledger rather than starting subagents to satisfy the wording.

### 4. What to watch for

- **A pause is not the loop's to clear.** `/goal` keeps the boss working; it does not
  authorize `harness/boss.sh resume` without reading the blocked action (`SKILL.md`, step 6).
- **No coaching.** The boss's messages to the team carry facts about the run, never hints
  about the work, however long the loop runs.
- **Bound the loop by the run.** When `wait-run.sh` prints `TIME UP` or `STALLED`, the run
  is over: print `verify.py`'s output as the gap report and stop. That is the contract's
  bounded termination, not a reason to launch a second run.
- **No new goals mid-run** unless the user approved an envelope for them up front.

## An agent under `/goal`

On the `open` profile an agent has slash commands, skills and subagents, so it may start
`/goal` in its own session for its own part of the work. It is allowed, not expected.

- **Done means merged.** The agent's condition should be "`team mr` printed ACCEPTED for
  `<statement>`" (or `team status` lists it as done), not only that a local check passed.
  The merge job is a stronger judge than the evaluator, which reads text only.
- **Two loops.** The Stop hook keeps the agent going until the run is over; `/goal` keeps it
  going until its condition. When the goal is met first, the Stop hook sends the agent back
  to the board, which is what the team wants. When the run ends first (complete, time up,
  stalled, paused, removed), the Stop hook lets go but `/goal` may not; every door request
  is then refused, so the loop can only spin. Give the goal a small bound.
- **Wake-ups during a pause.** `/loop` or a goal turn can wake a paused agent. The monitor
  refuses every tool call while the team is paused, skills included, so a wake-up costs
  tokens and does nothing.
- **Subagents.** make-goal's casts delegate to subagents. Whether the monitor sees the tool
  calls made inside them is unproven (`references/design.md`); treat their work as
  unmonitored until a run shows otherwise. The merge job still checks everything that lands.
- **Its files.** The contract, ledger and claims files live in the agent's workspace under
  `.goal/`. They are not part of the work, so the agent should not commit them; a merge
  that adds them is refused unless the allowed paths happen to cover `.goal/`.

## What stays forbidden, in every profile and either way

- Starting `tmux`, another `claude` session, or make-goal's own launcher from inside the
  team. The monitor blocks `tmux` and `claude` and pauses the team.
- Invoking the team skill itself from inside the team (the monitor refuses it).
- Network from the shell, writes outside the agent's workspace, direct pushes. Only the
  merge job moves `main`.
- Connectors (MCP servers).
