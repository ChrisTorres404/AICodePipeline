#!/usr/bin/env bash
# decimal-counts: wo verify and bug verify read a suite's passed and failed counts as decimal, so a suite that
# prints "08 passed" is recorded instead of stopping the driver in shell arithmetic.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug; mkdir -p s
printf '#!/usr/bin/env bash\necho "08 passed, 0 failed"\n' > s/pass08.sh
printf '#!/usr/bin/env bash\necho "09 passed, 08 failed"; exit 1\n' > s/fail08.sh
printf '#!/usr/bin/env bash\necho "3 passed, 0 failed"\n' > s/plain.sh
status() { grep '^\*\*Overall status:\*\*' "$1" | tail -1; }
n="$($W new "decimal counts" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"; n="${n#WO-}"
b="$($B new "decimal counts" --category database 2>/dev/null | grep -o 'BUG-[0-9][0-9]*' | head -1)"; b="${b#BUG-}"
{ [ -n "$n" ] && [ -n "$b" ]; } || { echo "FAIL setup: could not open a work order and a bug"; exit 1; }
# V1: wo verify records a suite that printed 08 passed as a PASS, with its counts
out="$($W verify "$n" --run s/pass08.sh 2>&1)"; rc=$?
v="$(ls Workspace/Docs/WorkOrders/WO-"$n"-*/WO-"$n"-VERIFICATION.md | head -1)"
{ [ "$rc" -eq 0 ] && status "$v" | grep -qF "EXECUTED — PASS" && status "$v" | grep -qF "checks 08/8)"; } \
  || { echo "FAIL V1: wo verify did not record a suite that printed 08 passed"; echo "  exit $rc"; exit 1; }
# V2: bug verify does the same
out="$($B verify "$b" --run s/pass08.sh 2>&1)"; rc=$?
bv="$(ls Workspace/Docs/Bugs/BUG-"$b"-*/BUG-"$b"-VERIFICATION.md | head -1)"
{ [ "$rc" -eq 0 ] && status "$bv" | grep -qF "EXECUTED — PASS" && status "$bv" | grep -qF "checks 08/8)"; } \
  || { echo "FAIL V2: bug verify did not record a suite that printed 08 passed"; echo "  exit $rc"; exit 1; }
# V3: a failing suite that printed 08 failed is recorded as a FAIL, with both counts, in each driver
out="$($W verify "$n" --run s/fail08.sh 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && status "$v" | grep -qF "EXECUTED — FAIL" && status "$v" | grep -qF "checks 09/17)"; } \
  || { echo "FAIL V3: wo verify did not record a failing suite that printed 08 failed"; echo "  exit $rc"; exit 1; }
out="$($B verify "$b" --run s/fail08.sh 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && status "$bv" | grep -qF "EXECUTED — FAIL" && status "$bv" | grep -qF "checks 09/17)"; } \
  || { echo "FAIL V3: bug verify did not record a failing suite that printed 08 failed"; echo "  exit $rc"; exit 1; }
# V4: ordinary counts are recorded as before
out="$($W verify "$n" --run s/plain.sh 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && status "$v" | grep -qF "checks 3/3)"; } || { echo "FAIL V4: wo verify changed how ordinary counts are shown"; echo "  exit $rc"; exit 1; }
out="$($B verify "$b" --run s/plain.sh 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && status "$bv" | grep -qF "checks 3/3)"; } || { echo "FAIL V4: bug verify changed how ordinary counts are shown"; echo "  exit $rc"; exit 1; }
exit 0
