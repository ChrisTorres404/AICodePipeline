#!/usr/bin/env bash
# list-ratio: wo list takes the checks ratio only from the status line's own ", checks P/T)" ending.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo
run() { # <title> <suite path> <suite body>: open an order, verify it with that suite, print its number
  local n; n="$($W new "$1" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"; n="${n#WO-}"
  mkdir -p "$(dirname "$2")"; printf '#!/usr/bin/env bash\n%s\n' "$3" > "$2"
  $W verify "$n" --run "$2" >/dev/null 2>&1; echo "$n"; }
# the evidence column of wo list (printf "%-8s %-6s %-12s %-8s %-14s %s"): characters 39 to 52, trimmed
listed() { $W list 2>/dev/null | grep -E "^WO-$1 " | head -1 | cut -c39-52 | sed 's/ *$//'; }
# L1: a failing run whose suite path holds "checks 9/9" shows the run's own 0/3
a="$(run "path ratio" "s/checks 9/9.sh" 'echo "0 passed, 3 failed"; exit 1')"
[ "$(listed "$a")" = "FAIL 0/3" ] || { echo "FAIL L1: wo list showed the ratio from the suite path, not the run's ($(listed "$a"))"; exit 1; }
# L2: a path that copies the whole ending, ", checks 9/9)", still shows the run's own ratio
b="$(run "ending ratio" "s/x, checks 9/9).sh" 'echo "0 passed, 3 failed"; exit 1')"
[ "$(listed "$b")" = "FAIL 0/3" ] || { echo "FAIL L2: wo list showed a ratio copied into the suite path ($(listed "$b"))"; exit 1; }
# L3: a run that printed no counts shows no ratio, even with "checks 5/5" in its path
c="$(run "no counts" "s/checks 5/5.sh" 'exit 0')"
[ "$(listed "$c")" = "PASS" ] || { echo "FAIL L3: wo list showed a ratio for a run that printed none ($(listed "$c"))"; exit 1; }
# L4: an ordinary run still shows its ratio
d="$(run "ordinary" "s/ok.sh" 'echo "3 passed, 0 failed"')"
[ "$(listed "$d")" = "PASS 3/3" ] || { echo "FAIL L4: wo list no longer shows an ordinary run's ratio ($(listed "$d"))"; exit 1; }
# L5: a run that printed no counts, under a path that copies the ending with text after it, shows no ratio
e="$(run "copied ending" "s/x, checks 7/7).sh" 'exit 0')"
[ "$(listed "$e")" = "PASS" ] || { echo "FAIL L5: wo list showed a ratio taken from the suite path ($(listed "$e"))"; exit 1; }
# L6: a "checks N/M" note above the status line is not the ratio
v="$(ls -d Workspace/Docs/WorkOrders/WO-"$d"-*/WO-"$d"-VERIFICATION.md | head -1)"
{ printf 'Earlier note: checks 8/8 were planned.\n'; cat "$v"; } > "$v.new" && mv "$v.new" "$v"
[ "$(listed "$d")" = "PASS 3/3" ] || { echo "FAIL L6: wo list took a ratio from a note above the status line ($(listed "$d"))"; exit 1; }
# L7: a VERIFICATION file with CRLF line endings still shows its ratio
perl -pi -e 's/\n/\r\n/' "$v"
[ "$(listed "$d")" = "PASS 3/3" ] || { echo "FAIL L7: wo list lost the ratio of a file with CRLF line endings ($(listed "$d"))"; exit 1; }
exit 0
