#!/usr/bin/env bash
# verify-literal: wo verify and bug verify write the suite path and the project root as data.
set -uo pipefail
R="$EVAL_TMP/a|b@c"; mkdir -p "$R"; cd "$R" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug
mkdir -p s; name='s/x|;system("touch PWNED");#'
printf '#!/usr/bin/env bash\necho "file: $(pwd -P)/a.py"\necho "1 passed, 0 failed"\n' > "$name"
n="$($W new "verify check" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"
$W verify "${n#WO-}" --run "$name" >/dev/null 2>&1
# V1: a suite path that is perl code is written as text and never runs (wo verify)
[ ! -e PWNED ] || { echo "FAIL V1: a suite path ran as code in wo verify"; exit 1; }
v="$(ls Workspace/Docs/WorkOrders/"$n"-*/"$n"-VERIFICATION.md | head -1)"
grep -q "^\*\*Overall status:\*\* EXECUTED — PASS (last run .*, suite s/x|;system(\"touch PWNED\");#@[0-9a-f]*, checks 1/1)$" "$v" \
  || { echo "FAIL V1: the status line does not carry the suite path as typed"; exit 1; }
# V2: the same in bug verify
b="$($B new "verify check" --category database 2>/dev/null | grep -o 'BUG-[0-9][0-9]*' | head -1)"
$B verify "${b#BUG-}" --run "$name" >/dev/null 2>&1
[ ! -e PWNED ] || { echo "FAIL V2: a suite path ran as code in bug verify"; exit 1; }
bv="$(ls Workspace/Docs/Bugs/"$b"-*/"$b"-VERIFICATION.md | head -1)"
grep -q "^\*\*Overall status:\*\* EXECUTED — PASS (last run .*, suite s/x|;system(\"touch PWNED\");#@[0-9a-f]*, checks 1/1)$" "$bv" \
  || { echo "FAIL V2: the bug status line does not carry the suite path as typed"; exit 1; }
# V3: the project root is removed from the log intact, even when it holds | and @
l="$(ls Workspace/Docs/WorkOrders/"$n"-*/"$n"-VERIFICATION-*.log | head -1)"
grep -qx 'file: a.py' "$l" || { echo "FAIL V3: the path scrub damaged the log line: $(head -1 "$l")"; exit 1; }
# V4: every value in cmd_verify goes to perl as data with -C0, the RUNNING lines included (C213a-2)
for d in wo bug; do
  f="$PIPELINE_ROOT/bin/$d"; want=3   # bug verify scrubs its log as wo verify does
  [ "$(grep -c "perl -pi -e \"s|" "$f")" -eq 0 ] || { echo "FAIL V4: bin/$d still splices a value into a perl program"; exit 1; }
  [ "$(grep -c "^ *ACP_V_[A-Z]*=.* perl -C0 -pi -e '" "$f")" -eq "$want" ] || { echo "FAIL V4: bin/$d does not pass all $want verify values as data with -C0"; exit 1; }
done
# V5: with PERL_UNICODE set, a non-ASCII suite path and project root are still written and scrubbed as typed (C213a-1)
U="$EVAL_TMP/é"; mkdir -p "$U"; cd "$U" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: second new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the second scratch project's first commit"; exit 1; }
mkdir -p s; printf '#!/usr/bin/env bash\necho "file: $(pwd -P)/a.py"\necho "1 passed, 0 failed"\n' > s/é.sh
n="$($W new "unicode check" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"
PERL_UNICODE=SD $W verify "${n#WO-}" --run s/é.sh >/dev/null 2>&1
v="$(ls Workspace/Docs/WorkOrders/"$n"-*/"$n"-VERIFICATION.md | head -1)"
grep -q "^\*\*Overall status:\*\* EXECUTED — PASS (last run .*, suite s/é.sh@[0-9a-f]*, checks 1/1)$" "$v" \
  || { echo "FAIL V5: with PERL_UNICODE set, the wo status line is not written as typed"; exit 1; }
l="$(ls Workspace/Docs/WorkOrders/"$n"-*/"$n"-VERIFICATION-*.log | head -1)"
grep -qx 'file: a.py' "$l" || { echo "FAIL V5: with PERL_UNICODE set, the project root was not scrubbed from the log"; exit 1; }
b="$($B new "unicode check" --category database 2>/dev/null | grep -o 'BUG-[0-9][0-9]*' | head -1)"
PERL_UNICODE=SD $B verify "${b#BUG-}" --run s/é.sh >/dev/null 2>&1
bv="$(ls Workspace/Docs/Bugs/"$b"-*/"$b"-VERIFICATION.md | head -1)"
grep -q "^\*\*Overall status:\*\* EXECUTED — PASS (last run .*, suite s/é.sh@[0-9a-f]*, checks 1/1)$" "$bv" \
  || { echo "FAIL V5: with PERL_UNICODE set, the bug status line is not written as typed"; exit 1; }
exit 0
