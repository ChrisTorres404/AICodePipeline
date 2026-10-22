#!/usr/bin/env bash
# adopt-no-folder: wo adopt works when the work-order folder does not exist yet, as wo new does, and says it
# creates it; before, it stopped with exit 1 and no word.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1; cd p || die "new-project failed"
W=./.aicodepipeline/bin/wo; WD=Workspace/Docs/WorkOrders
printf '# Old work\n\nDone long ago.\n' > old.md
mv "$WD" "$EVAL_TMP/wo-away" || die "the eval could not move the work-order folder away"
# A4 first: a dry run on a missing folder says what it would do and creates nothing
rc=0; out="$($W adopt old.md --number 7 --dry-run 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || die "FAIL A1: wo adopt stopped without a word when the work-order folder did not exist" "exit $rc" "$out"
printf '%s\n' "$out" | grep -q '^would adopt ' || die "FAIL A4: wo adopt --dry-run did not say what it would do" "$out"
[ -e "$WD" ] && die "FAIL A4: wo adopt --dry-run created the work-order folder"
rc=0; out="$($W adopt old.md --number 7 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || die "FAIL A1: wo adopt stopped without a word when the work-order folder did not exist" "exit $rc" "$out"
d="$(ls -d "$WD"/WO-0007-* 2>/dev/null | head -1)"
[ -n "$d" ] && [ -f "$d/.wo-meta" ] || die "FAIL A2: wo adopt did not create the adopted work order" "$out"
printf '%s\n' "$out" | grep -qxF "wo adopt: the work-order folder $WD does not exist yet; adopting creates it" \
  || die "FAIL A3: wo adopt did not say the work-order folder was missing" "$out"
# A5: with the folder there, adopt says nothing about it
printf '# Other work\n\nAlso done.\n' > other.md
out="$($W adopt other.md --number 8 2>&1)" || die "the second wo adopt failed" "$out"
printf '%s\n' "$out" | grep -qF 'does not exist yet' && die "FAIL A5: wo adopt said a folder that exists was missing" "$out"
# A6: a work-order folder that cannot be read is refused, so a number already taken is never taken twice
printf '# Third\n\nAgain.\n' > third.md
chmod 300 "$WD"
rc=0; out="$($W adopt third.md --number 7 2>&1)" || rc=$?
chmod 755 "$WD"
[ "$rc" -ne 0 ] || die "FAIL A6: wo adopt went on though it could not read the work-order folder" "$out"
[ "$(ls -d "$WD"/WO-0007-* | wc -l | tr -d ' ')" = 1 ] || die "FAIL A6: wo adopt made a second WO-0007" "$(ls "$WD")"
printf '%s\n' "$out" | grep -qF "wo adopt: cannot read the work-order folder $WD" || die "FAIL A6: wo adopt did not say it could not read the folder" "$out"
# A7: a work-order path that is a file is refused, with the right words
mv "$WD" "$EVAL_TMP/wo-away2" && printf 'not a folder\n' > "$WD"
rc=0; out="$($W adopt third.md --number 9 2>&1)" || rc=$?
rm -f "$WD" && mv "$EVAL_TMP/wo-away2" "$WD"
[ "$rc" -ne 0 ] || die "FAIL A7: wo adopt went on though the work-order path is a file" "$out"
printf '%s\n' "$out" | grep -qF "wo adopt: the work-order folder $WD is not a folder" || die "FAIL A7: wo adopt did not say the work-order path is not a folder" "$out"
printf '%s\n' "$out" | grep -qF 'does not exist yet' && die "FAIL A7: wo adopt said a path that exists does not" "$out"
echo "adopt-no-folder: all checks passed"
exit 0
