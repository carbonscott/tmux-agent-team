#!/bin/bash
# Team tests for `msg`: directed messages through the gateway. What the acceptance test does
# not cover: refusals (self, empty, too long, pause, time up), the protection of the gateway's
# tables against tricks the authorizer must catch, read marks across a restart, and how
# messages meet removals and the rest of the door.
. "$(dirname "$0")/../lib.sh"
count() { as lead team sql "SELECT count(*) AS n FROM messages WHERE body = '$1'" | sed -n 2p; }

mk_workdir lead h1 h2 h3; setup_wd
check "boss.sh messages works before the board exists" '\(0 messages\)' sh -c "cd '$W' && harness/boss.sh messages"
launch >/dev/null 2>&1; start_gateway

# the gateway's tables exist from the start, before the lead has made any of its own
check "the messages table exists at start" 'messages' as lead team sql "SELECT name FROM sqlite_master WHERE name = 'messages'"
refute "a fresh agent has no unread line" 'unread messages' as h1 team status
check "an empty inbox says so" 'no unread messages' as h1 team inbox
check "an empty inbox --all says so" 'no messages' as h1 team inbox --all

# refusals
as h1 team msg h1 "me" >/dev/null 2>&1 && no "a message to yourself is refused" || ok "a message to yourself is refused"
as h1 team msg h2 "   " >/dev/null 2>&1 && no "an empty message is refused" || ok "an empty message is refused"
long=$(python3 -c "print('x' * 5000)")
as h1 team msg h2 "$long" >/dev/null 2>&1 && no "a message over 4000 characters is refused" || ok "a message over 4000 characters is refused"
as h1 team msg h2 >/dev/null 2>&1 && no "team msg without text is a usage error" || ok "team msg without text is a usage error"
check "an unknown recipient names the agents" 'lead, h1, h2, h3' as h1 team msg h9 "x"
check "no refused message was stored" '^0$' as lead team sql "SELECT count(*) FROM messages"

# delivery, counting, reading
check "a message gets an id back" 'sent message [0-9]+ to h2' as h1 team msg h2 "first"
as lead team msg h2 "second" >/dev/null
echo "from stdin; with 'quotes' and \"double\"" | as h3 team msg h2 - >/dev/null
check "unread messages are counted" 'unread messages: 3' as h2 team status
check "team wait shows the count too" 'unread messages: 3' as h2 team wait 1
refute "a message to h2 is not unread for h3" 'unread messages' as h3 team status
out=$(as h2 team inbox)
check "the inbox shows every unread message in order" 'first(.|\n)*second(.|\n)*from stdin' sh -c 'printf "%s" "$1" | tr "\n" " "' sh "$out"
check "text from stdin arrives whole, quotes included" "with 'quotes' and \"double\"" echo "$out"
check "the inbox names each sender" 'h3 -> h2' echo "$out"
refute "after reading, nothing is unread" 'unread messages' as h2 team status
as h2 team msg h1 "reply to first" >/dev/null
check "inbox --all also shows what the caller sent" 'h2 -> h1:' as h2 team inbox --all
check "inbox --all shows what the caller received" 'h1 -> h2:' as h2 team inbox --all
check "inbox --all marks unread messages read too" 'unread messages: 1' as h1 team status
as h1 team inbox --all >/dev/null
refute "so the reply is no longer unread" 'unread messages' as h1 team status

# text that looks like SQL is stored as text
as h1 team msg h2 "x'); DROP TABLE messages; --" >/dev/null
check "SQL inside a message is stored as text" "DROP TABLE messages" as h2 team inbox
check "and the table is still there" '^[0-9]+$' sh -c "cd '$W/ws/lead' && PATH='$W/bin:$PATH' team sql 'SELECT count(*) FROM messages' | sed -n 2p"

