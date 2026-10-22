#!/usr/bin/env bash
# integrate-errexit: wo integrate keeps errexit while wo new makes its order, so a failure part-way through stops
# it, says nothing was created, and leaves no half-made folder (release review G7-2).
set -uo pipefail
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1; cd p || die "new-project failed"
W=./.aicodepipeline/bin/wo; WD=Workspace/Docs/WorkOrders
n="$($W new "Covered" --size small --area docs | grep -o 'WO-[0-9]*' | head -1)"; n="${n#WO-}"
[ -n "$n" ] || die "wo new opened no work order"
$W suite "$n" >/dev/null 2>&1 || die "wo suite failed"
# a python3 that fails only when it reads its program from stdin: one step inside wo new then fails
real="$(command -v python3)"; mkdir -p "$EVAL_TMP/shim"
printf '#!/bin/bash\nif [ "${1:-}" = "-" ]; then echo "shim: python failed" >&2; exit 1; fi\nexec "%s" "$@"\n' "$real" > "$EVAL_TMP/shim/python3"
chmod +x "$EVAL_TMP/shim/python3"
# G0: the shim does make a plain wo new fail, so the failure is real
rc=0; PATH="$EVAL_TMP/shim:$PATH" $W new "Direct" --size standard --area integration >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || die "the shim did not make wo new fail; the eval cannot test wo integrate"
ls -d "$WD"/WO-*-direct >/dev/null 2>&1 && die "wo new left a half-made folder (wo new's own cleanup is broken, not wo integrate)"
rc=0; out="$(PATH="$EVAL_TMP/shim:$PATH" $W integrate "Batch int" --covers "$n" 2>&1)" || rc=$?
ls -d "$WD"/WO-*-batch-int >/dev/null 2>&1 && die "FAIL G1: wo integrate left a half-made order when wo new failed part-way" "$out"
[ "$rc" -ne 0 ] || die "FAIL G2: wo integrate exited 0 when wo new failed part-way" "$out"
printf '%s\n' "$out" | grep -q '^WO-[0-9]* created' && die "FAIL G3: wo integrate said an order was created when wo new failed part-way" "$out"
# G4: without the failure, integrate still works
out="$($W integrate "Batch ok" --covers "$n" 2>&1)" || die "FAIL G4: wo integrate failed without any fault" "$out"
ls -d "$WD"/WO-*-batch-ok >/dev/null 2>&1 || die "FAIL G4: wo integrate made no order" "$out"
echo "integrate-errexit: all checks passed"
exit 0
