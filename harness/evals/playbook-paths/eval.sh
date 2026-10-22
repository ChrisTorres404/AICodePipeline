#!/usr/bin/env bash
# playbook-paths: playbook treats the configured playbooks path and the folders it finds as data: a path
# holding |, & or [x], and folder names holding a space or a quote, are shown as they are.
set -uo pipefail
PB="$PIPELINE_ROOT/bin/playbook"; [ -x "$PB" ] || { echo "FAIL setup: bin/playbook not found"; exit 1; }
doc() { mkdir -p "$1" && printf '# spec\n\nAbout caching.\n' > "$1/$(basename "$1" | cut -d- -f1-2)-SPEC.md"; }
plain() { printf '%s\n' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }   # without the bold codes
D="$EVAL_TMP/a|b&c [x]/pb"; W="$D/mine/workorders"
doc "$W/WO-0001-foo bar"; doc "$W/WO-0002-it's"; doc "$W/WO-0003-plain"
# P1: wo search under a playbooks path holding |, & and [x] names each folder from the playbook down
out="$(plain "$(PLAYBOOKS_DIR="$D" "$PB" wo caching 2>&1)")"
printf '%s\n' "$out" | grep -qxF "  mine/workorders/WO-0003-plain" \
  || { echo "FAIL P1: playbook wo did not name a folder under a playbooks path holding |, & or [x]"; echo "  got: $out" | head -3; exit 1; }
# P2: a folder whose name holds a space or a quote is named whole
printf '%s\n' "$out" | grep -qxF "  mine/workorders/WO-0001-foo bar" && printf '%s\n' "$out" | grep -qxF "  mine/workorders/WO-0002-it's" \
  && [ "$(printf '%s\n' "$out" | grep -c '^  ')" = 3 ] || { echo "FAIL P2: a folder name holding a space or a quote was split or lost: $out"; exit 1; }
# P3: show names the folder from the playbook down, not by its full path
out="$(plain "$(PLAYBOOKS_DIR="$D" "$PB" show WO-0001 2>&1)")"
printf '%s\n' "$out" | grep -qxF "mine/workorders/WO-0001-foo bar" && printf '%s\n' "$out" | grep -qxF "    WO-0001-SPEC.md" \
  || { echo "FAIL P3: playbook show did not name the folder from the playbook down: $out"; exit 1; }
# P4: an ordinary playbooks path behaves as before
D2="$EVAL_TMP/plain/pb"; doc "$D2/mine/workorders/WO-0004-cache"
out="$(plain "$(PLAYBOOKS_DIR="$D2" "$PB" wo caching 2>&1)")"
[ "$out" = "$(printf 'WORK ORDERS\n  mine/workorders/WO-0004-cache')" ] || { echo "FAIL P4: an ordinary search changed: $out"; exit 1; }
out="$(plain "$(PLAYBOOKS_DIR="$D2" "$PB" show WO-0004 2>&1)")"
[ "$out" = "$(printf 'mine/workorders/WO-0004-cache\n    WO-0004-SPEC.md')" ] || { echo "FAIL P4: an ordinary show changed: $out"; exit 1; }
# P5: a folder with two matching documents is named once, a backslash in a name is kept, and at
# most 20 folders are named per playbook
D3="$EVAL_TMP/many/pb"; W3="$D3/mine/workorders"; doc "$W3/WO-0100-two"; printf 'caching again\n' > "$W3/WO-0100-two/notes.md"
doc "$W3/WO-0101-back\\slash"; printf 'a log about caching\n' > "$W3/WO-0100-two/run.log"
for i in $(seq 102 130); do doc "$W3/WO-0$i-n"; done
out="$(plain "$(PLAYBOOKS_DIR="$D3" "$PB" wo caching 2>&1)")"
{ [ "$(printf '%s\n' "$out" | grep -c '^  ')" = 20 ] && [ "$(printf '%s\n' "$out" | grep -cxF '  mine/workorders/WO-0100-two')" = 1 ] \
  && printf '%s\n' "$out" | grep -qxF '  mine/workorders/WO-0101-back\slash'; } \
  || { echo "FAIL P5: folders were repeated, cut at the wrong count, or lost a backslash: $(printf '%s\n' "$out" | head -4 | tr '\n' '|')"; exit 1; }
exit 0
