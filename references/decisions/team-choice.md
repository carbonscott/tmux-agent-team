# Team choice: `team precheck`, the merge job's verdict without landing

The first team to use this template on a real task chose one improvement that its own run
showed was needed. It is `team precheck`: an agent asks the merge job what it would say
about its HEAD now, and nothing lands.

## What was built

| Part | What it does |
|---|---|
| `team precheck` | Reads the agent's committed HEAD from its workspace, merges it into a private clone of the current `main`, applies the path rule, runs the checks of every attempted statement in the merge job's sandbox, and checks that nothing already done would break. It prints `PRECHECK PASSED` with what would be done on `main`, or `PRECHECK FAILED` with the reason: the files in conflict, the frozen paths, the failing statement and its output. |
| `team precheck --quick` | Stops after the merge and the path rule. It answers "will this conflict?" in about a second, without the minutes the checks take late in a run. |
| Gateway | `do_precheck` in `harness/gateway.py`, op `precheck`, logged in `records/gateway.jsonl` like every request. `do_mr` is unchanged. |
| Briefs and runbook | One sentence in `docs/helper.md` and `docs/lead.md`; the command and a symptom row in `SKILL.md`; a row in the enforced table of `references/design.md`. |
| Tests | `tests/team/test_wildcard.sh` |

## Evidence from this run

> **Corrected after the run by review**, from the run's records (`records/gateway.jsonl`,
> `records/merges.jsonl`, `state/started`, `state/DONE`). The team's first version said the
> conflicts came "in the first 45 minutes, before four statements were done", listed four
> agents, and gave the cost as resolving and re-running checks. The records show more
> rejections, a shorter run, and a different main cost. The team's reasoning and its choice
> stand; only the numbers below were corrected.

The team was seven agents (a lead and six helpers) building eight statements at once, all
editing the same few shared files (`SKILL.md`, `references/design.md`,
`references/claude-code.md`, `template/harness/gateway.py`, `template/harness/boss.sh`).

- **The run** took 33.3 minutes from launch to `RUN COMPLETE` (8 of 8). The fourth statement
  (`resume`) was done at minute 14.7, and the lead chose this improvement at 4 of 8 done
  (board note 27).
- **The rejections.** Of 27 merge requests, 16 were accepted and 11 rejected, every one of
  them for a merge conflict: w2 three times (`stall`), w1 twice (`resume`), w4 twice (`goal`),
  w5 twice (`msg`), w3 once (`profiles`), w6 once (`report`). Every conflict was in a shared
  document or a shared script.
- **The cost was waiting.** `team mr` takes the merge lock, and each accepted merge runs the
  checks of every attempted statement, so an agent heard about its conflict only when its turn
  in the queue came. The 11 rejections took 714 s in all (713.99 s) to come back, from 0.1 s to
  261 s each. Finding the conflict itself takes under a second. Resolving it and re-running
  the local checks (about 40 s to a minute a round, as the agents reported) came on top.

| Asked at (min) | Answered at (min) | Agent | Statement | Conflict in | Waited |
|---|---|---|---|---|---|
| 6.9 | 7.4 | w3 | profiles | `SKILL.md` | 33.0 s |
| 7.2 | 7.4 | w5 | msg | `SKILL.md` | 15.3 s |
| 8.4 | 8.4 | w1 | resume | `references/design.md`, `template/harness/render.py` | 0.1 s |
| 8.8 | 9.6 | w5 | msg | `SKILL.md`, `references/claude-code.md` | 48.8 s |
| 9.9 | 9.9 | w1 | resume | `references/design.md`, `template/harness/boss.sh` | 0.1 s |
| 10.6 | 10.6 | w2 | stall | `SKILL.md`, `references/design.md` | 0.2 s |
| 12.1 | 14.7 | w4 | goal | `references/design.md`, `references/goal.md` (add/add) | 153.5 s |
| 12.7 | 14.7 | w6 | report | `SKILL.md`, `references/design.md` | 116.5 s |
| 13.2 | 14.7 | w2 | stall | `SKILL.md`, `references/claude-code.md`, `references/design.md`, `template/harness/boss.sh`, `template/launch.sh` | 85.0 s |
| 18.3 | 18.3 | w4 | goal | `references/design.md` | 0.1 s |
| 22.1 | 26.5 | w2 | stall | `SKILL.md`, `references/design.md` | 261.4 s |

