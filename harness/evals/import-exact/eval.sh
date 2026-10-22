#!/usr/bin/env bash
# import-exact: wo import opens the work order numbered exactly as the issue, or refuses; it no longer dies
# on a closed pipe; a GitHub title is trimmed to 200 bytes and can never be read as a flag. wo new
# --number N takes exactly N, and wo new -- "<title>" takes a title that starts with a dash.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; WD=Workspace/Docs/WorkOrders
mkdir -p "$EVAL_TMP/gh"; export MOCK_LOG="$EVAL_TMP/gh.log"
cat > "$EVAL_TMP/gh/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  "repo view"*) echo me/proj;;
  "issue view "*"--json title"*) printf '%s\n' "${MOCK_TITLE:-Imported issue}";;
  "issue view "*"--json body"*) echo "issue body text";;
  "issue view "*"--json url"*) echo "https://example.com/me/proj/issues/$3";;
  *) echo "$*" >> "$MOCK_LOG";;
esac
GH
chmod +x "$EVAL_TMP/gh/gh"
imp() { out="$(PATH="$EVAL_TMP/gh:$PATH" $W import "$@" 2>&1)"; rc=$?; }
meta() { sed -n "s/^$2=//p" "$(ls -d "$WD/WO-$1"-*/.wo-meta 2>/dev/null | head -1)" 2>/dev/null; }
# I1: wo import 42 opens WO-0042 with the issue attached
imp 42
{ [ "$rc" -eq 0 ] && [ "$(meta 0042 issue_number)" = 42 ] && [ "$(meta 0042 issue)" = "https://example.com/me/proj/issues/42" ] \
  && grep -qF "From issue #42" "$(ls -d "$WD"/WO-0042-*/WO-0042-SPEC.md | head -1)" \
  && [ "$(printf '%s\n' "$out" | head -1 | cut -c1-16)" = "WO-0042 created " ]; } \
  || { echo "FAIL I1: wo import 42 did not open WO-0042 with the issue attached"; echo "  exit $rc"; exit 1; }
# I2: an issue whose number is taken is refused, and the order that holds the number is left alone
before="$(cat "$WD"/WO-0003-*/.wo-meta)"; n="$(ls -d "$WD"/WO-* | grep -c .)"
imp 3
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "WO-0003 already exists" && [ "$(cat "$WD"/WO-0003-*/.wo-meta)" = "$before" ] && [ "$(ls -d "$WD"/WO-* | grep -c .)" = "$n" ]; } \
  || { echo "FAIL I2: wo import 3 did not refuse a taken number, or touched WO-0003"; echo "  exit $rc"; exit 1; }
# I3: the exact number, even when a higher number in its band exists
mkdir -p "$WD/WO-0070-hand-made"; printf '# hand made\n' > "$WD/WO-0070-hand-made/WO-0070-hand-made.md"
imp 60
{ [ "$rc" -eq 0 ] && [ "$(meta 0060 issue_number)" = 60 ] && ! ls -d "$WD"/WO-0071-* >/dev/null 2>&1; } \
  || { echo "FAIL I3: wo import 60 did not open exactly WO-0060"; echo "  exit $rc"; exit 1; }
# I4: a title that starts with a dash is a title, not a flag
MOCK_TITLE="--force everything" imp 61
{ [ "$rc" -eq 0 ] && [ "$(meta 0061 title)" = "--force everything" ]; } || { echo "FAIL I4: wo import read a title starting with a dash as a flag"; echo "  exit $rc"; exit 1; }
# I5: a long title is trimmed to 200 bytes, on a character boundary
MOCK_TITLE="$(printf 'x%.0s' $(seq 1 250))" imp 62
{ [ "$rc" -eq 0 ] && [ "$(printf '%s' "$(meta 0062 title)" | LC_ALL=C wc -c | tr -d ' ')" -eq 200 ]; } || { echo "FAIL I5: wo import did not trim a long title to 200 bytes"; echo "  exit $rc"; exit 1; }
MOCK_TITLE="$(printf '日%.0s' $(seq 1 90))" LC_ALL=C.UTF-8 imp 63
t="$(meta 0063 title)"
{ [ "$rc" -eq 0 ] && [ "$(printf '%s' "$t" | LC_ALL=C wc -c | tr -d ' ')" -le 200 ] && [ "$(printf '%s' "$t" | iconv -f UTF-8 -t UTF-8 2>/dev/null)" = "$t" ]; } \
  || { echo "FAIL I5: wo import did not trim a long title on a character boundary"; echo "  exit $rc"; exit 1; }
MOCK_TITLE="$(printf '日%.0s' $(seq 1 90))" LC_ALL=C imp 64
t="$(meta 0064 title)"
{ [ "$rc" -eq 0 ] && [ "$(printf '%s' "$t" | LC_ALL=C wc -c | tr -d ' ')" -le 200 ] && [ "$(printf '%s' "$t" | iconv -f UTF-8 -t UTF-8 2>/dev/null)" = "$t" ]; } \
  || { echo "FAIL I5: wo import did not trim a long title on a character boundary under the C locale"; echo "  exit $rc"; exit 1; }
# I8: when making the order fails part-way, wo import fails and leaves no half-made folder
mkdir -p "$EVAL_TMP/badperl"; printf '#!/bin/sh\nexit 1\n' > "$EVAL_TMP/badperl/perl"; chmod +x "$EVAL_TMP/badperl/perl"
out="$(PATH="$EVAL_TMP/badperl:$EVAL_TMP/gh:$PATH" $W import 65 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! ls -d "$WD"/WO-0065-* >/dev/null 2>&1; } || { echo "FAIL I8: a wo import that failed part-way kept a half-made folder"; echo "  exit $rc"; exit 1; }
# I6: wo new --number N takes exactly N, refuses a taken number, 0, anything but 1 to 4 digits, and --series with it
a="$($W new "exact" --number 7 2>&1 | grep -o 'WO-[0-9]*' | head -1)"
[ "$a" = WO-0007 ] || { echo "FAIL I6: wo new --number 7 did not open WO-0007"; echo "  got: $a"; exit 1; }
for c in "7|WO-0007 already exists" "0|must not be 0" "1a|1 to 4 digits" "12345|1 to 4 digits" "|1 to 4 digits"; do
  out="$($W new "exact again" --number "${c%%|*}" 2>&1)" && { echo "FAIL I6: wo new --number refused nothing"; echo "  --number ${c%%|*}"; exit 1; }
  printf '%s\n' "$out" | grep -qF "${c#*|}" || { echo "FAIL I6: wo new --number refused without saying why"; echo "  --number ${c%%|*}: $out"; exit 1; }
done
out="$($W new "both" --number 8 --series 100 2>&1)" && { echo "FAIL I6: wo new took --number and --series together"; exit 1; }
printf '%s\n' "$out" | grep -qF "not both" || { echo "FAIL I6: wo new refused --number with --series without saying why"; exit 1; }
ls -d "$WD"/WO-0008-* "$WD"/WO--* >/dev/null 2>&1 && { echo "FAIL I6: a refused wo new --number left a folder"; exit 1; }
# I7: wo new -- "<title>" takes a title that starts with a dash
b="$($W new -- "-dash first" 2>&1 | grep -o 'WO-[0-9]*' | head -1)"
{ [ -n "$b" ] && [ "$(meta "${b#WO-}" title)" = "-dash first" ]; } || { echo "FAIL I7: wo new -- did not take a title starting with a dash"; echo "  got: $b"; exit 1; }
out="$($W new -- "-x" extra 2>&1)" && { echo "FAIL I7: wo new -- took more than one title"; exit 1; }
exit 0
