#!/bin/bash
# Team test for multi_doc: the docs agree with what boss.sh and wait-run.sh actually print.
. "$(dirname "$0")/../lib.sh"
sec=$(awk '/^#+ Running more than one team/{on=1; print; next} on && /^#/{exit} on' "$REPO/SKILL.md")
for w in "work directory" "already exists" "current directory" "one \`wait-run.sh\` per team" "login" "CPU" "rate limit"; do
  grep -qiF -- "$w" <<<"$sec" && ok "the section mentions '$w'" || no "the section mentions '$w'" "$sec"
done
step6=$(grep -F 'The first line `wait-run.sh` prints' "$REPO/SKILL.md")
for st in DONE STALLED HALT "TIME UP" "STILL RUNNING"; do
  grep -qF "\`$st [<session>]\`" <<<"$step6" && ok "step 6 shows '$st [<session>]'" || no "step 6 shows '$st [<session>]'" "$step6"
done
check "the commands table shows wait-run.sh's tag" 'wait-run\.sh.*\[<session>\]' grep -F '| `harness/wait-run.sh' "$REPO/SKILL.md"
check "the commands table shows boss.sh's tag" 'boss\.sh status.*\[<session>\]' grep -F '| `harness/boss.sh status' "$REPO/SKILL.md"
check "step 5 shows the tagged trust line" '\[<session>\] h1: answered yes, started' cat "$REPO/SKILL.md"
refute "no untagged bare state list is left in step 6" '`DONE`, `STALLED`' cat "$REPO/SKILL.md"
check "README points to the SKILL.md section" 'Running more than one team' cat "$REPO/README.md"
check "README mentions the tag" '\[<session>\]' cat "$REPO/README.md"
# what the docs say matches what the scripts print
mk_workdir; setup_wd; launch >/dev/null 2>&1
S=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['session'])" "$W/config.json")
check "wait-run.sh prints the documented first line" "^STILL RUNNING \[$S\]\$" sh -c "cd / && '$W/harness/wait-run.sh' 0 | head -1"
check "boss.sh status starts with [<session>] <work dir>, as documented" "^\[$S\] $W\$" sh -c "cd / && '$W/harness/boss.sh' status | head -1"
check "boss.sh say prints the documented line" "^\[$S\] typed into h1: hello\$" sh -c "cd / && '$W/harness/boss.sh' say h1 hello"
check "boss.sh refusals carry the tag, as documented" "^\[$S\] refused: " sh -c "cd / && '$W/harness/boss.sh' slash nobody /x"
finish