# the gateway's tables cannot be changed through team sql, by tricks the plain test does not try
for q in "CREATE TRIGGER t AFTER INSERT ON messages BEGIN DELETE FROM messages; END" \
         "CREATE TEMP TRIGGER t AFTER INSERT ON main.messages BEGIN SELECT 1; END" \
         "ALTER TABLE messages RENAME TO old_messages" \
         "ALTER TABLE messages ADD COLUMN x" \
         "CREATE INDEX i ON messages(body)" \
         "UPDATE message_reads SET last_id = 0" \
         "INSERT INTO message_reads(agent, last_id) VALUES ('h2', 0)" \
         "DROP TABLE message_reads" \
         "REPLACE INTO messages(id, sender, recipient, body) VALUES (1, 'lead', 'h2', 'forged')" \
         "INSERT INTO messages(sender, recipient, body) SELECT 'lead', 'h2', 'forged'"; do
  check "the lead cannot: $q" 'ERROR: not allowed' as lead team sql "$q"
done
as h1 team sql "SELECT 1; INSERT INTO messages(sender, recipient, body) VALUES ('lead', 'h2', 'forged')" >/dev/null 2>&1 \
  && no "a write hidden after a SELECT is refused" || ok "a write hidden after a SELECT is refused"
check "no forged message exists" '^0$' count forged
check "the refusal says how to send instead" 'team msg' as h1 team sql "DELETE FROM messages"
check "a temp table cannot hide the lead's messages" 'sent message' sh -c "
  cd '$W/ws/lead' && PATH='$W/bin:$PATH' team sql 'CREATE TEMP TABLE messages(id, ts, sender, recipient, body)' >/dev/null
  PATH='$W/bin:$PATH' team msg h3 'past the shadow'"
check "and the message reached the real table" 'past the shadow' as h3 team inbox
check "the lead's own tables still work as before" 'OK' as lead team sql "CREATE TABLE notes(body TEXT); INSERT INTO notes VALUES ('x')"

# messages to all: everyone else, once each
as h3 team msg all "to all from h3" >/dev/null
for a in lead h1 h2; do check "$a gets the message to all" 'to all from h3' as $a team inbox; done
refute "the sender of a message to all does not get it" 'to all from h3' as h3 team inbox

# read marks and messages survive a restart
as lead team msg h1 "before restart" >/dev/null
stop_gateway; start_gateway
check "an unread message is still unread after a restart" 'unread messages: 1' as h1 team status
refute "a read message stays read after a restart" 'unread messages' as h2 team status

# removal, pause, time up
( cd "$W" && harness/boss.sh remove h3 ) >/dev/null 2>&1
check "a message to a removed agent warns the sender" 'has been removed' as h1 team msg h3 "are you there"
as h3 team inbox >/dev/null 2>&1 && no "a removed agent cannot read its inbox" || ok "a removed agent cannot read its inbox"
echo '{"ts": 0, "agent": "h1", "reason": "test"}' > "$W/state/HALT"
as h1 team msg h2 "during the pause" >/dev/null 2>&1 && no "nothing is sent during a pause (exit status)" || ok "nothing is sent during a pause (exit status)"
check "the refusal says the team is paused" 'PAUSED' as lead team msg h2 "during the pause"
rm -f "$W/state/HALT"
check "nothing sent during the pause was stored" '^0$' count "during the pause"
cp "$W/state/deadline" "$TOP/deadline"; echo 1 > "$W/state/deadline"
check "nothing is sent once time is up" 'TIME IS UP' as h1 team msg h2 "too late"
check "but the inbox can still be read" 'no unread messages|#' as h2 team inbox
cp "$TOP/deadline" "$W/state/deadline"
check "nothing sent after the time was stored" '^0$' count "too late"

# records
check "an inbox read is logged" '"op": "inbox"' cat "$W/records/gateway.jsonl"
check "a refused message is logged with its recipient" '"op": "msg", "detail": "to h9: x"' cat "$W/records/gateway.jsonl"
out=$(cd "$W" && harness/boss.sh messages)
check "boss.sh messages shows sender and recipient" 'h1 -> h2: first' echo "$out"
check "boss.sh messages counts them" '\([0-9]+ messages\)' echo "$out"
check "the board window lists the messages table" 'messages \(' sh -c "cd '$W' && python3 harness/board.py --brief"
finish
