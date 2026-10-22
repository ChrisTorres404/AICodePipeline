#!/usr/bin/env bash
# CODE_DIR names the product's code. The tree fingerprint covers it (a change elsewhere does not stale
# the evidence), the default "." is today's fingerprint, wo verify and bug verify record the commit the source
# was at, and a CODE_DIR that is not a folder of code inside the project is refused.
set -uo pipefail
. "$(dirname "$0")/../_lib/verification.sh"
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p || exit 1
# CODE_DIR comes from the environment in this evaluation, so the config must not set it
grep -v '^export CODE_DIR=' pipeline.config.sh > ../cfg && mv ../cfg pipeline.config.sh
# src/main.py makes the project count as having source code, so intake step 3 measures it (E12, E13)
mkdir -p src; echo v1 > src/app.txt; echo 'print(1)' > src/main.py; echo readme > README.md; printf '#!/usr/bin/env bash\nexit 0\n' > ok.sh
G() { git -c user.name=t -c user.email=t@example.com "$@"; }
git init -q && git add -A && G commit -qm base >/dev/null 2>&1 || { echo "FAIL setup: could not make the first commit"; exit 1; }
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug; A=.aicodepipeline/bin/acp
fp() { CODE_DIR="${1-}" "$W" fingerprint "${2-}"; }
newwo() { "$W" new "$1" --size small --area backend | grep -o 'WO-[0-9]*' | head -1 | cut -c4-; }
rec() { ls "$1"/Workspace/Docs/WorkOrders/WO-"$2"-*/WO-"$2"-VERIFICATION.md 2>/dev/null | head -1; }
refused() { # <code dir> <message part> <command...>: the command fails and says why
  local cd="$1" msg="$2" out; shift 2
  out="$(CODE_DIR="$cd" "$@" 2>&1)" && return 1
  printf '%s\n' "$out" | grep -qF -- "$msg"
}
# E1: the default is today's fingerprint: CODE_DIR unset, "." and "./" give the same value
a="$(fp '')"; b="$(fp .)"; c="$(fp ./)"
{ [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" = "$c" ]; } || { echo "FAIL E1: the default CODE_DIR changed the tree fingerprint"; echo "  $a $b $c"; exit 1; }
# E2: with CODE_DIR=src, a change outside src does not change the fingerprint
s1="$(fp src)"; echo changed > README.md; s2="$(fp src)"; G checkout -q -- README.md
[ "$s1" = "$s2" ] || { echo "FAIL E2: a change outside CODE_DIR changed the tree fingerprint"; exit 1; }
# E3: a change inside src does
echo v2 > src/app.txt; s3="$(fp src)"; G checkout -q -- src/app.txt
[ "$s1" != "$s3" ] || { echo "FAIL E3: a change inside CODE_DIR did not change the tree fingerprint"; exit 1; }
# E4: the code folder is fingerprinted exactly as a declared path (wo new --paths) of the same folder is,
# however it is spelled
[ "$s1" = "$(fp '' src)" ] || { echo "FAIL E4: CODE_DIR=src and the declared path src gave different fingerprints"; exit 1; }
for sp in ./src src/ ./src/ 'src//'; do [ "$(fp "$sp")" = "$s1" ] || { echo "FAIL E4: CODE_DIR=$sp and CODE_DIR=src gave different fingerprints"; exit 1; }; done
# E5: wo verify records the commit and the code folder's fingerprint; the status line keeps its form
head="$(git rev-parse HEAD)"; n="$(newwo Code)"
CODE_DIR=src "$W" verify "$n" --run ./ok.sh >/dev/null 2>&1; v="$(rec . "$n")"
st="$(grep -m1 '^\*\*Overall status:\*\*' "$v")"
{ [ "$(grep -cxF -- "- **Commit:** $head" "$v")" = 1 ] && printf '%s\n' "$st" | grep -qF ", tree $s1, suite ./ok.sh@" \
  && printf '%s\n' "$st" | grep -qE '^\*\*Overall status:\*\* EXECUTED — PASS \(last run [0-9-]+, tree [0-9a-f]{16}, suite \./ok\.sh@[0-9a-f]{16}\)$'; } \
  || { echo "FAIL E5: wo verify did not record the commit and the code folder's fingerprint"; echo "  $st"; exit 1; }
# E5b: the commit is taken before the suite runs: a suite that commits does not change it
printf '#!/usr/bin/env bash\ngit -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m during\n' > Workspace/Testing/suites/commits.sh
h5="$(newwo Commits)"; CODE_DIR=src "$W" verify "$h5" --run Workspace/Testing/suites/commits.sh >/dev/null 2>&1
{ [ "$(git rev-parse HEAD)" != "$head" ] && [ "$(grep -cxF -- "- **Commit:** $head" "$(rec . "$h5")")" = 1 ]; } \
  || { echo "FAIL E5b: the commit recorded was not the one the suite started from"; exit 1; }
head0="$head"; head="$(git rev-parse HEAD)"
# E6: a change inside the code folder that is not committed is noted; one outside it is not
echo v3 > src/app.txt; CODE_DIR=src "$W" verify "$n" --run ./ok.sh >/dev/null 2>&1; G checkout -q -- src/app.txt
echo other > README.md; CODE_DIR=src "$W" verify "$n" --run ./ok.sh >/dev/null 2>&1; G checkout -q -- README.md
{ [ "$(grep -cxF -- "- **Commit:** $head (with uncommitted changes in the source)" "$v")" = 1 ] && [ "$(grep -cxF -- "- **Commit:** $head" "$v")" = 1 ]; } \
  || { echo "FAIL E6: uncommitted changes in the code folder were not noted, or a change outside it was"; exit 1; }
# E7: the close guard reads the code folder: a change outside it does not stale the PASS, a change inside does
echo v4 > src/app.txt
rc=0; CODE_DIR=src "$W" close "$n" >/dev/null 2>&1 || rc=$?; G checkout -q -- src/app.txt
[ "$rc" -ne 0 ] || { echo "FAIL E7: closed although the code folder changed after the PASS"; exit 1; }
CODE_DIR=src "$W" verify "$n" --run ./ok.sh >/dev/null 2>&1; fill_wo "$n"; echo outside > README.md
CODE_DIR=src "$W" close "$n" >/dev/null 2>&1 || { echo "FAIL E7: a change outside the code folder staled the PASS"; exit 1; }
G checkout -q -- README.md
# E8: bug verify records the commit, the code folder's fingerprint and the uncommitted-change note the same
# way, and refuses a missing code folder
bn="$("$B" new "Code bug" | grep -o 'BUG-[0-9]*' | head -1 | cut -c5-)"
CODE_DIR=src "$B" verify "$bn" --run ./ok.sh >/dev/null 2>&1; bv="$(ls Workspace/Docs/Bugs/BUG-"$bn"-*/BUG-"$bn"-VERIFICATION.md | head -1)"
bst="$(grep -m1 '^\*\*Overall status:\*\*' "$bv")"
echo v5 > src/app.txt; CODE_DIR=src "$B" verify "$bn" --run ./ok.sh >/dev/null 2>&1; G checkout -q -- src/app.txt
{ [ "$(grep -cxF -- "- **Commit:** $head" "$bv")" = 1 ] && [ "$(grep -cxF -- "- **Commit:** $head (with uncommitted changes in the source)" "$bv")" = 1 ] \
  && printf '%s\n' "$bst" | grep -qF "EXECUTED — PASS (last run" && printf '%s\n' "$bst" | grep -qF ", tree $s1, suite ./ok.sh@" \
  && refused nosuch 'CODE_DIR nosuch is not a folder in the project' "$B" verify "$bn" --run ./ok.sh; } \
  || { echo "FAIL E8: bug verify did not record the commit, the code folder's fingerprint or the note, or ran with a missing code folder"; exit 1; }
# E9: with the default, the record gains only the commit line, and the readers still see the PASS
m="$(newwo Default)"; "$W" verify "$m" --run ./ok.sh >/dev/null 2>&1; dv="$(rec . "$m")"
{ [ "$(grep -cE -- '^- \*\*Commit:\*\* ' "$dv")" = 1 ] && grep -m1 '^\*\*Overall status:\*\*' "$dv" | grep -qF ", suite ./ok.sh@" \
  && "$W" list 2>/dev/null | grep -F "WO-$m" | grep -F PASS >/dev/null; } \
  || { echo "FAIL E9: a default verify did not record the commit, or a reader lost the PASS"; exit 1; }
# E10: a CODE_DIR that is not written as a folder inside the project, relative to it, is refused by both drivers,
# on one line whatever it holds
for bad in ../x /tmp ':!src' -x 'a*' 'a?b' 'a\b' 'a[b' '..' 'a/../b' 'src/..' 'src/.' 'a//b' 'a/./b' "$(printf 'a\nb')" "$(printf 'a\r')"; do
  for drv in "$W" "$B"; do
    out="$(CODE_DIR="$bad" "$drv" list 2>&1)" && { echo "FAIL E10: CODE_DIR=$bad was accepted"; exit 1; }
    { printf '%s\n' "$out" | grep -qF 'CODE_DIR in pipeline.config.sh or the environment must be a folder inside the project' \
      && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]; } \
      || { echo "FAIL E10: CODE_DIR=$bad was refused without saying why on one line"; exit 1; }
  done
done
# E11: verify and wo fingerprint refuse a code folder the fingerprint could never see change: missing, a
# symbolic link, .git, the pipeline, a pipeline folder, the workspace, empty, or wholly ignored by git
ln -s src lnk; mkdir -p empty ign; echo x > ign/a; echo 'ign/' >> .gitignore; k="$(newwo Refusals)"
for case in "nosuch|is not a folder in the project" "lnk|is or passes through a symbolic link" ".git|is inside .git" \
            ".aicodepipeline|is inside .aicodepipeline" "Workspace/Docs/WorkOrders|is inside Workspace/Docs/WorkOrders" \
            "Workspace|is inside Workspace" "empty|holds no file the fingerprint reads" "ign|holds no file the fingerprint reads"; do
  d="${case%%|*}"; msg="CODE_DIR $d ${case#*|}"
  { refused "$d" "$msg" "$W" verify "$k" --run ./ok.sh && refused "$d" "$msg" "$W" fingerprint; } \
    || { echo "FAIL E11: CODE_DIR=$d was not refused with: $msg"; exit 1; }
done
rm -f lnk; rm -rf empty ign; G checkout -q -- .gitignore
# E12: the baseline readers see the code folder: a baseline taken on the whole project reads as changed under
# CODE_DIR=src, one taken under CODE_DIR=src reads as this exact tree, and kb.py's survey hash is the same value
I3=Workspace/Testing/suites/intake-03-baseline.sh
"$A" baseline --command true >/dev/null 2>&1 || { echo "FAIL setup: acp baseline failed"; exit 1; }
says() { printf '%s\n' "$1" | grep -F -- "$2" >/dev/null; }   # doctor and the suite exit non-zero when they report a problem
kbh() { CODE_DIR="${1-}" python3 -I -c 'import sys; sys.path.insert(0, ".aicodepipeline/core/hooks"); import kb; print(kb.tree_hash(".", ".aicodepipeline", ["x"]))'; }
dr="$(CODE_DIR=src "$A" doctor . 2>&1)"; i3="$(CODE_DIR=src bash "$I3" 2>&1)"
{ says "$dr" 'the tree has changed since' && says "$i3" 'the tree has changed since the baseline was taken'; } \
  || { echo "FAIL E12: a whole-project baseline did not read as changed under CODE_DIR=src"; exit 1; }
CODE_DIR=src "$A" baseline --command true >/dev/null 2>&1
dr="$(CODE_DIR=src "$A" doctor . 2>&1)"; i3="$(CODE_DIR=src bash "$I3" 2>&1)"
{ grep -qF "tree $s1" Workspace/Testing/results/BASELINE.md && says "$dr" 'baseline recorded against this exact tree' \
  && says "$i3" 'the baseline was taken against this exact tree' && [ "$(kbh src)" = "$s1" ]; } \
  || { echo "FAIL E12: a baseline taken under CODE_DIR=src was not read against the code folder"; exit 1; }
# E13: an unusable CODE_DIR gives the baseline readers no fingerprint: against a real baseline, intake step 3
# says the current fingerprint could not be computed and doctor that the tree changed; acp baseline then records
# nofp (which intake step 3 reports as naming no tree), and kb.py falls back to its file-list hash
i3="$(CODE_DIR=empty-missing bash "$I3" 2>&1)"; dr="$(CODE_DIR=empty-missing "$A" doctor . 2>&1)"
CODE_DIR=empty-missing "$A" baseline --command true >/dev/null 2>&1; i3b="$(CODE_DIR=empty-missing bash "$I3" 2>&1)"
{ says "$i3" 'the current tree fingerprint could not be computed' && says "$dr" 'the tree has changed since' \
  && grep -qF 'tree nofp' Workspace/Testing/results/BASELINE.md && says "$i3b" 'the baseline names no tree' \
  && [ "$(kbh empty-missing)" = "$(printf 'x' | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-16)" ]; } \
  || { echo "FAIL E13: an unusable CODE_DIR gave a baseline reader a fingerprint"; exit 1; }
# E14: outside git, and in a repository with no commit yet, the commit is recorded as none; outside git the
# default fingerprint ignores a work-order change, and every spelling of the code folder gives one value
cd "$EVAL_TMP" && "$PIPELINE_ROOT/bin/new-project" q --name Q --no-git >/dev/null 2>&1 && cd q || { echo "FAIL setup: second new-project failed"; exit 1; }
grep -v '^export CODE_DIR=' pipeline.config.sh > ../cfg && mv ../cfg pipeline.config.sh
printf '#!/usr/bin/env bash\nexit 0\n' > ok.sh; j="$(newwo NoGit)"
q0="$(fp '')"; [ "$q0" = "$(fp .)" ] && [ "$q0" = "$(fp ./)" ] || { echo "FAIL E14: outside git, the default CODE_DIR changed the tree fingerprint"; exit 1; }
echo note >> "$(ls -d Workspace/Docs/WorkOrders/WO-"$j"-*)/notes.md"
[ "$(fp '')" = "$q0" ] || { echo "FAIL E14: outside git, a work-order change moved the default fingerprint"; exit 1; }
.aicodepipeline/bin/wo verify "$j" --run ./ok.sh >/dev/null 2>&1
grep -qxF -- '- **Commit:** none (not a git repository)' "$(rec . "$j")" || { echo "FAIL E14: outside git the commit was not recorded as none"; exit 1; }
mkdir -p src dist; echo v1 > src/app.txt; echo x > dist/a; q1="$(fp src)"
for sp in ./src src/ ./src/ 'src//'; do [ "$(fp "$sp")" = "$q1" ] || { echo "FAIL E14: outside git, CODE_DIR=$sp and CODE_DIR=src gave different fingerprints"; exit 1; }; done
echo x > notes.txt; [ "$(fp src)" = "$q1" ] || { echo "FAIL E14: outside git, a change outside CODE_DIR changed the tree fingerprint"; exit 1; }
refused dist 'CODE_DIR dist holds no file the fingerprint reads' .aicodepipeline/bin/wo fingerprint || { echo "FAIL E14: outside git, CODE_DIR=dist was not refused"; exit 1; }
git init -q && .aicodepipeline/bin/wo verify "$j" --run ./ok.sh >/dev/null 2>&1
grep -qxF -- '- **Commit:** none (no commit yet)' "$(rec . "$j")" || { echo "FAIL E14: a repository with no commit yet was not recorded as none"; exit 1; }
exit 0
