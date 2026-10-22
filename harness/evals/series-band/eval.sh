#!/usr/bin/env bash
# series-band: wo new --series N takes the next number in N's band (0100 means 0100-0199), as bug new
# does: the second order in a series gets the next number, a full band refuses rather than spilling
# into the next, and series 0 never matches every number as a prefix. bug new refuses a full band too.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; WD=Workspace/Docs/WorkOrders
num() { printf '%s\n' "$1" | grep -o 'WO-[0-9][0-9]*' | head -1; }
folders() { ls -d "$WD"/WO-* 2>/dev/null | grep -c . || true; }
# S1: the first two orders in series 100 are WO-0100 and WO-0101
a="$(num "$($W new "first in band" --series 100 2>&1)")"; b="$(num "$($W new "second in band" --series 100 2>&1)")"
{ [ "$a" = WO-0100 ] && [ "$b" = WO-0101 ]; } || { echo "FAIL S1: a second wo new --series 100 did not open WO-0101"; echo "  got: $a then $b"; exit 1; }
# S2: another series is its own band
c="$(num "$($W new "other band" --series 300 2>&1)")"
[ "$c" = WO-0300 ] || { echo "FAIL S2: wo new --series 300 did not open WO-0300"; echo "  got: $c"; exit 1; }
# S3: the band continues from its highest number, not from the highest number anywhere
d="$(num "$($W new "third in band" --series 100 2>&1)")"
[ "$d" = WO-0102 ] || { echo "FAIL S3: wo new --series 100 did not continue its own band"; echo "  got: $d"; exit 1; }
# S4: series 0 is the band 0000-0099, never a prefix of every number, and never WO-0000
e="$(num "$($W new "zero band" --series 0 2>&1)")"
case "$e" in WO-00[0-9][0-9]) [ "$e" != WO-0000 ] ;; *) false;; esac || { echo "FAIL S4: wo new --series 0 did not stay in 0001-0099"; echo "  got: $e"; exit 1; }
# S5: a full band refuses, says so, makes no folder, and never spills into the next band
mkdir -p "$WD/WO-0199-hand-made"; printf '# hand made\n' > "$WD/WO-0199-hand-made/WO-0199-hand-made.md"
before="$(folders)"; out="$($W new "past the band" --series 100 2>&1)" && { echo "FAIL S5: wo new --series 100 opened an order past a full band"; echo "  got: $(num "$out")"; exit 1; }
printf '%s\n' "$out" | grep -qF "is full" || { echo "FAIL S5: a full band was refused without saying it is full"; exit 1; }
[ "$(folders)" = "$before" ] || { echo "FAIL S5: a refused full band left a folder"; exit 1; }
ls -d "$WD"/WO-0200-* >/dev/null 2>&1 && { echo "FAIL S5: a full band spilled into the next band"; exit 1; }
ls -d "$WD"/WO--* >/dev/null 2>&1 && { echo "FAIL S5: a full band made a folder with no number"; exit 1; }
# S6: without --series, the next number is the highest anywhere plus one, as before
f="$(num "$($W new "no series" 2>&1)")"
[ "$f" = WO-0301 ] || { echo "FAIL S6: wo new without --series did not take the highest number plus one"; echo "  got: $f"; exit 1; }
# S7: bug new refuses a full band the same way: it fails, says so, and makes no folder (none without a number)
BD=Workspace/Docs/Bugs; mkdir -p "$BD/BUG-0199-hand-made"
bb="$(ls -d "$BD"/BUG-* 2>/dev/null | grep -c . || true)"
out="$(.aicodepipeline/bin/bug new "past the band" --series 100 --category database 2>&1)" && { echo "FAIL S7: bug new opened a bug past a full band"; exit 1; }
printf '%s\n' "$out" | grep -qF "is full" || { echo "FAIL S7: bug new refused a full band without saying it is full"; exit 1; }
[ "$(ls -d "$BD"/BUG-* 2>/dev/null | grep -c . || true)" = "$bb" ] || { echo "FAIL S7: bug new left a folder for a full band"; exit 1; }
# S8: in a project with no orders, the first number is WO-0001, with or without --series 0 (never WO-0000)
cd "$EVAL_TMP" && "$PIPELINE_ROOT/bin/new-project" q --name Q --no-git >/dev/null 2>&1 || { echo "FAIL setup: the second new-project failed"; exit 1; }
cd q && rm -rf Workspace/Docs/WorkOrders/WO-*
g="$(num "$(.aicodepipeline/bin/wo new "first ever" 2>&1)")"
[ "$g" = WO-0001 ] || { echo "FAIL S8: the first order of an empty project is not WO-0001"; echo "  got: $g"; exit 1; }
rm -rf Workspace/Docs/WorkOrders/WO-*
h="$(num "$(.aicodepipeline/bin/wo new "first in zero band" --series 0 2>&1)")"
[ "$h" = WO-0001 ] || { echo "FAIL S8: wo new --series 0 in an empty project is not WO-0001"; echo "  got: $h"; exit 1; }
exit 0
