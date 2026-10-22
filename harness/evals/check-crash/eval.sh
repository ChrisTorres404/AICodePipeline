#!/usr/bin/env bash
# check-crash: check.py exits 3 when the checks break part-way, and keeps 0, 1 and 2 as they were.
set -uo pipefail
src="$PIPELINE_ROOT/core/hooks"
[ -f "$src/check.py" ] || { echo "FAIL setup: core/hooks/check.py is missing"; exit 1; }
P="$EVAL_TMP/proj"; mkdir -p "$P"
( cd "$P" && git init -q && printf 'x = 1\n' > a.py && git add a.py && git -c user.name=t -c user.email=t@example.com commit -qm base ) \
  || { echo "FAIL setup: could not make the scratch repository"; exit 1; }
# a credential-shaped line, assembled at run time so this file carries none
printf '%s_%s = "%s%s"\n' aws_secret access_key AKIAIOSFODNN7 EXAMPLEKEYZZ1234567890abcd > "$P/s.py"
run() { python3 "$@" >"$EVAL_TMP/out" 2>"$EVAL_TMP/err"; RC=$?; }

# K1: a rule that breaks part-way through the checks gives exit 3 and says so
# (the copy keeps bin/sanitize two levels above the hooks, as an install does: the key list lives there)
mkdir -p "$EVAL_TMP/b/core" "$EVAL_TMP/b/bin" && cp -R "$src" "$EVAL_TMP/b/core/hooks" && cp "$PIPELINE_ROOT/bin/sanitize" "$EVAL_TMP/b/bin/"
printf '\nRULES = list(RULES) + [(None, "planted crash")]\n' >> "$EVAL_TMP/b/core/hooks/quality-gate.py"
run "$EVAL_TMP/b/core/hooks/check.py" --root "$P" --paths "$P/a.py"
[ "$RC" -eq 3 ] || { echo "FAIL K1: a crash inside the checks exited $RC, not 3"; exit 1; }
grep -q '^Traceback (most recent call last):' "$EVAL_TMP/err" || { echo "FAIL K1: a crash gave exit 3 without the traceback"; exit 1; }
grep -q '^check: internal error (AttributeError: ' "$EVAL_TMP/err" || { echo "FAIL K1: a crash gave exit 3 without saying why"; exit 1; }

# K2-K5: the other exit codes are unchanged
run "$src/check.py" --root "$P" --paths "$P/a.py";               [ "$RC" -eq 0 ] || { echo "FAIL K2: a clean file exited $RC, not 0"; exit 1; }
run "$src/check.py" --root "$P" --manifest "$EVAL_TMP/no-such"; [ "$RC" -eq 1 ] || { echo "FAIL K3: a missing manifest exited $RC, not 1"; exit 1; }
run "$src/check.py" --root "$P" --paths "$P/s.py";               [ "$RC" -eq 2 ] || { echo "FAIL K4: a credential exited $RC, not 2"; exit 1; }
run "$src/check.py" --no-such-option;                            [ "$RC" -eq 2 ] || { echo "FAIL K5: a bad option exited $RC, not 2"; exit 1; }
# K6: a failure outside the rules (writing a manifest into a folder that does not exist) also gives 3
run "$src/check.py" --root "$P" --write-manifest "$EVAL_TMP/no/such/dir/m"; [ "$RC" -eq 3 ] || { echo "FAIL K6: a failure outside the rules exited $RC, not 3"; exit 1; }
exit 0
