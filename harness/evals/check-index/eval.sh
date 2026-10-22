#!/usr/bin/env bash
# check-index: check.py --staged reads a work order's files and its VERIFICATION document from the index,
# as the commit will hold them, so a failing staged document cannot pass by a passing working copy.
set -uo pipefail
CK="$PIPELINE_ROOT/core/hooks/check.py"; PY="$(command -v python3)"
[ -f "$CK" ] && [ -n "$PY" ] || { echo "FAIL setup: check.py or python3 not found"; exit 1; }
G() { git -c user.name=t -c user.email=t@example.com "$@"; }
FAILED='**Overall status:** EXECUTED — FAIL (last run 1)'; PASSED='**Overall status:** EXECUTED — PASS (last run 1)'
O=Docs/WO-0001-x
repo() { R="$EVAL_TMP/$1"; mkdir -p "$R/$O" && G -C "$R" init -q && printf 'x\n' > "$R/README" && G -C "$R" add README && G -C "$R" commit -qm base \
  || { echo "FAIL setup: could not make a scratch repository"; exit 1; }; }
ver() { printf '# V\n\n%s\n' "$1" > "$R/$O/WO-0001-VERIFICATION.md"; }
close() { printf '# closeout\n' > "$R/$O/WO-0001-CLOSEOUT.md"; }
ck() { out="$(cd "$R" && "$PY" -I "$CK" --root "$R" --no-kb "$@" 2>&1)"; rc=$?; }
# E1: a staged failing VERIFICATION blocks, though the working copy has since been edited to PASS
repo e1; close; ver "$FAILED"; G -C "$R" add -A; ver "$PASSED"
ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "WO-0001-x: CLOSEOUT present but the latest verification run failed"; } \
  || { echo "FAIL E1: check.py --staged passed a staged failing VERIFICATION because the working copy says PASS (exit $rc)"; exit 1; }
# E2: the other way round, the commit holds a pass: a staged PASS passes though the working copy says FAIL
repo e2; close; ver "$PASSED"; G -C "$R" add -A; ver "$FAILED"
ck --staged; [ "$rc" -eq 0 ] || { echo "FAIL E2: check.py --staged blocked a staged passing VERIFICATION (exit $rc): $out"; exit 1; }
# E3: a staged CLOSEOUT with no VERIFICATION in the index blocks, though one sits unstaged in the working copy
repo e3; close; G -C "$R" add -A; ver "$PASSED"
ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "WO-0001-x: CLOSEOUT present, no VERIFICATION document"; } \
  || { echo "FAIL E3: check.py --staged passed a CLOSEOUT whose VERIFICATION is not in the commit (exit $rc): $out"; exit 1; }
