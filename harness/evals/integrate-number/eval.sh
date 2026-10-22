#!/usr/bin/env bash
# integrate-number: wo integrate writes its covers, its suite and its report against the number wo new reserved
# for it, not the highest WO-* name on disk.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p || exit 1
W=.aicodepipeline/bin/wo; D=Workspace/Docs/WorkOrders; SD=Workspace/Testing/suites
num() { $W new "$1" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1 | sed 's/WO-//'; }
a="$(num alpha)"; $W suite "$a" >/dev/null 2>&1; b="$(num beta)"; $W suite "$b" >/dev/null 2>&1
[ -n "$a" ] && [ -n "$b" ] && [ -f "$SD/wo-$a-alpha.sh" ] || { echo "FAIL setup: could not make two verified-looking orders"; exit 1; }
# a folder whose number part is not all digits, which numbering skips but sorts above every order
mkdir -p "$D/WO-0099x-stray"
# I1: the integration order is the one wo new made, and its covers and suite are written against it
out="$($W integrate "join" --covers "$a,$b" 2>/dev/null)"; rc=$?   # the report is on stdout
n="$(printf '%s\n' "$out" | sed -n 's/^WO-\([0-9][0-9]*\) created (.*/\1/p' | head -1)"
[ "$rc" -eq 0 ] && [ -n "$n" ] && printf '%s\n' "$out" | grep -qxF "Integration work order WO-$n covers: $a,$b" \
  || { echo "FAIL I1: wo integrate did not report the number wo new reserved for it (exit $rc)"; printf '  %s\n' "$out" | head -4; exit 1; }
j="$(ls -d "$D"/WO-"$n"-join 2>/dev/null)"
[ -n "$j" ] && grep -qxF "covers=$a,$b" "$j/.wo-meta" && [ -x "$SD/wo-$n-join.sh" ] && grep -qF "WO-$n" "$SD/wo-$n-join.sh" \
  || { echo "FAIL I1: the covers or the suite were not written against WO-$n"; exit 1; }
[ ! -e "$D/WO-0099x-stray/.wo-meta" ] && ! ls "$SD"/wo-0099x-* >/dev/null 2>&1 || { echo "FAIL I1: wo integrate wrote into the stray folder"; exit 1; }
# I2: a second integration, after another order has been opened, gets its own number too
c="$(num gamma)"; $W suite "$c" >/dev/null 2>&1
out="$($W integrate "join two" --covers "$a,$c" 2>&1)"; rc=$?
n2="$(printf '%s\n' "$out" | sed -n 's/^WO-\([0-9][0-9]*\) created (.*/\1/p' | head -1)"
[ "$rc" -eq 0 ] && [ -n "$n2" ] && [ "$n2" != "$n" ] && grep -qxF "covers=$a,$c" "$D/WO-$n2-join-two/.wo-meta" && [ -x "$SD/wo-$n2-join-two.sh" ] \
  || { echo "FAIL I2: a second integration was not written against its own number (exit $rc)"; exit 1; }
exit 0
