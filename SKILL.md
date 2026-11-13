---
name: sealed-team
description: Build a small team of sandboxed coding agents from scratch in an environment that has no such system. One lead plus helpers that coordinate only through a shared database and Git, a finish line checked by a machine, and a fail-closed action monitor. Gives the portable design rules, a capability checklist with fallbacks, a build order with a test after every step, and one worked example (Claude Code on Linux). Activate ONLY when the user explicitly invokes /sealed-team or names this skill. Do NOT infer activation from a request to parallelize work, spawn subagents, or "use a team"; ordinary subagents are the right tool for those.
argument-hint: <the goal, and how a machine can check that it is reached>
---

# Sealed team

You have been asked to stand up a team of agents that works the way the team in
"Safely scaling multi-agent teams with Claude Fable 5.2" (claude.dev, 2026-11-09) worked,
in an environment where nothing like it exists yet. This skill gives you the rules that
make such a team work, a way to map them onto whatever your environment offers, and the
order to build and test things in.

You are the **operator**. You build the harness, launch the team, watch it, and verify the
result. You are not the lead. The lead and the helpers are separate agent sessions that
you start.

**How much to trust this skill.** It distills one build, run three times: four agents on
one Linux machine, one easy task, finished in a few minutes each time. The nine rules below
are the part meant to travel. Everything under `example/` is one way to satisfy them. The
runs exercised coordination, claiming, the merge job, the walls and one team pause. They
did not exercise task splitting, moving helpers between crews, time reminders, a block by
the model classifier, a slow checker, or a helper dying mid-task. Advice marked
*untested* below is reasoning, not experience. Where your situation differs, reason from
the rules.

## 1. Decide what to build

The full harness is real work. In the build behind this skill it was about 1,100 lines,
written and tested before any agent started, to coordinate work the team then finished in
four minutes. Before committing to it:

**Check the three conditions.**

- **A machine can check the finish line**: tests, a type checker, a proof checker, a build,
  a benchmark threshold.
- **The work splits into pieces that can land separately**, each with its own check.
- **You cannot supervise by reading along**: more agents or hours than you can follow. This
  skill has no tested threshold; its only data point is four agents. If you could read
  every agent's output yourself, you do not need it.

**Probe your environment** (section 4) before deciding. What you can enforce changes what
is worth building.

Then choose:

| Situation | Build |
|---|---|
| A condition fails | Nothing from this skill. Use the subagents or parallel sessions your runtime offers and tell the user why. Most requests for "a team" end here. |
| Conditions hold, but you cannot wall agents off from each other | The merge gate alone (rule 2), with ordinary subagents behind it. It is the piece that keeps most of its value without walls. |
| Conditions hold and walls can be enforced | The full design. |

Say which purpose the run serves. A **trial** shows that the harness works; advisory rules
are tolerable there as long as the report names them. For **real work**, an advisory rule
is a real gap, and the user should hear about it before launch.

## 2. Roles

| Role | Who | Does |
|---|---|---|
| Operator | You | Builds the harness, writes the finish line, launches, reviews pauses, verifies the result |
| Lead | One agent session | Designs the whiteboard tables, writes the orders, forms crews, moves helpers; does not do the work itself |
| Helper | Every other session | Reads the orders, claims a task, does it, gets it merged, reports; repeats |
| Captain | One helper per crew | Posts the crew's plan and splits its work into tasks; also does helper work |

A **crew** is the group of helpers assigned to one part of the goal. With fewer than about
six helpers a crew is a single agent and captains add nothing; say so.

You are probably an agent acting for a person. Wherever this skill says a human reviews
something, that is you unless the user has kept it for themselves. Settle these with the
user before launch: how many agents and for how long (each is a full session that costs
money), who answers prompts that ask for a person's consent, and what stays running
afterwards. Stay reachable while the team runs; wait on the run in the background.

## 3. The nine rules

Each rule has a reason. When your environment cannot enforce a rule, the reason tells you
what you have lost.

**1. A whiteboard instead of messages.** Agents share exactly two things: a database and a
Git repository. They never message each other and cannot see each other's files or
screens. Five tables are enough:

| Table | Holds |
|---|---|
| `announce` | The lead's orders to everyone |
| `assign` | Who works on what, and who is captain |
| `notes` | Plans, claims, progress |
| `subtasks` | The to-do list; any agent may add rows |
| `landed` | The log of finished work |