# E4: a closed order already committed, with its VERIFICATION now staged as a failure, blocks
repo e4; close; ver "$PASSED"; G -C "$R" add -A && G -C "$R" commit -qm closed; ver "$FAILED"; G -C "$R" add -A; ver "$PASSED"
ck --staged; [ "$rc" -eq 2 ] || { echo "FAIL E4: a committed closeout with a staged failing VERIFICATION passed (exit $rc): $out"; exit 1; }
# E5: --since still reads the working copy
ck --since HEAD; [ "$rc" -eq 0 ] || { echo "FAIL E5: check.py --since did not read the working copy (exit $rc): $out"; exit 1; }
# E6: a staged document holding a NUL has no status line, and blocks
repo e6; close; printf '# V\n\n%s\n\0\n' "$PASSED" > "$R/$O/WO-0001-VERIFICATION.md"; G -C "$R" add -A; ver "$PASSED"
ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "VERIFICATION has no authoritative status line"; } || { echo "FAIL E6: a staged VERIFICATION holding a NUL was read as passed (exit $rc): $out"; exit 1; }
# E7: ordinary staged orders behave as before, and no temporary file is left behind
repo e7; close; ver "$PASSED"; G -C "$R" add -A; mkdir -p "$EVAL_TMP/t7"
out="$(cd "$R" && TMPDIR="$EVAL_TMP/t7" "$PY" -I "$CK" --root "$R" --no-kb --staged 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL E7: an ordinary passing order did not pass (exit $rc): $out"; exit 1; }
[ -z "$(ls -A "$EVAL_TMP/t7")" ] || { echo "FAIL E7: check.py --staged left a temporary file behind"; exit 1; }
# E8: only the order folder's own files count: a CLOSEOUT staged in a subfolder of it is not the order's
repo e8; mkdir -p "$R/$O/old" && printf '# closeout\n' > "$R/$O/old/WO-0001-CLOSEOUT.md" && printf 'n\n' > "$R/$O/notes.md"; G -C "$R" add -A
ck --staged; [ "$rc" -eq 0 ] || { echo "FAIL E8: a CLOSEOUT in a subfolder was taken as the order's own (exit $rc): $out"; exit 1; }
# E9: a staged CLOSEOUT and failing VERIFICATION, then removed from the working copy, still block;
# so does a staged CLOSEOUT alone, removed from disk
repo e9; close; ver "$FAILED"; G -C "$R" add -A; rm "$R/$O/WO-0001-CLOSEOUT.md" "$R/$O/WO-0001-VERIFICATION.md"
ck --staged; [ "$rc" -eq 2 ] || { echo "FAIL E9: a failing order staged and then removed from the working copy passed (exit $rc): $out"; exit 1; }
repo e9b; close; G -C "$R" add -A; rm "$R/$O/WO-0001-CLOSEOUT.md"
ck --staged; [ "$rc" -eq 2 ] || { echo "FAIL E9: a CLOSEOUT staged alone and removed from the working copy passed (exit $rc): $out"; exit 1; }
# E10: a committed closed order whose VERIFICATION the commit deletes (from the index only, or from
# both), or moves out of the folder, blocks
repo e10; close; ver "$PASSED"; G -C "$R" add -A && G -C "$R" commit -qm closed; G -C "$R" rm -q --cached "$O/WO-0001-VERIFICATION.md"
ck --staged; [ "$rc" -eq 2 ] || { echo "FAIL E10: a commit deleting a closed order's VERIFICATION from the index passed (exit $rc): $out"; exit 1; }
G -C "$R" reset -q; G -C "$R" rm -q "$O/WO-0001-VERIFICATION.md"
ck --staged; [ "$rc" -eq 2 ] || { echo "FAIL E10: a commit deleting a closed order's VERIFICATION passed (exit $rc): $out"; exit 1; }
G -C "$R" reset -q --hard; G -C "$R" mv "$O/WO-0001-VERIFICATION.md" "Docs/moved.md"
ck --staged; [ "$rc" -eq 2 ] || { echo "FAIL E10: a commit moving a closed order's VERIFICATION out of its folder passed (exit $rc): $out"; exit 1; }
# E11: a VERIFICATION staged as a symbolic link whose target's name reads as a passing status line blocks
repo e11; close; ln -s "$PASSED" "$R/$O/WO-0001-VERIFICATION.md"; G -C "$R" add -A
ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "VERIFICATION has no authoritative status line"; } || { echo "FAIL E11: a VERIFICATION staged as a symbolic link was read as passed (exit $rc): $out"; exit 1; }
# E12: a VERIFICATION entry git cannot read back blocks
repo e12; close; G -C "$R" add -A && G -C "$R" update-index --add --info-only --cacheinfo "100644,1234567890123456789012345678901234567890,$O/WO-0001-VERIFICATION.md" \
  || { echo "FAIL setup: could not stage an unreadable entry"; exit 1; }
