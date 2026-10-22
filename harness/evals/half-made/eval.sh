#!/usr/bin/env bash
# half-made: when wo new, wo adopt, bug new or bug adopt fails after reserving its number, the half-made
# folder is removed, so the number is free again; a successful one keeps its folder as before.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p || exit 1
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug; WT=.aicodepipeline/core/templates/workorders; BT=.aicodepipeline/core/templates/bugs
WD=Workspace/Docs/WorkOrders; BD=Workspace/Docs/Bugs
[ -f "$WT/WO-TEMPLATE-CHECKLIST.md" ] && [ -f "$BT/BUG-TEMPLATE-ISSUE.md" ] || { echo "FAIL setup: the installed copy has no templates where expected"; exit 1; }
# a perl that fails on one named template, so creation fails part-way, after its number is reserved
mkdir -p "$EVAL_TMP/shim"; real="$(command -v perl)"
printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in *"$FAIL_ON") exit 9;; esac; done\nexec "%s" "$@"\n' "$real" > "$EVAL_TMP/shim/perl"; chmod +x "$EVAL_TMP/shim/perl"
failing() { FAIL_ON="$1" PATH="$EVAL_TMP/shim:$PATH" "${@:2}"; }
# a python3 that fails while the routing is written into the first document (wo: DOC is set; bug: the issue file is named)
realpy="$(command -v python3)"; mkdir -p "$EVAL_TMP/pyshim"   # its own folder: the perl shim fails on everything when FAIL_ON is empty
printf '#!/usr/bin/env bash\n[ -n "${FAIL_PY:-}" ] && { [ -n "${DOC:-}" ] || case "$*" in *-routed-bug.md*) true;; *) false;; esac; } && exit 9\nexec "%s" "$@"\n' "$realpy" > "$EVAL_TMP/pyshim/python3"; chmod +x "$EVAL_TMP/pyshim/python3"
wo_num() { $W new "$1" --size "${2:-small}" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1 | sed 's/WO-//'; }
# H1: wo new failing part-way (a template cannot be filled) leaves no folder, and the next order takes that number
a="$(wo_num "before")"; [ -n "$a" ] || { echo "FAIL setup: wo new failed"; exit 1; }
failing WO-TEMPLATE-CHECKLIST.md $W new "half made" --size standard >/dev/null 2>&1 && { echo "FAIL setup: wo new did not fail when a template could not be filled"; exit 1; }
if ls -d "$WD"/WO-*-half-made >/dev/null 2>&1; then echo "FAIL H1: wo new left a half-made folder when it failed"; exit 1; fi
b="$(wo_num "after")"; [ "$((10#$b))" -eq "$((10#$a + 1))" ] || { echo "FAIL H1: the failed wo new kept its number (WO-$a, then WO-$b)"; exit 1; }
# H2: wo adopt failing part-way (the record cannot be read) leaves no folder, and the number can be adopted again
printf '# old record\n' > "$EVAL_TMP/rec.md"; chmod 000 "$EVAL_TMP/rec.md"
$W adopt "$EVAL_TMP/rec.md" --number 700 --title "kept" >/dev/null 2>&1 && { echo "FAIL setup: wo adopt read an unreadable record"; exit 1; }
chmod 644 "$EVAL_TMP/rec.md"
! ls -d "$WD"/WO-0700-* >/dev/null 2>&1 || { echo "FAIL H2: wo adopt left a half-made folder when it failed"; exit 1; }
$W adopt "$EVAL_TMP/rec.md" --number 700 --title "kept" >/dev/null 2>&1 && ls -d "$WD"/WO-0700-kept >/dev/null 2>&1 || { echo "FAIL H2: the number of a failed wo adopt could not be adopted again"; exit 1; }
# H3: bug new failing part-way leaves no folder, and the next bug takes that number
c="$($B new "first" 2>/dev/null | grep -o 'BUG-[0-9][0-9]*' | head -1 | sed 's/BUG-//')"; [ -n "$c" ] || { echo "FAIL setup: bug new failed"; exit 1; }
failing BUG-TEMPLATE-ISSUE.md $B new "half bug" >/dev/null 2>&1 && { echo "FAIL setup: bug new did not fail when a template could not be filled"; exit 1; }
! ls -d "$BD"/BUG-*-half-bug >/dev/null 2>&1 || { echo "FAIL H3: bug new left a half-made folder when it failed"; exit 1; }
d="$($B new "second" 2>/dev/null | grep -o 'BUG-[0-9][0-9]*' | head -1 | sed 's/BUG-//')"
[ "$((10#$d))" -eq "$((10#$c + 1))" ] || { echo "FAIL H3: the failed bug new kept its number (BUG-$c, then BUG-$d)"; exit 1; }
# H4: bug adopt failing part-way leaves no folder
chmod 000 "$EVAL_TMP/rec.md"
$B adopt "$EVAL_TMP/rec.md" --number 700 --category database --title "kept bug" >/dev/null 2>&1 && { echo "FAIL setup: bug adopt read an unreadable record"; exit 1; }
chmod 644 "$EVAL_TMP/rec.md"
! ls -d "$BD"/BUG-0700-* >/dev/null 2>&1 || { echo "FAIL H4: bug adopt left a half-made folder when it failed"; exit 1; }
# H5: ordinary creation keeps its folder, with every document, in both drivers
e="$(wo_num "whole" standard)"; f="$(ls -d "$WD"/WO-"$e"-whole 2>/dev/null)"
[ -n "$f" ] && [ -f "$f/WO-$e-CHECKLIST.md" ] && [ -f "$f/WO-$e-Prompt.md" ] && [ -f "$f/.wo-meta" ] || { echo "FAIL H5: an ordinary wo new did not keep its folder whole"; exit 1; }
$B adopt "$EVAL_TMP/rec.md" --number 701 --category database --title "kept bug" >/dev/null 2>&1 && [ -f "$(ls -d "$BD"/BUG-0701-* 2>/dev/null | head -1)/.bug-meta" ] \
  || { echo "FAIL H5: an ordinary bug adopt did not keep its folder"; exit 1; }
# H6: a failure while the routing is written (--area, --category) leaves no folder either
FAIL_PY=1 PATH="$EVAL_TMP/pyshim:$PATH" $W new "routed half" --size small --area backend >/dev/null 2>&1 && { echo "FAIL setup: wo new --area did not fail in the routing step"; exit 1; }
! ls -d "$WD"/WO-*-routed-half >/dev/null 2>&1 || { echo "FAIL H6: wo new left a half-made folder when the routing step failed"; exit 1; }
FAIL_PY=1 PATH="$EVAL_TMP/pyshim:$PATH" $B new "routed bug" --category database >/dev/null 2>&1 && { echo "FAIL setup: bug new --category did not fail in the routing step"; exit 1; }
! ls -d "$BD"/BUG-*-routed-bug >/dev/null 2>&1 || { echo "FAIL H6: bug new left a half-made folder when the routing step failed"; exit 1; }
exit 0