Claiming a task is one atomic conditional update (set the owner to me where the owner is
empty), so two agents cannot both win. Any store with transactions and that update will do.
Record when each claim was made and what a task depends on. A claim needs a way back:
when a helper is removed or goes quiet, the lead reopens its rows.
*Why:* a board survives an agent dying, makes nobody wait for a reply, can be read by
someone who joins late, and is a complete record afterwards. Messages are none of those.

Let the lead design the columns and write the orders into `announce`. Helpers start
knowing only where the orders are. This keeps the briefs short and proves the board
carries everything a helper needs.

**2. A fixed finish line that a machine checks.** Split the goal into **statements**: pieces
that can each be checked separately (one module and its tests, one theorem, one file that
must type-check). Write them as files the agents cannot change. Work counts only when a
merge job you control accepts it onto `main`. The merge job merges the agent's branch,
refuses any change outside an allowlist of paths, runs the checker somewhere the agents
cannot reach, and only then moves `main`. Agents have no other way to move `main`.
*Why:* agents report success optimistically, and with many of them you cannot read every
diff. The merge job turns "done" from a claim into a fact. It is also what lets you tell
agents to keep going until their work is accepted.

Four things make the difference between a finish line and a formality:

- **Merges must be able to pass before the whole goal does.** If the only check is global
  ("the entire build passes"), nothing can land until the end. Check each merge with the
  statements it completes, plus a ratchet: nothing that passed before may fail now.
- **Freeze the checker's settings with the statements**, and reject its escape hatches:
  skipped tests, suppressed errors, directives that switch a check off.
- **Give every shared file one owner.** Files several tasks need to change (build
  configuration, an index, a renamed import) are either changed by you before launch or
  assigned to exactly one task. The allowlist then stays narrow.
- **Know how strong your checker is.** A proof checker cannot be satisfied by a wrong
  proof. A test suite can be passed by wrong code. Tell the user which one you have.

