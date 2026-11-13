#!/bin/bash
# Live view for humans: run state plus the team's whiteboard tables.
R=$(cd "$(dirname "$0")/.." && pwd); cfg() { python3 "$R/harness/cfg.py" "$1"; }
C=$(cfg db.container); DB=$(cfg db.name)
q() { docker exec "$C" psql -U postgres -d "$DB" -P pager=off -At -F ' | ' -c "$1" 2>&1 | cut -c1-${COLUMNS:-200}; }
while true; do
  clear
  left=$(python3 -c "import time;print(int((float(open('$R/state/deadline').read())-time.time())//60))" 2>/dev/null)
  echo "== $(cfg session)  $(date +%T)  time left: ${left:-?} min  landed: $(tr -d '[]\",' < "$R/state/landed.json" 2>/dev/null)"
  [ -e "$R/state/DONE" ] && echo "== RUN COMPLETE"
  [ -e "$R/state/HALT" ] && { echo "== TEAM PAUSED:"; cut -c1-400 "$R/state/HALT"; echo; }
  echo "-- tables (rows)"; q "SELECT relname || ': ' || n_live_tup FROM pg_stat_user_tables ORDER BY 1"
  for t in assign subtasks; do echo "-- $t"; q "SELECT * FROM $t ORDER BY 1" | tail -25; done
  echo "-- notes (last 6)"; q "SELECT * FROM notes ORDER BY 1 DESC LIMIT 6"
  echo "-- merges"; tail -n 6 "$R/records/merges.jsonl" 2>/dev/null | python3 -c "
import sys,json,time
for l in sys.stdin:
    d=json.loads(l); print(time.strftime('%H:%M:%S',time.localtime(d['ts'])), d['agent'], d['title'][:60], '->', ' '.join(d['landed']))"
  sleep 10
done