What the agents reported on the board at the time (their words, kept as the team's record):

| Agent | What happened | Cost, as reported |
|---|---|---|
| w3 | `profiles` merge REJECTED: conflict in the `SKILL.md` commands table; `archive` had landed a row beside it minutes earlier | Fetch, resolve, rerun two statements' checks (~40 s each), resubmit |
| w5 | `msg` merge REJECTED twice: `SKILL.md` commands table, then `SKILL.md` and `references/claude-code.md`; `goal` and `profiles` landed between the fetch and `team mr` | Two rounds of resolve, `check.sh` (~50 s), resubmit |
| w1 | `resume` merge REJECTED twice: `render.py` and `design.md` against `goal` and `archive`, then `boss.sh status` and `design.md` against `profiles` | Two rounds, each a full local check (~1 min) plus a round trip |
| w4 | `goal` merge hit an add/add conflict on `references/goal.md`, written by w3 meanwhile | A manual merge of two versions of one document |

Two further facts made the problem worse than the conflicts alone:

- Inside an agent's sandbox a second sandbox cannot be started, so `tests/lib.sh` runs the
  toy task's check through a stand-in. No agent could see the real merge job's verdict on
  its work before landing it.
- After merging `main`, predicting the merge job meant running `tests/check.sh` once per
  attempted statement by hand. w3 skipped it once; the merge was accepted, but by luck.

w3 proposed a dry run of the merge job; w5 and w1 seconded it with evidence of their own, and w4
added its own after the choice (board notes 12, 18, 24 and 37; corrected after the run by review:
the first version said three agents proposed it independently).

## Why it does not weaken anything

- It only reads. It works in a throwaway clone and writes nothing in the central
  repository, not even the agent's own branch. It never touches `landed.json` or
  `merges.jsonl`, and cannot complete a run.
- It goes through the same door as everything else: refused during a pause, after a
  removal, after a stall and after time is up, and logged as op `precheck` under the true
  sender.
- It runs the checks with the merge job's own functions (`verify`, `run_check`), in the
  same sandbox, so it cannot drift into a weaker check.
- `team mr` is unchanged and remains the only way onto `main`.
- It does not take the merge lock, so a slow precheck never delays a real merge.

## Considered and dropped

| Idea | Who | Why dropped |
|---|---|---|
| One item per line in shared lists (the commands table, "Not yet exercised") | w1, w5 | A good writing rule, and partly how the commands table already works, but it reduces conflicts rather than telling an agent about them. Recorded here for whoever edits the runbook next. |
| Conflict check only, no checks (`team sync`) | w5 | Kept, as `team precheck --quick`. |
| Let the merge job resolve conflicts itself | - | The merge job would then write content no agent wrote. That weakens the one part that turns "done" into a fact. |
| One owner per shared file for the template's own docs | - | `design.md` already advises it for tasks. For this repository it would have serialised eight statements behind one agent. |
| A last-seen time per agent for the lead | lead | The lead found quiet claim owners only through note timestamps. Real, but it costs the lead minutes where conflicts cost every helper rounds of checks. |
| Run the precheck automatically on every `team push` | - | Costs the full checks on every push, and most pushes are backups, not merge attempts. |

## Limits

- The verdict is for `main` at the moment of the precheck. Something else may land before
  `team mr`; the merge job then decides, as before.
- Several prechecks at once compete with the merge job for the machine.
- Tested with stub `tmux` and `claude` only. Nobody used it during this run (it landed at
  minute 24.5, and the records hold no `precheck` request), so it has not yet been seen to
  save a round trip; the boss should read its count in the next run's records.
