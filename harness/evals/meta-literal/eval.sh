#!/usr/bin/env bash
# meta-literal: wo's meta_set writes a value as data: a block reason can neither run as code nor be mangled.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo
n="$($W new "meta check" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"; n="${n#WO-}"
[ -n "$n" ] || { echo "FAIL setup: wo new opened nothing"; exit 1; }
# wo start refuses an order whose documents are not committed (its branch would not hold them)
{ git add -A Workspace/Docs/WorkOrders && git -c user.name=t -c user.email=t@example.com commit -qm "WO-$n open"; } >/dev/null 2>&1 \
  || { echo "FAIL setup: could not commit the order's documents"; exit 1; }
$W start "$n" >/dev/null 2>&1 || { echo "FAIL setup: wo start failed"; exit 1; }
meta="$(ls Workspace/Docs/WorkOrders/WO-"$n"-*/.wo-meta | head -1)"

# M1: a reason that is perl code is written as text and never runs
$W block "$n" '@{[ system("touch PWNED") ]}' >/dev/null 2>&1
[ ! -e PWNED ] || { echo "FAIL M1: a block reason ran as code"; exit 1; }
grep -qxF 'blocked_reason=@{[ system("touch PWNED") ]}' "$meta" || { echo "FAIL M1: the block reason was not written as typed"; exit 1; }

# M2: reasons holding / $ \ & are written as typed, and the key is replaced, not added again
for r in 'a/b' 'cost $HOME & \1' 'back\slash'; do
  $W block "$n" "$r" >/dev/null 2>&1
  grep -qxF "blocked_reason=$r" "$meta" || { echo "FAIL M2: the block reason [$r] was not written as typed"; exit 1; }
  [ "$(grep -c '^blocked_reason=' "$meta")" = 1 ] || { echo "FAIL M2: blocked_reason appears more than once"; exit 1; }
done
# M3: the status set in the same command is still replaced
grep -qx 'status=blocked' "$meta" || { echo "FAIL M3: status was not set to blocked"; exit 1; }
# M4: a PERL_UNICODE setting in the user's environment does not re-encode the reason
r='café 日本'
PERL_UNICODE=SDA $W block "$n" "$r" >/dev/null 2>&1
grep -qxF "blocked_reason=$r" "$meta" || { echo "FAIL M4: PERL_UNICODE in the environment changed the block reason"; exit 1; }
exit 0
