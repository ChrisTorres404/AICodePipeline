#!/usr/bin/env bash
# numbers: numbers a person gives (--series, --number, the import's issue number) are refused unless
# they are 1 to 4 digits, before any arithmetic, so none can run code; numbers read from folder names
# are never refused.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p || exit 1
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug; WD=Workspace/Docs/WorkOrders; BD=Workspace/Docs/Bugs
EVIL='1+a[$(touch PWNED)]'
# N1: wo new --series holding code is refused, and the code does not run
out="$($W new "evil series" --series "$EVIL" 2>&1)"; rc=$?
{ [ ! -e PWNED ] && [ "$rc" -ne 0 ] && ! ls -d "$WD"/WO-*-evil-series >/dev/null 2>&1; } || { echo "FAIL N1: wo new ran the --series value as code, or took it"; exit 1; }
printf '%s\n' "$out" | grep -qF "1 to 4 digits" || { echo "FAIL N1: wo new refused --series without saying why: $out"; exit 1; }
# N2: bug new --series, and the --number of wo adopt and bug adopt, the same
out="$($B new "evil bug" --series "$EVIL" 2>&1)"; rc=$?
{ [ ! -e PWNED ] && [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "1 to 4 digits"; } || { echo "FAIL N2: bug new took or ran a --series value that is not 1 to 4 digits: $out"; exit 1; }
printf '# rec\n' > "$EVAL_TMP/rec.md"
for c in "$W adopt $EVAL_TMP/rec.md --title x" "$B adopt $EVAL_TMP/rec.md --category database --title x"; do
  for v in 12345 '0x1F' ''; do
    out="$($c --number "$v" 2>&1)"; rc=$?
    { [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "1 to 4 digits|--number is required"; } || { echo "FAIL N2: '${c%% *} adopt' took --number '$v': $out"; exit 1; }
  done
done
# N3: wo import refuses an issue number that is not 1 to 4 digits, before asking GitHub
mkdir -p "$EVAL_TMP/gh" && printf '#!/usr/bin/env bash\necho "$*" >> "%s/gh.log"; echo title\n' "$EVAL_TMP" > "$EVAL_TMP/gh/gh" && chmod +x "$EVAL_TMP/gh/gh"
out="$(PATH="$EVAL_TMP/gh:$PATH" $W import "$EVIL" 2>&1)"; rc=$?
{ [ ! -e PWNED ] && [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "1 to 4 digits" && ! grep -qF 'issue view' "$EVAL_TMP/gh.log" 2>/dev/null; } \
  || { echo "FAIL N3: wo import took, passed on or ran an issue number that is not 1 to 4 digits: $out"; exit 1; }
# N3b: five digits are refused in each place too (the length rule, not only the digits)
out="$($W new "five series" --series 12345 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "1 to 4 digits" && ! ls -d "$WD"/WO-12345-* >/dev/null 2>&1; } || { echo "FAIL N3: wo new took --series 12345: $out"; exit 1; }
out="$($B new "five bug" --series 12345 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "1 to 4 digits"; } || { echo "FAIL N3: bug new took --series 12345: $out"; exit 1; }
rm -f "$EVAL_TMP/gh.log"; out="$(PATH="$EVAL_TMP/gh:$PATH" $W import 12345 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "the issue number must be 1 to 4 digits" && ! grep -qF 'issue view' "$EVAL_TMP/gh.log" 2>/dev/null; } \
  || { echo "FAIL N3: wo import took issue number 12345, or asked GitHub first: $out"; exit 1; }
# N4: good values are taken as before, leading zeros included
$W new "series ok" --series 0100 >/dev/null 2>&1 && ls -d "$WD"/WO-0100-series-ok >/dev/null 2>&1 || { echo "FAIL N4: wo new --series 0100 was refused"; exit 1; }
$B new "bug series ok" --series 0300 >/dev/null 2>&1 && ls -d "$BD"/BUG-0300-bug-series-ok >/dev/null 2>&1 || { echo "FAIL N4: bug new --series 0300 was refused"; exit 1; }
$W adopt "$EVAL_TMP/rec.md" --number 42 --title "adopted" >/dev/null 2>&1 && ls -d "$WD"/WO-0042-adopted >/dev/null 2>&1 || { echo "FAIL N4: wo adopt --number 42 was refused"; exit 1; }
# N5: a folder whose number has five digits, made by hand, never blocks wo new or bug new
mkdir -p "$WD/WO-10000-by-hand" "$BD/BUG-10000-by-hand"
$W new "after five digits" >/dev/null 2>&1 && ls -d "$WD"/WO-*-after-five-digits >/dev/null 2>&1 || { echo "FAIL N5: a five-digit folder blocked wo new"; exit 1; }
$B new "bug after five digits" >/dev/null 2>&1 && ls -d "$BD"/BUG-*-bug-after-five-digits >/dev/null 2>&1 || { echo "FAIL N5: a five-digit folder blocked bug new"; exit 1; }
[ ! -e PWNED ] || { echo "FAIL: a number ran as code"; exit 1; }
exit 0
