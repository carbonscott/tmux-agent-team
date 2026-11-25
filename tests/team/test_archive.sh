#!/bin/bash
# Team tests for ./teardown.sh --archive: refusals that must change nothing, failures that must
# delete nothing, what STATUS.txt says beyond its first line, and runs that ended in odd states.
. "$(dirname "$0")/../lib.sh"
status_of() { find "$1" -maxdepth 2 -name STATUS.txt | head -1; }
unpack() { rm -rf "$TOP/x"; mkdir "$TOP/x"; tar -xzf "$1" -C "$TOP/x" && status_of "$TOP/x"; }
intact() { [ -d "$W/ws/h1" ] && [ -d "$W/central.git" ] && [ -d "$W/state" ] && [ -d "$W/records" ]; }
running() { [ -e "$STUB_DIR/session" ] && kill -0 "$GWPID" 2>/dev/null; }

# ---- refusals: checked before anything is stopped, so the run goes on untouched
mk_workdir; setup_wd; launch >/dev/null 2>&1; start_gateway
land h1 a >/dev/null 2>&1
as h1 team msg h2 "kept in the records" >/dev/null 2>&1; as lead team msg all "and this one" >/dev/null 2>&1
out=$(cd "$W" && ./teardown.sh --archive "$TOP/no/such/folder" 2>&1); rc=$?
[ $rc -ne 0 ] && ok "a destination that does not exist is refused" || no "a destination that does not exist is refused" "$out"
check "and the refusal says why" 'no such folder' echo "$out"
running && intact && ok "and nothing was stopped or deleted" || no "and nothing was stopped or deleted" "$out"
out=$(cd "$W" && ./teardown.sh --archive "$W/state" 2>&1); rc=$?
[ $rc -ne 0 ] && ok "a destination inside the work directory is refused" || no "a destination inside the work directory is refused" "$out"
check "and the refusal says it must be outside" 'inside the work directory' echo "$out"
running && intact && ok "and the run is still untouched" || no "and the run is still untouched" "$out"
mkdir -p "$TOP/ro"; chmod 555 "$TOP/ro"
if [ -w "$TOP/ro" ]; then ok "a read-only destination is refused (skipped: running as root)"
else
  ( cd "$W" && ./teardown.sh --archive "$TOP/ro" ) >/dev/null 2>&1 && no "a read-only destination is refused" || ok "a read-only destination is refused"
  running && intact && ok "and the run is still untouched after it" || no "and the run is still untouched after it"
fi
chmod 755 "$TOP/ro"
out=$(cd "$W" && ./teardown.sh --archvie 2>&1); rc=$?
[ $rc -ne 0 ] && running && intact && ok "a mistyped option stops nothing" || no "a mistyped option stops nothing" "$out"
check "and prints the usage" '--archive \[DIR\]' echo "$out"

# ---- a failure while writing deletes nothing: every name the archive could take is already used
mkdir -p "$TOP/full"
python3 -c "
import json, os, time
s = json.load(open('$W/config.json'))['session']; t = int(time.time())
for i in range(-2, 40):
    open(os.path.join('$TOP/full', 'team-archive-%s-%s.tar.gz' % (s, time.strftime('%Y%m%d-%H%M%S', time.localtime(t + i)))), 'w').write('x\\n')"
before=$(ls "$TOP/full" | md5sum)
out=$(cd "$W" && ./teardown.sh --archive "$TOP/full" 2>&1); rc=$?
[ $rc -ne 0 ] && ok "an archive that cannot be written fails" || no "an archive that cannot be written fails" "$out"
check "an existing file is named, not overwritten" 'already exists' echo "$out"
[ "$(ls "$TOP/full" | md5sum)" = "$before" ] && [ "$(cat "$TOP/full"/* | sort -u)" = x ] && ok "and the files already there are untouched" || no "and the files already there are untouched"
intact && ok "and the run's files are kept" || no "and the run's files are kept" "$out"
refute "and it never says archived" '^archived:' echo "$out"

