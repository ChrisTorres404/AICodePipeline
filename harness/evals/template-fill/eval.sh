#!/usr/bin/env bash
# template-fill: wo integrate and wo suite fill their templates with values as data, and refuse a value that
# would end the generated script's quotes or run code there.
set -uo pipefail
cd "$EVAL_TMP" || exit 1; EVAL_TMP="$(pwd -P)"   # mktemp on macOS gives /var/..., a link; wo writes the physical path
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; SD=Workspace/Testing/suites
num() { $W new "$1" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1 | sed 's/WO-//'; }
# F1: a covered suite whose file name holds code is refused, and nothing is written
a="$(num "alpha")"; mkdir -p "$SD"; printf '#!/usr/bin/env bash\nexit 0\n' > "$SD/wo-$a-x\$(id>PWNED).sh"
before="$(ls "$SD" | grep -c . || true)"
out="$($W integrate "join" --covers "$a" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] || [ "$(ls "$SD" | grep -c . || true)" != "$before" ] || ls -d Workspace/Docs/WorkOrders/WO-*-join >/dev/null 2>&1 || grep -rqF 'x$(id>PWNED)' "$SD"/wo-*-join*.sh 2>/dev/null; then
  echo "FAIL F1: wo integrate wrote a covered suite's name that runs code into the integration suite"; exit 1; fi
printf '%s\n' "$out" | grep -qF "is not a plain file name" || { echo "FAIL F1: wo integrate refused without saying why"; exit 1; }
rm -f "$SD/wo-$a-x\$(id>PWNED).sh"
# F2: an ordinary integration fills every placeholder with its value, as data
$W suite "$a" >/dev/null 2>&1 || { echo "FAIL setup: wo suite failed"; exit 1; }
b="$(num "beta")"; $W suite "$b" >/dev/null 2>&1
$W integrate "join" --covers "$a,$b" >/dev/null 2>&1 || { echo "FAIL F2: an ordinary wo integrate failed"; exit 1; }
f="$(ls "$SD"/wo-*-join.sh | head -1)"
grep -qxF "COVERED_SUITES=\"wo-$a-alpha.sh wo-$b-beta.sh\"" "$f" && grep -qxF 'HARNESS="$ROOT/.aicodepipeline/harness"' "$f" \
  && grep -qF 'f="$ROOT/Workspace/Testing/suites/$s"' "$f" && grep -qF ': join — integration suite.' "$f" && ! grep -qF -e '{{' -e 'WO-XXXX' "$f" || { echo "FAIL F2: an ordinary integration suite was not filled as expected"; exit 1; }
# F3: run from a pipeline whose path holds & and |, wo suite writes that path as it is
src="$EVAL_TMP/R&D|x/acp"; mkdir -p "$src" && (cd "$PIPELINE_ROOT" && tar -cf - --exclude ./harness/evals/results --exclude ./.git .) | (cd "$src" && tar -xf -) \
  || { echo "FAIL setup: could not copy the pipeline"; exit 1; }
c="$(num "gamma")"
"$src/bin/wo" suite "$c" >/dev/null 2>&1; g="$SD/wo-$c-gamma.sh"
[ "$(grep -m1 '^HARNESS=' "$g" 2>/dev/null)" = "HARNESS=\"\$ROOT/$src/harness\"" ] && grep -qF "# WO-$c: gamma — " "$g" \
  || { echo "FAIL F3: a pipeline path holding & and | was not written as it is: $(grep -m1 '^HARNESS=' "$g" 2>/dev/null)"; exit 1; }
# F5: wo integrate run from that pipeline fills every placeholder too (an installed copy's templates
# come with the paths already filled in by install, so only a run from the source tree shows this)
"$src/bin/wo" integrate "joint" --covers "$a,$b" >/dev/null 2>&1 || { echo "FAIL F5: wo integrate from a pipeline path holding & and | failed"; exit 1; }
j="$(ls "$SD"/wo-*-joint.sh 2>/dev/null | head -1)"
[ -n "$j" ] && [ "$(grep -m1 '^HARNESS=' "$j")" = "HARNESS=\"\$ROOT/$src/harness\"" ] && grep -qF 'f="$ROOT/Workspace/Testing/suites/$s"' "$j" \
  && grep -qxF "COVERED_SUITES=\"wo-$a-alpha.sh wo-$b-beta.sh\"" "$j" && grep -qF ': joint — integration suite.' "$j" && ! grep -qF -e '{{' -e 'WO-XXXX' "$j" \
  || { echo "FAIL F5: wo integrate from the source tree did not fill its placeholders as data"; exit 1; }
# F4: run from a pipeline whose path holds $, wo suite refuses and writes nothing
src2="$EVAL_TMP/a\$b/acp"; mkdir -p "$src2" && (cd "$src" && tar -cf - .) | (cd "$src2" && tar -xf -) || { echo "FAIL setup: could not copy the pipeline"; exit 1; }
d="$(num "delta")"
out="$("$src2/bin/wo" suite "$d" 2>&1)" && { echo "FAIL F4: wo suite accepted a pipeline path holding \$"; exit 1; }
[ ! -e "$SD/wo-$d-delta.sh" ] || { echo "FAIL F4: a refused wo suite left a suite behind"; exit 1; }
printf '%s\n' "$out" | grep -qF 'holds a quote, $, backtick, backslash or newline' || { echo "FAIL F4: wo suite refused without saying why: $out"; exit 1; }
# F6: wo integrate from a pipeline whose path holds $ refuses too, and writes no integration suite
out="$("$src2/bin/wo" integrate "dollar" --covers "$a,$b" 2>&1)" && { echo "FAIL F6: wo integrate accepted a pipeline path holding \$"; exit 1; }
! ls "$SD"/wo-*-dollar.sh >/dev/null 2>&1 || { echo "FAIL F6: a refused wo integrate left a suite behind"; exit 1; }
! ls -d Workspace/Docs/WorkOrders/WO-*-dollar >/dev/null 2>&1 || { echo "FAIL F6: a refused wo integrate left a work order behind"; exit 1; }
printf '%s\n' "$out" | grep -qF 'holds a quote, $, backtick, backslash or newline' || { echo "FAIL F6: wo integrate refused without saying why: $out"; exit 1; }
[ ! -e PWNED ] || { echo "FAIL: a value ran as code"; exit 1; }
exit 0
