#!/usr/bin/env bash
# check-paths: check.py --staged and --since read git's paths with -z, so a work order whose path holds a
# space, a non-ASCII letter or a double quote is checked, and a byte that is not UTF-8 blinds nothing.
set -uo pipefail
CK="$PIPELINE_ROOT/core/hooks/check.py"; PY="$(command -v python3)"
[ -f "$CK" ] && [ -n "$PY" ] || { echo "FAIL setup: check.py or python3 not found"; exit 1; }
G() { git -c user.name=t -c user.email=t@example.com "$@"; }
FAILED='**Overall status:** EXECUTED — FAIL (last run 1)'; PASSED='**Overall status:** EXECUTED — PASS (last run 1)'
order() { # <folder> <status line>: a closed order in $R
  mkdir -p "$R/$1" && printf '# closeout\n' > "$R/$1/$(basename "$1" | cut -d- -f1-2)-CLOSEOUT.md" \
    && printf '# V\n\n%s\n' "$2" > "$R/$1/$(basename "$1" | cut -d- -f1-2)-VERIFICATION.md"; }
repo() { R="$EVAL_TMP/$1"; mkdir -p "$R" && G -C "$R" init -q && printf 'x\n' > "$R/README" && G -C "$R" add README && G -C "$R" commit -qm base \
  || { echo "FAIL setup: could not make a scratch repository"; exit 1; }; }
ck() { out="$(cd "$R" && "$PY" -I "$CK" --root "$R" --no-kb "$@" 2>&1)"; rc=$?; }
# K1: a staged failing order under a path holding a non-ASCII letter blocks, naming it
repo k1; order "Docs/WO-0001-café" "$FAILED"; G -C "$R" add -A
ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "WO-0001-café: CLOSEOUT present but the latest verification run failed"; } \
  || { echo "FAIL K1: check.py --staged passed a failing order under a path holding a non-ASCII letter (exit $rc)"; exit 1; }
# K2: the same for a space and a double quote
repo k2; order "Docs/WO-0002-a b" "$FAILED"; order 'Docs/WO-0003-q"x' "$FAILED"; G -C "$R" add -A
ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "WO-0002-a b: CLOSEOUT present" && printf '%s\n' "$out" | grep -qF 'WO-0003-q"x: CLOSEOUT present'; } \
  || { echo "FAIL K2: check.py --staged passed a failing order under a path holding a space or a double quote (exit $rc): $out"; exit 1; }
# K3: --since reads changed and untracked paths the same way
repo k3; order "Docs/WO-0004-é y" "$PASSED"; G -C "$R" add -A && G -C "$R" commit -qm o
order "Docs/WO-0004-é y" "$FAILED"; order "Docs/WO-0005-ü z" "$FAILED"
ck --since HEAD
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "WO-0004-é y: CLOSEOUT present" && printf '%s\n' "$out" | grep -qF "WO-0005-ü z: CLOSEOUT present"; } \
  || { echo "FAIL K3: check.py --since passed a failing order under such a path (exit $rc): $out"; exit 1; }
# K4: the file set is exactly the paths git names: a staged rename by its new path, a deletion left out
repo k4; mkdir -p "$R/a b" && printf '1\n' > "$R/a b/old é.txt" && printf '1\n' > "$R/gone.txt" && G -C "$R" add -A && G -C "$R" commit -qm f
G -C "$R" mv "a b/old é.txt" "a b/new é.txt" && G -C "$R" rm -q gone.txt && printf '2\n' > "$R/plain.txt" && G -C "$R" add plain.txt
ck --staged --list
[ "$rc" -eq 0 ] && [ "$out" = "$(printf 'a b/new é.txt\nplain.txt')" ] || { echo "FAIL K4: check.py --staged --list did not give exactly the staged paths: $out"; exit 1; }
# K5: a staged path holding a byte that is not UTF-8 does not blind the others
repo k5; order "Docs/WO-0006-p" "$FAILED"; G -C "$R" add -A
h="$(printf 'x\n' | G -C "$R" hash-object -w --stdin)" && G -C "$R" update-index --add --cacheinfo "100644,$h,$(printf 'bad\377.txt')" || { echo "FAIL setup: could not stage the byte path"; exit 1; }
ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "WO-0006-p: CLOSEOUT present"; } || { echo "FAIL K5: a path holding a byte that is not UTF-8 blinded check.py --staged (exit $rc): $out"; exit 1; }
# K6: an ordinary passing order passes, and an ordinary failing one blocks
repo k6; order "Docs/WO-0007-ok" "$PASSED"; G -C "$R" add -A; ck --staged
[ "$rc" -eq 0 ] || { echo "FAIL K6: an ordinary passing order did not pass (exit $rc): $out"; exit 1; }
order "Docs/WO-0008-no" "$FAILED"; G -C "$R" add -A; ck --staged
[ "$rc" -eq 2 ] || { echo "FAIL K6: an ordinary failing order did not block (exit $rc): $out"; exit 1; }
# K7: a new configuration under such a path is allowed, a changed one blocks (the A/M status is kept)
repo k7; mkdir -p "$R/web é" && printf '{}\n' > "$R/web é/.eslintrc.json" && G -C "$R" add -A; ck --staged
[ "$rc" -eq 0 ] || { echo "FAIL K7: a new configuration under a path holding a non-ASCII letter was refused (exit $rc): $out"; exit 1; }
G -C "$R" commit -qm c && printf '{"rules":{}}\n' > "$R/web é/.eslintrc.json" && G -C "$R" add -A; ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "web é/.eslintrc.json: lint, format, or strictness configuration changed"; } \
  || { echo "FAIL K7: a changed configuration under a path holding a non-ASCII letter passed (exit $rc): $out"; exit 1; }
# K8: a staged copy (three fields) keeps the fields after it in step, and a type change of a
# configuration counts as a change
repo k8; G -C "$R" config diff.renames copies; seq 1 200 > "$R/a.txt"; mkdir -p "$R/web é" && printf '{}\n' > "$R/web é/.eslintrc.json"
G -C "$R" add -A && G -C "$R" commit -qm f && cp "$R/a.txt" "$R/c é.txt" && echo 201 >> "$R/a.txt" && order "Docs/WO-0010-é" "$FAILED" \
  && rm "$R/web é/.eslintrc.json" && ln -s ../a.txt "$R/web é/.eslintrc.json" && G -C "$R" add -A || { echo "FAIL setup: could not stage K8"; exit 1; }
G -C "$R" diff --cached --name-status | grep -q '^C' && G -C "$R" diff --cached --name-status | grep -q '^T' || { echo "FAIL setup: git did not report a copy and a type change"; exit 1; }
ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "WO-0010-é: CLOSEOUT present" && printf '%s\n' "$out" | grep -qF "web é/.eslintrc.json: lint, format"; } \
  || { echo "FAIL K8: after a staged copy or a type change check.py lost a path (exit $rc): $out"; exit 1; }
exit 0
