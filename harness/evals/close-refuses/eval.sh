#!/usr/bin/env bash
# close-refuses: wo close and bug close refuse unless the close-time checks ran to the end (exit 0, or 2 for a block).
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug; HOOKS=.aicodepipeline/core/hooks
printf '#!/usr/bin/env bash\necho "1 passed, 0 failed"\n' > "$EVAL_TMP/ok.sh"
ready_wo() { local n; n="$($W new "$1" --size small 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"; n="${n#WO-}"; [ -n "$n" ] || return 1; $W verify "$n" --run "$EVAL_TMP/ok.sh" >/dev/null 2>&1; echo "$n"; }
ready_bug() { local n; n="$($B new "$1" --category database 2>/dev/null | grep -o 'BUG-[0-9][0-9]*' | head -1)"; n="${n#BUG-}"; [ -n "$n" ] || return 1; $B verify "$n" --run "$EVAL_TMP/ok.sh" >/dev/null 2>&1; echo "$n"; }
closed() { ls "$1"-*/"$(basename "$1")"-*CLOSEOUT.md >/dev/null 2>&1; }   # <folder prefix> -> 0 when a closeout exists

# C1: a broken hook makes check.py exit 3; wo close must refuse and write no closeout
cp "$HOOKS/quality-gate.py" "$EVAL_TMP/qg.bak"; printf '\ndef (:\n' >> "$HOOKS/quality-gate.py"
n="$(ready_wo "broken hook")" || { echo "FAIL setup: could not make a verified order"; exit 1; }
out="$(ALLOW_PLACEHOLDERS=1 $W close "$n" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! closed "Workspace/Docs/WorkOrders/WO-$n"; } || { echo "FAIL C1: wo close closed although check.py broke (exit 3)"; exit 1; }
printf '%s\n' "$out" | grep -qF "broke part-way (check.py exit 3)" || { echo "FAIL C1: wo close refused without naming exit 3"; exit 1; }
# C2: the same in bug close
b="$(ready_bug "broken hook")" || { echo "FAIL setup: could not make a verified bug"; exit 1; }
out="$(ALLOW_PLACEHOLDERS=1 $B close "$b" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! closed "Workspace/Docs/Bugs/BUG-$b"; } || { echo "FAIL C2: bug close closed although check.py broke (exit 3)"; exit 1; }
printf '%s\n' "$out" | grep -qF "broke part-way (check.py exit 3)" || { echo "FAIL C2: bug close refused without naming exit 3"; exit 1; }
cp "$EVAL_TMP/qg.bak" "$HOOKS/quality-gate.py"

# C3: python3 cannot be found (127): wo close must refuse
mkdir -p "$EVAL_TMP/shim"; real="$(command -v python3)"
printf '#!/usr/bin/env bash\ncase "$1" in *check.py) exit 127;; esac\nexec "%s" "$@"\n' "$real" > "$EVAL_TMP/shim/python3"; chmod +x "$EVAL_TMP/shim/python3"
n="$(ready_wo "no python")" || { echo "FAIL setup: could not make a verified order"; exit 1; }
out="$(PATH="$EVAL_TMP/shim:$PATH" ALLOW_PLACEHOLDERS=1 $W close "$n" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! closed "Workspace/Docs/WorkOrders/WO-$n"; } || { echo "FAIL C3: wo close closed although the checks could not start (exit 127)"; exit 1; }
printf '%s\n' "$out" | grep -qF "(exit 127: python3 not found)" || { echo "FAIL C3: wo close refused without naming exit 127"; exit 1; }

# C5: check.py itself does not compile (python exits 1): wo close must refuse, naming the exit code
cp "$HOOKS/check.py" "$EVAL_TMP/check.bak"; printf '\ndef (:\n' >> "$HOOKS/check.py"
n="$(ready_wo "broken checker")" || { echo "FAIL setup: could not make a verified order"; exit 1; }
out="$(ALLOW_PLACEHOLDERS=1 $W close "$n" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! closed "Workspace/Docs/WorkOrders/WO-$n"; } || { echo "FAIL C5: wo close closed although check.py could not run (exit 1)"; exit 1; }
printf '%s\n' "$out" | grep -qF "did not finish (check.py exit 1)" || { echo "FAIL C5: wo close refused without naming exit 1"; exit 1; }
cp "$EVAL_TMP/check.bak" "$HOOKS/check.py"

# C4: nothing broken: the close goes through as before
n="$(ready_wo "clean")" || { echo "FAIL setup: could not make a verified order"; exit 1; }
ALLOW_PLACEHOLDERS=1 $W close "$n" >/dev/null 2>&1 && closed "Workspace/Docs/WorkOrders/WO-$n" || { echo "FAIL C4: a clean close no longer goes through"; exit 1; }
exit 0