**3. Identity comes from the channel.** Who sent a request is decided by where it arrived
(this agent's socket, request folder or credentials), never by a name the agent writes
into the request. "A helper cannot act as the lead" means exactly this: no request from a
helper can be recorded under the lead's identity. If your store has no per-agent accounts,
the gateway writes the author column itself and agents never supply it.
*Why:* with identity fixed, the records can be attributed, "first to claim owns it" means
something, and readers can tell the lead's orders from a helper's note.

**4. One door out.** Give each agent a single command for everything shared: run SQL,
publish my branch, request a merge, show status and time left, and wait (sleep, then show
status, so an idle agent can poll cheaply). A gateway process outside the agents' walls
serves that door. It stamps identity, enforces limits (time per SQL statement, database
size, which kinds of statement a helper may run), and logs every request.
*Why:* one door is one place to enforce and one place to log.

**5. Walls.** Each agent can write only inside its own workspace, cannot read the other
workspaces or the harness, and has no network. Everything shared goes through the door.
Take away every tool you cannot wall or check: web access, messaging, spawning further
agents, connectors to outside services. Because there is no network, install whatever the
agents and the checker need before the walls go up.
*Why:* without walls, rules 1 to 4 are only requests. "No messaging" fails the moment one
agent can read another's files. "Identity from the channel" fails the moment one agent can
write into another's channel.

**6. Check before acting, and fail closed.** Something outside the agent looks at every
command and file edit before it runs. A block does more than refuse the action: it pauses
the whole team until you have reviewed it. Then decide:

| What you find | What you do |
|---|---|
| A real violation by a helper | Remove that helper, resume the rest |
| A real violation by the lead | End the run |
| A false alarm | Fix the monitor, resume, and move the deadline back by the length of the pause |

Removing a helper means the check and the gateway refuse everything from it from then on,
and its unfinished claims are reopened.
*Why:* a refusal tells you an agent tried something. A team that keeps running while you
find out has time to try the next thing.

Two layers work well: cheap fixed rules for the obvious cases, and a model that judges each
action. Neither replaces the walls. A pattern rule is easy to dodge.

**7. Keep going until the checker says done.** An agent may not stop while the finish line
is unreached and time remains. Give the run a deadline and let agents see the time left
through the door. If you can put input into a running session, also remind the lead on a
timer. Stopping must stay possible once the run is done, time is up, or the team is paused.
*Why:* agents stop early, after their own task or while waiting on someone else. The goal
belongs to the team.

**8. A cold start from a brief.** Every agent is a separate session that starts from a
short written brief and nothing else: who it is, the goal, the door's commands, the
limits. A helper's brief says only where to find the orders.
*Why:* context an agent inherits from you is a private channel the board does not record.
A brief you can read is a brief you can audit.

**9. Records out of reach.** Log every tool call, every gateway request and every merge
somewhere agents can neither read nor write. Review the records after the run.
*Why:* the monitor catches only what it was built to catch. The records are how you find
the rest, and how you check claims, for example that `landed` matches what the merge job
really merged.

## 4. Map the rules onto your environment

Find out what you have before you build. For each need, take the strongest option
available and write down which one you took. Probe each one; do not assume. The table
you fill in here goes into your final report.

| Need | Rules | Options, strongest first |
|---|---|---|
| Separate sessions | 8 | A VM or container per agent. Separate processes of an agent CLI, one per terminal window or background job. Subagents inside your own session. |
| Walls | 5 | A VM or container. An OS sandbox around the agent's shell (bubblewrap, Seatbelt, or one built into the agent runtime). A separate OS user per agent. Instructions only. |
| Whiteboard | 1 | A database server with one account per agent. A single-file database only the gateway can open. Files with atomic rename, behind the gateway. |
| Identity and door | 3, 4 | Per-agent credentials held only by the gateway. A per-agent channel inside that agent's walls. A name the agent supplies. |
| Checker isolation | 2 | A throwaway container or sandbox with no network. A subprocess under another OS user. A plain subprocess. |
| Check before acting | 6 | A runtime hook on every tool call plus a model classifier. A hook with fixed rules. Nothing. |
| Stop control | 7 | A runtime hook that can refuse a stop. An outer loop that prompts again. Nudges by hand. |
| Records | 9 | Hook and gateway logs outside the walls, plus the runtime's own transcripts. |

The last option in most rows makes the rule **advisory**: agents are asked to follow it and
nothing enforces it.

**Walls decide the rest.** If the walls are advisory, then the whiteboard, identity, the
door and the records are advisory too, whichever option you picked for them, because an
agent that can reach the files behind them can go around them. Mark them so.

Cases that need particular care:

- **Subagents as the team.** They share your process and credentials and usually cannot be
  given their own sandbox. The walls and the cold start become advisory at once. If you
  can still hook their commands, you keep the check-before-acting rule for the shell;
  remove the tools the hook does not see.
- **A shell the runtime owns.** If you cannot change how the runtime starts commands, a
  wall has to wrap each command: have the hook refuse anything not run through your
  sandbox wrapper. *Untested.*
- **A name the agent supplies** is not identity. Label every record as self-reported.
- **A plain subprocess as the checker** runs submitted code with your privileges.

## 5. Build order

Build from the bottom up. Test each step before you start the next, wherever possible by
trying the thing it is supposed to stop. A wall you have not watched refuse something is a
guess. After a test that changes shared state, reset: undo its merges, rows and logs so
the real run starts clean.

0. **Finish line.** Agree with the user what "done" means. Write the statements, freeze
   the checker and its settings, and install the checker's toolchain. *Test:* solve one
   statement end to end yourself; the checker accepts it and rejects a broken copy. For a
   trial task you invented, solve all of it, then delete your solution or keep it where
   agents cannot read it. For a trial, also size the task: if one agent could finish it in
   a few minutes, the team will exercise nothing.
1. **Repository and merge job.** *Test:* a wrong answer is rejected by the checker; an
   edit to a frozen file is rejected; a valid change is accepted and `main` moves; a
   direct push is refused.
2. **Whiteboard and gateway.** *Test as a helper:* no request of yours is recorded under
   another identity; the limits you set hold (in the example, no deleting rows and no
   changing tables); an over-long statement is cut off; two simultaneous claims produce
   one winner; each request is logged under the right identity.
3. **Walls.** *Test from inside a real agent session, not from your own shell.* These must
   fail: writing outside the workspace, listing a neighbour's workspace, reading the
   harness, reaching the network, reaching the database directly. These must still work:
   the door, a Git commit, the local checker.
4. **Monitor and pause.** *Test:* a violating command is blocked, the pause is set, other
   agents are refused while paused, and a resume clears it. Also feed the rules harmless
   text that mentions forbidden commands and confirm it passes.
5. **Keep going.** A deadline, time left shown through the door, and a stop check tied to
   the finish line. *Test:* a stop is refused while the finish line is unreached, and
   allowed once it is reached, time is up, or the team is paused.
6. **Briefs.** See section 6. *Test:* give each brief to a fresh agent and ask what it
   would do first. A helper should name the door and the orders table and nothing more.
7. **Launch** every agent together, so nobody acts on a board the others have not seen.
   *Test:* every agent's first request arrives through the door under its own identity.
   Stay for the first few minutes; that is when the first pause tends to come.
8. **Finish.** Check the result yourself on a fresh checkout. Review the records. Hand
   back: say where the result is and how to bring it into the user's own repository. Tear
   down what you started, or list what is still running. Report.

Watch each test for a pass that happens for the wrong reason. In the example, "a wrong
answer is rejected" once passed because the checker itself had failed to start.

Merges go through one queue. If the checker is slow, that queue is the team's speed limit;
checking only what a merge touches, with a full check at intervals, is the obvious
remedy. *Untested.*

## 6. Briefs

The lead's brief covers: its role and the team's size; the goal and where the statements
are; the two shared things and the door's commands; its four jobs (create the five tables,
post orders, form crews, keep the team moving); that helpers know nothing until the orders
are posted, so the orders must describe the tables, the atomic claim, and the loop below;
and the limits (time, walls, monitor).