# ---- the archive of that (now stopped) run: what it holds and what STATUS.txt says
( cd "$W" && harness/boss.sh remove h2 ) >/dev/null 2>&1
echo '{"tool_name":"Bash","tool_input":{"command":"sudo ls"},"cwd":"'"$W/ws/h1"'"}' | python3 "$W/harness/hook.py" h1 >/dev/null 2>&1
echo '{"ts": 1, "down_s": 60}' >> "$W/records/resumes.jsonl"
( cd "$W" && python3 harness/report.py ) >/dev/null 2>&1; mkdir -p "$W/harness/__pycache__"; touch "$W/harness/__pycache__/x.pyc"
mkdir -p "$TOP/rel"
out=$(cd "$TOP" && "$W/teardown.sh" --archive rel 2>&1); rc=$?
[ $rc -eq 0 ] && ok "a stopped, paused run can still be archived" || no "a stopped, paused run can still be archived" "$out"
f=$(ls "$TOP"/rel/*.tar.gz 2>/dev/null)
check "a relative destination is printed as a full path" "^archived: $TOP/rel/team-archive-" sh -c 'echo "$1" | tail -1' sh "$out"
check "the archive holds exactly STATUS.txt, central.git and records under one folder" '^central.git records STATUS.txt$' \
  sh -c "tar -tzf '$f' | cut -d/ -f2 | grep . | sort -uf | xargs echo"
check "everything is under one folder named like the file" "^$(basename "$f" .tar.gz)\$" sh -c "tar -tzf '$f' | cut -d/ -f1 | sort -u"
s=$(unpack "$f")
check "STATUS.txt: an abandoned run with one of three done" '^abandoned run, stopped .+, 1 of 3 done, not verified$' head -1 "$s"
check "STATUS.txt names the removed helper" '^removed helpers: +h2$' cat "$s"
check "STATUS.txt shows the pause and the blocked action" 'sudo ls' cat "$s"
check "STATUS.txt counts the resumes" '^resumes: +1$' cat "$s"
check "STATUS.txt counts the messages" '^messages: +2 ' cat "$s"
check "and the messages themselves are in the archived records" 'kept in the records' cat "$(dirname "$s")/records/gateway.jsonl"
check "STATUS.txt carries what verify.py said" 'FAIL +b' cat "$s"
check "STATUS.txt says how to get the work back" 'git clone central.git' cat "$s"
d=$(dirname "$s")
check "the archive keeps the run's facts for the report (records/run.json)" '"started": [0-9]' cat "$d/records/run.json"
check "run.json says how the run ended" '"kind": "stopped"' cat "$d/records/run.json"
check "the archive holds the run's page, records/report.html" '1 of 3' cat "$d/records/report.html"
check "which says the run was abandoned, not that it never started" 'ABANDONED' cat "$d/records/report.html"
check "and shows the pause in progress at the stop" 'still paused at the stop' cat "$d/records/report.html"
out=$(python3 "$REPO/template/harness/report.py" --records "$d/records" -o "$TOP/again.html" 2>&1)
check "report.py --records rebuilds the page from the unpacked archive" "^report: $TOP/again.html\$" echo "$out"
check "with what was done" '1 of 3' cat "$TOP/again.html"
refute "and never says NOT STARTED" 'NOT STARTED' cat "$TOP/again.html"
refute "--archive leaves no report.html in the work directory" . sh -c "ls '$W/report.html' 2>/dev/null"
refute "nor a harness/__pycache__" . sh -c "ls -d '$W/harness/__pycache__' 2>/dev/null"
check "the history is in the archive" 'land a' sh -c "git -C '$(dirname "$s")/central.git' log --format=%s main"
check "a second --archive finds nothing to archive" 'nothing to archive' sh -c "cd '$W' && ./teardown.sh --archive '$TOP/rel'"
( cd "$W" && ./teardown.sh --archive "$TOP/rel" ) >/dev/null 2>&1 && no "and fails" || ok "and fails"

# ---- "verified" is judged when the archive is made, not taken from the merge job
mk_workdir; setup_wd; launch >/dev/null 2>&1; start_gateway
land h1 a >/dev/null 2>&1; land h1 b >/dev/null 2>&1
check "a run completes" 'RUN COMPLETE' land h2 c
setcfg task.check '"false"'
out=$(cd "$W" && ./teardown.sh --archive 2>&1)
f=$(ls "$TOP"/team-archive-*.tar.gz 2>/dev/null | head -1)
s=$(unpack "${f:-/nonexistent}")
check "a finished run whose check no longer passes is finished but not verified" '^finished run, stopped .+, 3 of 3 done, not verified$' head -1 "$s"
check "and its finish time is kept" '^finished at: +[0-9]{4}-' cat "$s"
d=$(dirname "$s")
check "a finished run's archived page says COMPLETE" '<span class="s">COMPLETE</span>' cat "$d/records/report.html"
cp -r "$d/records" "$W/records"     # the work directory was purged: no state/, but records/run.json
check "a work directory without state/ is reported from records/run.json" '3 of 3' \
  sh -c "cd '$W' && python3 harness/report.py -o '$TOP/wd.html' >/dev/null 2>&1; cat '$TOP/wd.html'"
rm -rf "$W/records" "$d/records/run.json"
python3 "$REPO/template/harness/report.py" --records "$d/records" -o "$TOP/old.html" >/dev/null 2>&1
check "an archive older than run.json is reported from its STATUS.txt" '<span class="n">3 of 3</span><span class="s">COMPLETE' cat "$TOP/old.html"
check "and the page says where the facts came from" 'come from STATUS.txt' cat "$TOP/old.html"
rm "$d/STATUS.txt"
python3 "$REPO/template/harness/report.py" --records "$d/records" -o "$TOP/none.html" >/dev/null 2>&1 \
  && no "records with neither run.json nor STATUS.txt are refused" || ok "records with neither run.json nor STATUS.txt are refused"

# ---- an interrupted run (session and gateway already gone) is archived as it lies
mk_workdir; setup_wd; launch >/dev/null 2>&1; start_gateway
land h1 a >/dev/null 2>&1
stop_gateway; rm -f "$STUB_DIR/session"
out=$(cd "$W" && ./teardown.sh --archive 2>&1); rc=$?
[ $rc -eq 0 ] && ok "an interrupted run is archived" || no "an interrupted run is archived" "$out"
s=$(unpack "$(ls "$TOP"/team-archive-*.tar.gz | head -1)")
check "as abandoned, with what had landed" '^abandoned run, stopped .+, 1 of 3 done, not verified$' head -1 "$s"
refute "and nothing of it is left in the work directory" . sh -c "ls -d '$W/ws' '$W/state' '$W/central.git' '$W/records' 2>/dev/null"

# ---- a plain teardown keeps the files, as before
mk_workdir; setup_wd; launch >/dev/null 2>&1; start_gateway
( cd "$W" && ./teardown.sh ) >/dev/null 2>&1
intact && ok "a plain ./teardown.sh still keeps the run's files" || no "a plain ./teardown.sh still keeps the run's files"
check "SKILL.md says when to archive and when to purge" -i 'archive.*purge|purge.*archive' cat "$REPO/SKILL.md"
finish
