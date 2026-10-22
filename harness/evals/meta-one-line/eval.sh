#!/usr/bin/env bash
# meta-one-line: every value wo new, wo adopt, bug new and bug adopt write into .wo-meta or .bug-meta (except
# --paths, which this does not yet check) is one line and an allowed value, so no value can add a line such as status=closed.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug; WD=Workspace/Docs/WorkOrders; BD=Workspace/Docs/Bugs
folders() { ls -d "$WD"/WO-* "$BD"/BUG-* 2>/dev/null | grep -c . || true; }
refused() { # <id> <what> <command...>: the command fails and makes no folder
  local id="$1" what="$2"; shift 2; local before; before="$(folders)"
  out="$("$@" 2>&1)" && { echo "FAIL $id: $what was accepted"; exit 1; }
  [ "$(folders)" = "$before" ] || { echo "FAIL $id: $what was refused but left a folder"; exit 1; }; }
one_status() { [ "$(grep -c '^status=' "$1")" -le 1 ] && ! grep -qx 'status=closed' "$1" && ! grep -qx 'status=blocked' "$1"; }
printf '# Old record\n\nbody\n' > rec.md
nl="$(printf 'rec\nstatus=blocked.md')"; cp rec.md "$nl"
# M1: wo adopt refuses a record whose path holds a newline (it is written as adopted_from)
refused M1 "a wo adopt of a record whose path holds a newline" $W adopt "$nl" --number 60 --title ok
# M2: --opened is a date and nothing else
refused M2 "a wo adopt --opened holding a newline" $W adopt rec.md --number 61 --opened "$(printf '2020-01-01\nstatus=closed')"
refused M2 "a wo adopt --opened that is not YYYY-MM-DD" $W adopt rec.md --number 62 --opened 2020-1-1
$W adopt rec.md --number 63 --opened 2020-01-01 >/dev/null 2>&1 && grep -qx 'created=2020-01-01' "$(ls -d "$WD"/WO-0063-*/.wo-meta | head -1)" \
  || { echo "FAIL M2: wo adopt --opened 2020-01-01 was not written"; exit 1; }
# M3: --priority is P0 to P3
refused M3 "a wo new --priority holding a newline" $W new "prio nl" --priority "$(printf 'P1\nstatus=closed')"
refused M3 "a wo new --priority outside P0 to P3" $W new "prio bad" --priority P9
refused M3 "a wo new --priority P4" $W new "prio four" --priority P4
$W new "prio ok" --priority P0 >/dev/null 2>&1 && grep -qx 'priority=P0' "$(ls -d "$WD"/WO-*-prio-ok/.wo-meta | head -1)" || { echo "FAIL M3: wo new --priority P0 was not written"; exit 1; }
# M4: bug adopt takes only a known category and status, and refuses a record path holding a newline
refused M4 "a bug adopt with an unknown category" $B adopt rec.md --number 70 --category nope
refused M4 "a bug adopt --category holding a newline" $B adopt rec.md --number 71 --category "$(printf 'database\nstatus=closed')"
refused M4 "a bug adopt with an unknown status" $B adopt rec.md --number 72 --category database --status closed
refused M4 "a bug adopt --status blocked" $B adopt rec.md --number 76 --category database --status blocked
refused M4 "a bug adopt of a record whose path holds a newline" $B adopt "$nl" --number 73 --category database --title ok
$B adopt rec.md --number 74 --category database --status fixed >/dev/null 2>&1 && grep -qx 'status=fixed' "$(ls -d "$BD"/BUG-0074-*/.bug-meta | head -1)" \
  || { echo "FAIL M4: bug adopt --status fixed was not written"; exit 1; }
$B adopt rec.md --number 77 --category other >/dev/null 2>&1 && grep -qx 'category=other' "$(ls -d "$BD"/BUG-0077-*/.bug-meta | head -1)" \
  || { echo "FAIL M4: bug adopt --category other, which intake's inventory writes, was refused"; exit 1; }
# M5: an owner name from git holding a newline is written on one line, in all four commands
git config user.name "$(printf 'Ann\nstatus=closed')"
mkdir -p "$WD/WO-0091-legacy" "$BD/BUG-0092-legacy"; cp rec.md "$WD/WO-0091-legacy/WO-0091-legacy.md"; cp rec.md "$BD/BUG-0092-legacy/BUG-0092-legacy.md"
$W new "owner nl" >/dev/null 2>&1; $W adopt rec.md --number 90 >/dev/null 2>&1; $W adopt "$WD/WO-0091-legacy/WO-0091-legacy.md" --number 91 >/dev/null 2>&1
$B new "owner nl" --category database >/dev/null 2>&1; $B adopt rec.md --number 93 --category database >/dev/null 2>&1
$B adopt "$BD/BUG-0092-legacy/BUG-0092-legacy.md" --number 92 --category database >/dev/null 2>&1
for m in "$(ls -d "$WD"/WO-*-owner-nl/.wo-meta | head -1)" "$(ls -d "$WD"/WO-0090-*/.wo-meta | head -1)" "$WD/WO-0091-legacy/.wo-meta" \
         "$(ls -d "$BD"/BUG-*-owner-nl/.bug-meta | head -1)" "$(ls -d "$BD"/BUG-0093-*/.bug-meta | head -1)" "$BD/BUG-0092-legacy/.bug-meta"; do
  { [ -f "$m" ] && one_status "$m" && [ "$(grep -c '^owner=' "$m")" = 1 ]; } || { echo "FAIL M5: an owner name holding a newline added a line to the metadata"; echo "  $m"; exit 1; }
done
git config user.name t
# M6: no record shows as blocked or closed through a forged line
$W list 2>/dev/null | grep -E 'WO-006[0-4]|WO-009[01]|prio|owner' | grep -qiE 'blocked|closed' && { echo "FAIL M6: wo list shows an order blocked or closed through a forged line"; exit 1; }
$B list 2>/dev/null | grep -E 'BUG-007[0-7]|BUG-009[23]|owner' | grep -qiE 'blocked|closed' && { echo "FAIL M6: bug list shows a bug blocked or closed through a forged line"; exit 1; }
exit 0
