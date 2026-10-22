#!/usr/bin/env bash
# issue-number: wo publish records an issue number only when the issue URL ends in digits, and wo sync
# refuses a recorded number that is not digits before it calls gh with that number.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo
# a mock gh: logs every call, names the repository o/r, and `issue create` prints the URL given in GH_URL
mkdir -p "$EVAL_TMP/bin"; LOG="$EVAL_TMP/gh.log"; : > "$LOG"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\ncase "$1 $2" in "repo view") echo o/r;; "issue create") printf "%%s\\n" "$GH_URL";; esac\nexit 0\n' "$LOG" > "$EVAL_TMP/bin/gh"; chmod +x "$EVAL_TMP/bin/gh"
gh_env() { PATH="$EVAL_TMP/bin:$PATH" GH_URL="$1" "${@:2}"; }
order() { local n; n="$($W new "$1" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"; echo "${n#WO-}"; }
meta() { ls Workspace/Docs/WorkOrders/WO-"$1"-*/.wo-meta | head -1; }
# G1: a URL whose last part is not digits: no issue number is recorded, the publish says so and fails
for url in 'https://github.com/o/r/issues/@{[system("touch PWNED")]}' 'https://github.com/o/r/issues/' 'https://github.com/o/r/issues/4x' 'https://github.com/o/r/issues/4;5' 'https://github.com/o/r/issues/-1'; do
  n="$(order "bad url")"; [ -n "$n" ] || { echo "FAIL setup: could not open a work order"; exit 1; }
  out="$(gh_env "$url" $W publish "$n" 2>&1)"; rc=$?
  { [ "$rc" -ne 0 ] && ! grep -q '^issue_number=' "$(meta "$n")"; } || { echo "FAIL G1: wo publish recorded an issue number that is not a number"; exit 1; }
  printf '%s\n' "$out" | grep -qF "whose last part is not an issue number" || { echo "FAIL G1: wo publish refused without saying why"; exit 1; }
  grep -qxF "issue=$url" "$(meta "$n")" || { echo "FAIL G1: the issue URL was not kept, so the order could be published twice"; exit 1; }
  out="$(gh_env x $W sync "$n" 2>&1)" && { echo "FAIL G1: wo sync ran on an order with no issue number"; exit 1; }
  printf '%s\n' "$out" | grep -qF "has its issue URL recorded but no issue number" || { echo "FAIL G1: after a refused publish, wo sync did not say how to recover"; exit 1; }
done
[ ! -e PWNED ] || { echo "FAIL G1: a value ran as code"; exit 1; }
# G2: a URL ending in digits records that number, and wo sync passes it to gh
n="$(order "good url")"
gh_env 'https://github.com/o/r/issues/42' $W publish "$n" >/dev/null 2>&1 && grep -qx 'issue_number=42' "$(meta "$n")" \
  || { echo "FAIL G2: wo publish no longer records a numeric issue number"; exit 1; }
gh_env x $W sync "$n" >/dev/null 2>&1 && grep -qF 'issue edit 42 --repo o/r' "$LOG" || { echo "FAIL G2: wo sync no longer edits issue 42"; exit 1; }
# G3: a recorded issue number that is not digits (an older record) is refused before gh is called with it
for v in '7;7' 'abc' '7 8' '-1'; do
  n="$(order "old record")"; m="$(meta "$n")"
  printf 'issue=https://github.com/o/r/issues/7\nissue_number=%s\n' "$v" >> "$m"
  : > "$LOG"; out="$(gh_env x $W sync "$n" 2>&1)"; rc=$?
  { [ "$rc" -ne 0 ] && ! grep -qvF "repo view --json nameWithOwner -q .nameWithOwner" "$LOG"; } || { echo "FAIL G3: wo sync passed the recorded issue number [$v] to gh"; exit 1; }
  printf '%s\n' "$out" | grep -qF "the recorded issue number is not a number" || { echo "FAIL G3: wo sync refused [$v] without saying why"; exit 1; }
done
exit 0
