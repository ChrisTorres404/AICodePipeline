#!/usr/bin/env bash
# close-checker: wo close and bug close refuse when check.py is missing, refuse a blocking (2) or unfinished
# check in both drivers, and bug close says when the close-time checks were not run.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug; CK=.aicodepipeline/core/hooks/check.py
printf '#!/usr/bin/env bash\necho "1 passed, 0 failed"\n' > "$EVAL_TMP/ok.sh"
ready_wo() { local n; n="$($W new "$1" --size small 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"; n="${n#WO-}"; [ -n "$n" ] || return 1; $W verify "$n" --run "$EVAL_TMP/ok.sh" >/dev/null 2>&1; echo "$n"; }
ready_bug() { local n; n="$($B new "$1" --category database 2>/dev/null | grep -o 'BUG-[0-9][0-9]*' | head -1)"; n="${n#BUG-}"; [ -n "$n" ] || return 1; $B verify "$n" --run "$EVAL_TMP/ok.sh" >/dev/null 2>&1; echo "$n"; }
closed() { ls "$1"-*/"$(basename "$1")"-*CLOSEOUT.md >/dev/null 2>&1; }
cp "$CK" "$EVAL_TMP/check.bak" || { echo "FAIL setup: no check.py in the installed copy"; exit 1; }
# M1: check.py missing: wo close refuses, saying so, and writes no closeout
rm "$CK"; n="$(ready_wo "no checker")" || { echo "FAIL setup: could not make a verified order"; exit 1; }
out="$(ALLOW_PLACEHOLDERS=1 $W close "$n" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! closed "Workspace/Docs/WorkOrders/WO-$n"; } || { echo "FAIL M1: wo close closed although check.py is missing"; exit 1; }
printf '%s\n' "$out" | grep -qF "the close-time checks are missing" || { echo "FAIL M1: wo close refused without saying check.py is missing: $out"; exit 1; }
# M2: the same in bug close
b="$(ready_bug "no checker")" || { echo "FAIL setup: could not make a verified bug"; exit 1; }
out="$(ALLOW_PLACEHOLDERS=1 $B close "$b" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! closed "Workspace/Docs/Bugs/BUG-$b"; } || { echo "FAIL M2: bug close closed although check.py is missing"; exit 1; }
printf '%s\n' "$out" | grep -qF "the close-time checks are missing" && printf '%s\n' "$out" | grep -qF "check.py not found" || { echo "FAIL M2: bug close refused without saying check.py is missing: $out"; exit 1; }
# M3: ACP_SKIP_CHECK=1 still closes both, check.py missing or not
ACP_SKIP_CHECK=1 ALLOW_PLACEHOLDERS=1 $W close "$n" >/dev/null 2>&1 && closed "Workspace/Docs/WorkOrders/WO-$n" \
  && ACP_SKIP_CHECK=1 ALLOW_PLACEHOLDERS=1 $B close "$b" >/dev/null 2>&1 && closed "Workspace/Docs/Bugs/BUG-$b" \
  || { echo "FAIL M3: ACP_SKIP_CHECK=1 no longer closes when check.py is missing"; exit 1; }
