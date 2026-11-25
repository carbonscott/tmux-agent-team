#!/bin/bash
# Acceptance: ./teardown.sh --archive  (see STATEMENTS.md, statement `archive`)
. "$(dirname "$0")/../lib.sh"
status_of() { find "$1" -maxdepth 2 -name STATUS.txt | head -1; }

# an abandoned run: one of three statements done
mk_workdir; setup_wd; launch >/dev/null 2>&1; start_gateway
check "a statement lands before the stop" 'ACCEPTED' land h1 a
DEST=$TOP/dest; mkdir -p "$DEST"; gw=$GWPID
out=$(cd "$W" && ./teardown.sh --archive "$DEST" 2>&1)
n=$(ls "$DEST" | wc -l); f=$(ls "$DEST"/team-archive-*.tar.gz 2>/dev/null | head -1)
[ "$n" = 1 ] && [ -n "$f" ] && ok "one file team-archive-*.tar.gz is written to the given folder" || no "one file team-archive-*.tar.gz is written to the given folder" "$(ls -la "$DEST"; echo "$out")"
check "the last line of output names the file" "^archived: $f\$" sh -c 'echo "$1" | tail -1' sh "$out"
mkdir "$TOP/x"; tar -xzf "$f" -C "$TOP/x" 2>/dev/null; s=$(status_of "$TOP/x"); root=$(dirname "${s:-/nonexistent/x}")
check "STATUS.txt starts with the state of the run" '^abandoned run, stopped .+, 1 of 3 done, not verified$' head -1 "$s"
check "the repository is in the archive and can be cloned" '^ok$' sh -c "git clone -q '$root/central.git' '$TOP/clone' && cat '$TOP/clone/out/a.txt'"
check "the records are in the archive" '"op": "mr"' cat "$root/records/gateway.jsonl"
refute "workspaces, the board and the tools are left out" . find "$TOP/x" \( -name ws -o -name 'board.db*' -o -name tools -o -name settings \)
refute "the run's files are deleted from the work directory" . sh -c "ls -d '$W/ws' '$W/state' '$W/central.git' '$W/records' 2>/dev/null"
kill -0 "$gw" 2>/dev/null && no "the gateway is stopped" || ok "the gateway is stopped"
check "the template itself is still there" . ls "$W/setup.sh" "$W/harness/gateway.py"

# a finished run, archived to the default place: the folder that holds the work directory
mk_workdir; setup_wd; launch >/dev/null 2>&1; start_gateway
land h1 a >/dev/null 2>&1; land h1 b >/dev/null 2>&1
check "the run completes" 'RUN COMPLETE' land h2 c
out=$(cd "$W" && ./teardown.sh --archive 2>&1)
f=$(ls "$TOP"/team-archive-*.tar.gz 2>/dev/null | head -1)
[ -n "$f" ] && ok "the default destination is the folder that holds the work directory" || no "the default destination is the folder that holds the work directory" "$out"
mkdir "$TOP/y"; tar -xzf "${f:-/nonexistent}" -C "$TOP/y" 2>/dev/null; s=$(status_of "$TOP/y")
check "a finished run that verifies says so" '^finished run, stopped .+, 3 of 3 done, verified$' head -1 "$s"
check "the file name carries the session and a date" "team-archive-tat-$(basename "$TOP")-[0-9]{8}-[0-9]{6}\.tar\.gz" echo "$f"

check "SKILL.md documents --archive" '--archive' cat "$REPO/SKILL.md"
finish
