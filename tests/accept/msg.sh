#!/bin/bash
# Acceptance: directed messages on the board, team msg / team inbox  (see STATEMENTS.md, statement `msg`)
. "$(dirname "$0")/../lib.sh"
count() { as lead team sql "SELECT count(*) AS n FROM messages WHERE body = '$1'" | sed -n 2p; }

mk_workdir lead h1 h2; setup_wd; launch >/dev/null 2>&1; start_gateway
as h1 team msg h2 "hello two" >/dev/null 2>&1 && ok "team msg <agent> <text> succeeds" || no "team msg <agent> <text> succeeds"
check "team status counts the unread message" 'unread messages: 1' as h2 team status
refute "the sender has nothing unread" 'unread messages' as h1 team status
out=$(as h2 team inbox 2>&1)
check "team inbox shows the text" 'hello two' echo "$out"
check "team inbox shows the sender" 'h1' echo "$out"
refute "a message is shown as unread once" 'hello two' as h2 team inbox
refute "and no longer counted" 'unread messages' as h2 team status
check "team inbox --all shows it again" 'hello two' as h2 team inbox --all
check "every agent can read the messages table" '^h1 \| h2 \| hello two$' as lead team sql "SELECT sender, recipient, body FROM messages"

as h1 team sql "INSERT INTO messages(sender, recipient, body) VALUES ('lead', 'h2', 'forged')" >/dev/null 2>&1 \
  && no "a helper cannot write the messages table directly" || ok "a helper cannot write the messages table directly"
as lead team sql "INSERT INTO messages(sender, recipient, body) VALUES ('h1', 'h2', 'forged')" >/dev/null 2>&1 \
  && no "nor can the lead" || ok "nor can the lead"
as lead team sql "UPDATE messages SET body = 'forged'" >/dev/null 2>&1
as lead team sql "DELETE FROM messages" >/dev/null 2>&1
as lead team sql "DROP TABLE messages" >/dev/null 2>&1
check "no forged message exists" '^0$' count forged
check "the real message is untouched" '^1$' count "hello two"

as h1 team msg nobody "x" >/dev/null 2>&1 && no "an unknown recipient is an error" || ok "an unknown recipient is an error"
as h1 team msg all "to everyone" >/dev/null 2>&1 && ok "team msg all <text> succeeds" || no "team msg all <text> succeeds"
check "the lead receives a message to all" 'to everyone' as lead team inbox
check "a helper receives a message to all" 'to everyone' as h2 team inbox
refute "the sender does not receive its own message" 'unread messages' as h1 team status
check "messages are logged under the sender's name" '"agent": "h1", "op": "msg"' cat "$W/records/gateway.jsonl"
check "boss.sh messages prints them" 'hello two' sh -c "cd '$W' && harness/boss.sh messages"

( cd "$W" && harness/boss.sh remove h2 ) >/dev/null 2>&1
as h2 team msg h1 "too late" >/dev/null 2>&1 && no "a removed agent cannot send" || ok "a removed agent cannot send"
stop_gateway; start_gateway
check "messages survive a gateway restart" 'to everyone' as lead team inbox --all
check "nothing from the removed agent arrived" '^0$' count "too late"

check "team help lists msg" 'team msg' as h1 team help
check "the helper brief describes team msg" 'team msg' cat "$W/docs/helper.md"
check "the lead brief describes team msg" 'team msg' cat "$W/docs/lead.md"
refute "the briefs no longer say there is no messaging" 'There is no messaging' cat "$W/docs/helper.md" "$W/docs/lead.md"
check "SKILL.md documents team msg" 'team msg' cat "$REPO/SKILL.md"
finish