ck --staged; [ "$rc" -eq 2 ] || { echo "FAIL E12: a VERIFICATION entry git could not read was passed (exit $rc): $out"; exit 1; }
# E13: a folder name holding glob characters is taken literally: another folder's VERIFICATION does not count
repo e13; mkdir -p "$R/Docs/WO-0002-[ab]" "$R/Docs/WO-0002-a" && printf '# closeout\n' > "$R/Docs/WO-0002-[ab]/WO-0002-CLOSEOUT.md" \
  && printf '# V\n\n%s\n' "$PASSED" > "$R/Docs/WO-0002-a/WO-0002-VERIFICATION.md" && G -C "$R" add -A
ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "WO-0002-[ab]: CLOSEOUT present, no VERIFICATION document"; } || { echo "FAIL E13: a folder name holding glob characters borrowed another folder's VERIFICATION (exit $rc): $out"; exit 1; }
# E14: a folder whose path starts with 0: is read as itself, not as another file git would name by it
repo e14; mkdir -p "$R/0:x/WO-0003-y" "$R/x/WO-0003-y" && printf '# closeout\n' > "$R/0:x/WO-0003-y/WO-0003-CLOSEOUT.md" \
  && printf '# V\n\n%s\n' "$FAILED" > "$R/0:x/WO-0003-y/WO-0003-VERIFICATION.md" && printf '# V\n\n%s\n' "$PASSED" > "$R/x/WO-0003-y/WO-0003-VERIFICATION.md" \
  && G -C "$R" add -A || { echo "FAIL setup: could not stage E14"; exit 1; }
ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "0:x/WO-0003-y: CLOSEOUT present but the latest verification run failed"; } \
  || { echo "FAIL E14: a folder whose path starts with 0: was read from another folder's document (exit $rc): $out"; exit 1; }
# E15: a VERIFICATION left in conflict (no stage 0 entry) blocks, whatever the conflict's sides say
repo e15; close; G -C "$R" add -A; hf="$(printf '# V\n\n%s\n' "$FAILED" | G -C "$R" hash-object -w --stdin)"; hp="$(printf '# V\n\n%s\n' "$PASSED" | G -C "$R" hash-object -w --stdin)"
printf '100644 %s 1\t%s\n100644 %s 2\t%s\n100644 %s 3\t%s\n' "$hf" "$O/WO-0001-VERIFICATION.md" "$hf" "$O/WO-0001-VERIFICATION.md" "$hp" "$O/WO-0001-VERIFICATION.md" \
  | G -C "$R" update-index --index-info || { echo "FAIL setup: could not stage a conflict"; exit 1; }
ck --staged; [ "$rc" -eq 2 ] || { echo "FAIL E15: a VERIFICATION left in conflict was read as passed (exit $rc): $out"; exit 1; }
# E16: an order staged under a folder name in decomposed form (as a branch made on Linux brings it) is checked
repo e16; hc="$(printf '# closeout\n' | G -C "$R" hash-object -w --stdin)"; hf="$(printf '# V\n\n%s\n' "$FAILED" | G -C "$R" hash-object -w --stdin)"
NFD="$(printf 'Docs/Cafe\314\201/WO-0003-y')"
printf '100644 %s 0\t%s\n100644 %s 0\t%s\n' "$hc" "$NFD/WO-0003-CLOSEOUT.md" "$hf" "$NFD/WO-0003-VERIFICATION.md" | G -C "$R" update-index --index-info \
  || { echo "FAIL setup: could not stage E16"; exit 1; }
ck --staged; [ "$rc" -eq 2 ] || { echo "FAIL E16: an order staged under a decomposed folder name passed (exit $rc): $out"; exit 1; }
# E17: a folder name holding glob characters reads its own VERIFICATION, not another folder's
repo e17; mkdir -p "$R/Docs/WO-0004-[ab]" "$R/Docs/WO-0004-a" && printf '# closeout\n' > "$R/Docs/WO-0004-[ab]/WO-0004-CLOSEOUT.md" \
  && printf '# V\n\n%s\n' "$FAILED" > "$R/Docs/WO-0004-[ab]/WO-0004-VERIFICATION.md" && printf '# V\n\n%s\n' "$PASSED" > "$R/Docs/WO-0004-a/WO-0004-VERIFICATION.md" && G -C "$R" add -A
ck --staged
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "WO-0004-[ab]: CLOSEOUT present but the latest verification run failed"; } || { echo "FAIL E17: a folder name holding glob characters read another folder's VERIFICATION (exit $rc): $out"; exit 1; }
# E18: a GIT_*_PATHSPECS setting in the environment does not empty the listing: a failing order still blocks
repo e18; close; ver "$FAILED"; G -C "$R" add -A
for v in GIT_ICASE_PATHSPECS GIT_GLOB_PATHSPECS; do
  out="$(cd "$R" && env "$v=1" "$PY" -I "$CK" --root "$R" --no-kb --staged 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] || { echo "FAIL E18: with $v=1 a failing order passed check.py --staged (exit $rc): $out"; exit 1; }
done
exit 0