# M4: a check that blocks (exit 2) is refused in both drivers, naming the block
printf 'import sys\nsys.exit(2)\n' > "$CK"
n="$(ready_wo "blocked")"; out="$(ALLOW_PLACEHOLDERS=1 $W close "$n" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! closed "Workspace/Docs/WorkOrders/WO-$n" && printf '%s\n' "$out" | grep -qF "the checks above block"; } || { echo "FAIL M4: wo close did not refuse a blocking check (exit 2): $out"; exit 1; }
b="$(ready_bug "blocked")"; out="$(ALLOW_PLACEHOLDERS=1 $B close "$b" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! closed "Workspace/Docs/Bugs/BUG-$b" && printf '%s\n' "$out" | grep -qF "the checks above block"; } || { echo "FAIL M4: bug close did not refuse a blocking check (exit 2): $out"; exit 1; }
# M5: in bug close, python3 not found (127) and any other exit (5) are refused, each named
cp "$EVAL_TMP/check.bak" "$CK"; mkdir -p "$EVAL_TMP/shim"; real="$(command -v python3)"
printf '#!/usr/bin/env bash\ncase "$1" in *check.py) exit 127;; esac\nexec "%s" "$@"\n' "$real" > "$EVAL_TMP/shim/python3"; chmod +x "$EVAL_TMP/shim/python3"
b="$(ready_bug "no python")"; out="$(PATH="$EVAL_TMP/shim:$PATH" ALLOW_PLACEHOLDERS=1 $B close "$b" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! closed "Workspace/Docs/Bugs/BUG-$b" && printf '%s\n' "$out" | grep -qF "(exit 127: python3 not found)"; } || { echo "FAIL M5: bug close did not refuse exit 127: $out"; exit 1; }
printf 'import sys\nsys.exit(5)\n' > "$CK"
b="$(ready_bug "exit five")"; out="$(ALLOW_PLACEHOLDERS=1 $B close "$b" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! closed "Workspace/Docs/Bugs/BUG-$b" && printf '%s\n' "$out" | grep -qF "did not finish (check.py exit 5)"; } || { echo "FAIL M5: bug close did not refuse exit 5: $out"; exit 1; }
cp "$EVAL_TMP/check.bak" "$CK"
# M6: in a project with no git, a bug with no manifest closes, and says the close-time checks were not run
cd "$EVAL_TMP" && "$PIPELINE_ROOT/bin/new-project" q --name Q --no-git >/dev/null 2>&1 && cd q || { echo "FAIL setup: new-project q failed"; exit 1; }
b="$(ready_bug "no git")" || { echo "FAIL setup: could not make a verified bug"; exit 1; }
rm -f Workspace/Docs/Bugs/BUG-"$b"-*/.bug-manifest
out="$(ALLOW_PLACEHOLDERS=1 $B close "$b" 2>&1 >/dev/null)"; rc=$?   # the warning is on stderr
{ [ "$rc" -eq 0 ] && closed "Workspace/Docs/Bugs/BUG-$b" && printf '%s\n' "$out" | grep -qF "the close-time checks were not run"; } \
  || { echo "FAIL M6: bug close with no git and no manifest did not say the checks were not run (exit $rc): $out"; exit 1; }
# M7: the plugin layout (check.py under hooks/scripts/, no core/) closes with its checks run, and
# refuses when the plugin's check.py is missing
C="$EVAL_TMP/copy"; mkdir -p "$C" && (cd "$PIPELINE_ROOT" && tar -cf - --exclude ./harness/evals/results --exclude ./.git --exclude ./dist .) | (cd "$C" && tar -xf -) \
  && bash "$C/bin/build-plugin" >/dev/null 2>&1 && [ -f "$C/dist/plugin/hooks/scripts/check.py" ] || { echo "FAIL setup: could not build the plugin"; exit 1; }
cd "$EVAL_TMP" && "$PIPELINE_ROOT/bin/new-project" r --name R --no-git >/dev/null 2>&1 && cd r && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: new-project r failed"; exit 1; }
W="$C/dist/plugin/bin/wo"
n="$(ready_wo "plugin close")" || { echo "FAIL setup: could not make a verified order with the plugin"; exit 1; }
out="$(ALLOW_PLACEHOLDERS=1 $W close "$n" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && closed "Workspace/Docs/WorkOrders/WO-$n"; } || { echo "FAIL M7: the plugin layout could not close a verified order (exit $rc): $out"; exit 1; }
B="$C/dist/plugin/bin/bug"; b="$(ready_bug "plugin close")" || { echo "FAIL setup: could not make a verified bug with the plugin"; exit 1; }
out="$(ALLOW_PLACEHOLDERS=1 $B close "$b" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && closed "Workspace/Docs/Bugs/BUG-$b"; } || { echo "FAIL M7: the plugin layout could not close a verified bug (exit $rc): $out"; exit 1; }
rm "$C/dist/plugin/hooks/scripts/check.py"; n="$(ready_wo "plugin no checker")"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$n" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! closed "Workspace/Docs/WorkOrders/WO-$n" && printf '%s\n' "$out" | grep -qF "the close-time checks are missing"; } \
  || { echo "FAIL M7: the plugin layout closed with its check.py missing (exit $rc): $out"; exit 1; }
exit 0
