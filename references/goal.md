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

The plan is JSON: `statements` (each with `name`, `check`, `text`), `skipped`, and the
contract's `goal` and `guardrails`.

- Each `done_when` item that names a command in backticks becomes a statement. Its `check`
  is the first command after "proven by" (or the item's first command), its `text` is the
  item, and its `name` is the stem of the first path the item names (`out/alpha.txt` gives
  `alpha`), or else its first meaningful words. Names are unique (`alpha_2`).
- Items with no command go to `skipped`: make-goal's claims item and ledger item, and any
  other end state only the boss can show. An item about the contract's own files under
  `.goal/` is skipped even if it names a command: the team's repository does not hold them.
- The command must exit 0 exactly when the item holds. `grep -x ok out/alpha.txt` does. A
  command that only prints something for a reader to judge (`wc -l`, `cat`, `ls`) is
  accepted with a warning, because the merge job reads only the exit status: rewrite it in
  `config.json` before `setup.sh`, for example `test $(wc -l < src/a.py) -lt 200`.
- `from-goal.py` refuses (exit status 2) an `exploratory` contract (findings and decisions
  have no exit status to check), a contract with no item that names a command, and a work
  directory where `setup.sh` has already run (`central.git/` or `ws/` exists).

`--apply` writes into `config.json`: `task.statements`, `task.checks` (one command per
statement), and `task.allowed_paths` from `--allowed`; it removes `task.attempted_if`, and
makes `task.check` a command that fails, so a statement added later without its own check
can never pass by accident. It also writes `task/seed/STATEMENTS.md` with each statement's
name, text and check, the guardrails and the allowed paths. The allowed paths are not
guessed from the guardrails' prose: `Do not modify any file outside out/` becomes
`--allowed 'out/.*'` because you say so. A pattern that would let agents rewrite
`STATEMENTS.md` is warned about.

It touches nothing else in `task/`. Put the frozen files the checks need into `task/seed/`,
make `task/install.sh` install the checks' tools (or delete it), and make `task/probe/good`
and `task/probe/bad` a right and a wrong answer to one statement (or delete them;
`test_gateway.sh` then says it skipped that step). Then follow `SKILL.md` from step 3.

**How the checks run.** A statement in `task.checks` is checked with its own command,
exactly as written (no `{name}` substitution, so shell braces such as `awk '{print $1}'`
are safe); the others use `task.check`. The merge job, `verify.py` and the briefs all
follow it. The command runs at the root of the merged tree in the merge job's sandbox: no
network, no home directory, only `/usr`, `/etc`, `tools/` and `task.toolchain_paths`.
Without `task.attempted_if` every statement is checked on every merge; a merge is rejected
only when it breaks a statement that was already done, and a wrong answer to an open
statement simply does not count.

### 2. The boss's own condition

The proof of the whole contract is the output of `python3 harness/verify.py`: it clones
`main` fresh, runs every statement's own check in the merge job's sandbox, and confirms the
frozen files are unchanged. The `/goal` evaluator reads conversation text only, so the
boss must print that output. Under each statement that has its own check, `verify.py`
prints `check: <command>`, so the evaluator sees the item's command, its last output line
and `PASS` together. A condition that fits:

> Every statement passes on a fresh checkout of main, proven by printing the output of
> `python3 harness/verify.py`, whose last line reads `<m> of <m> statements pass`.

Do not prove an item by running its command in a workspace: only `main` counts. Each turn
of the loop is one round of `SKILL.md` step 6 (`wait-run.sh`, then act on what it printed).

### 3. What the boss still owns

The skipped items are about the runner's own record, not the work, so no agent can do them:

| Skipped item | How the boss meets it |
|---|---|
| The claims file | Write it from `records/merges.jsonl`: each accepted merge (its `main` commit) is `verified` evidence for its statement once `verify.py` printed its PASS line; what a helper wrote on the board is `inherited` |
| The ledger digest | One iteration is one `harness/wait-run.sh 540` cycle: `delegated` is the helpers, `new` is what landed in that cycle |

The contract's `operating_mode` asks the runner to delegate to subagents. With a team, the
helpers are the delegation, and the boss uses no subagents for the work. Say so in the
ledger rather than starting subagents to satisfy the wording.

### 4. What to watch for

- **A pause is not the loop's to clear.** `/goal` keeps the boss working; it does not
  authorize `harness/boss.sh resume` without reading the blocked action (`SKILL.md`, step 6).
- **No coaching.** The boss's messages to the team carry facts about the run, never hints
  about the work, however long the loop runs.
- **Bound the loop by the run.** Choose `budget_min` so the team's time ends before the
  contract's ceiling. When `wait-run.sh` prints `TIME UP` or `STALLED`, the run is over:
  print `verify.py`'s output as the gap report, with the ledger digest and the claims file,
  and stop. That is the contract's bounded termination, not a reason to launch a second run.
- **No new goals mid-run** unless the user approved an envelope for them up front.

## An agent under `/goal`

On the `open` profile an agent has slash commands, skills and subagents, so it may run under
`/goal` in its own session for its own part of the work. It is allowed, not expected:
nothing in the briefs asks for it.

An agent cannot start `/goal` by itself. In the live profiles proof run (Claude Code 2.1.331)
an `open` agent that tried was told "goal is a UI command, not a skill" before the monitor
was reached: `/goal` is typed into the session's prompt. `boss.sh say` cannot type it either,
because it puts `[boss] ` in front. So the boss puts an agent under `/goal` with

    harness/boss.sh slash <id> "/goal <condition>"

which types that one line as it is and presses Enter. It is refused for an agent whose profile
is not `open`, for a removed agent, for `all`, and for anything but one line of printable text
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
- **Subagents.** make-goal's casts delegate to subagents. Whether the monitor sees the tool
  calls made inside them is unproven (`references/design.md`); treat their work as
  unmonitored until a run shows otherwise. The merge job still checks everything that lands.
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

## Not yet shown

No task has been written from a real make-goal contract, no boss has run under `/goal`, and
no agent has run `/goal` inside the team (`boss.sh slash` is tested with the stub tmux only). `from-goal.py`, `task.checks` and the merge job's
use of them are shown only by stub-based tests (`tests/accept/goal.sh`,
`tests/team/test_goal.sh`).