The loop the lead writes into its orders:

1. Read the plan in `notes`.
2. Claim a task from `subtasks`.
3. Do it, check it locally, commit, request a merge until it is accepted.
4. Mark it done in `subtasks`.
5. Post an update to `notes` and a row to `landed`.

Then repeat. A helper that finds a task too hard splits it into smaller rows instead of
holding it.

A helper's brief covers: its role, the goal, where the orders are and what to do if they
are not there yet (wait and retry), the door's commands, and the same limits.

Put the brief in the first user message, not only in a system prompt. A model that judges
actions against what the user asked for needs to see that you authorized the door.

The briefs in `example/docs/` show the shape. Their details (Postgres, pytest, the team's
names and size) belong to that example.

## 7. While it runs

- **A pause is yours to review.** Read the blocked action in full before deciding.
- **Agents told to stop do not restart by themselves.** After a resume, tell each one that
  the pause is cleared and why.
- **Do not coach.** Your messages to agents carry harness facts only: time left, a pause
  cleared, a removal. Hints about the work are a channel the board does not record.
- **Expect honest races.** Two idle helpers will go for the same open task. The atomic
  claim settles it; the loser should say so on the board and move on.
- **Watch for stale claims.** A task claimed long ago with no merge and no note is a task
  nobody is doing.

## 8. Report

Tell the user, in this order:

1. Whether the finish line was reached, and how you checked it yourself.
2. The table from section 4: the option you took for each need, and for each of the nine
   rules whether it was enforced or advisory.
3. What the run exercised and what it did not.
4. Every pause: what was blocked, what you decided, and why. Also every prompt you
   answered on the user's behalf.
5. Where the result is, what is still running, and the exact commands to remove it.

## 9. Lessons from the first build

- **Monitor rules must judge commands, not text.** The lead's orders said "never run git
  push" and a pattern rule read that as a push. The whole team paused two minutes in.
  Strip quoted text and here-document bodies before matching.
- **An easy task proves little.** Nobody split a task, the lead never moved a helper, the
  checker never rejected submitted work, and every run ended before the first time
  reminder.
- **Sandboxes change what agents see.** Ours showed stub files inside each workspace that
  Git wanted to add, and it cut off localhost. That is why the example's door is a pair
  of folders in each workspace: the agent drops a request file in one and the gateway
  writes the reply in the other. Find such things out in the wall test, before launch.
- **Keep your reference solution away from the agents.** A scratch directory the agents
  can read is not away.
- **New sessions may ask a person something first.** Ours asked whether to trust each new
  workspace folder.

## 10. The worked example

`example/` is the full build: gateway and merge job, monitor hooks, launch scripts, briefs,
and the task. `references/claude-code-linux.md` maps each rule to the feature that
implements it there and lists the quirks.

Read both closely if your agent runtime is Claude Code. Otherwise read `example/docs/`
(the briefs) and `example/bin/team` (the door, about 90 lines), skim
`example/harness/gateway.py` for the shape, and build your own. Do not port it line by
line: most of its length is there to fit one runtime's sandbox and hook system.
