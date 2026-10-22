#!/usr/bin/env bash
# evidence-scrub: wo verify and bug verify keep host paths out of the evidence: the project's path, then the
# home folder (never an empty or / home), are replaced in the log, the record and the GitHub comment,
# and the suite path is shown relative to the project, with the project's path taken as text.
set -uo pipefail
mkdir -p "$EVAL_TMP/w[1]" "$EVAL_TMP/h" && cd "$EVAL_TMP/w[1]" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug; R="$(pwd -P)"; H="$EVAL_TMP/h"; mkdir -p s
hostpath() { grep -v '^other' "$1" | grep -qF -e "$R" -e "$H"; }   # the other lines keep a longer name on purpose
cat > s/leak.sh <<'S'
#!/usr/bin/env bash
r="$(pwd -P)"; echo "root=$r"; echo "file=$r/a/b"; echo "home=$HOME/.cache/z"; echo "other=${r}x"; echo "other3=${r}+1"
echo "url=file://$r/a.js:1:2"; echo "flag=-I$r/include"; printf 'ansi=\033[31m%s/a.py\033[0m\n' "$r"; echo "at=x@$r/x"; echo "hurl=file://$HOME/x.js"; echo "bin=/usr/bin"; echo "slash=/"; echo "1 passed, 0 failed"
S
mkdir -p "$EVAL_TMP/gh"; printf '#!/usr/bin/env bash\ncase "$*" in "repo view"*) echo me/proj;; *) printf "%%s\\n" "$*" >> "%s/gh.log";; esac\n' "$EVAL_TMP" > "$EVAL_TMP/gh/gh"; chmod +x "$EVAL_TMP/gh/gh"
n="$($W new "scrub" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"; n="${n#WO-}"
b="$($B new "scrub" --category database 2>/dev/null | grep -o 'BUG-[0-9][0-9]*' | head -1)"; b="${b#BUG-}"
{ [ -n "$n" ] && [ -n "$b" ]; } || { echo "FAIL setup: could not open a work order and a bug"; exit 1; }
printf 'issue_number=5\n' >> "$(ls -d Workspace/Docs/WorkOrders/WO-"$n"-*/.wo-meta | head -1)"
# run each driver with the suite given by its absolute path, and HOME set to a folder outside the project
HOME="$H" PATH="$EVAL_TMP/gh:$PATH" $W verify "$n" --run "$R/s/leak.sh" >/dev/null 2>&1
HOME="$H" $B verify "$b" --run "$R/s/leak.sh" >/dev/null 2>&1
wl="$(ls -t Workspace/Docs/WorkOrders/WO-"$n"-*/WO-"$n"-VERIFICATION-*.log | head -1)"; wv="$(ls Workspace/Docs/WorkOrders/WO-"$n"-*/WO-"$n"-VERIFICATION.md | head -1)"
bl="$(ls -t Workspace/Docs/Bugs/BUG-"$b"-*/BUG-"$b"-VERIFICATION-*.log 2>/dev/null | head -1)"; bv="$(ls Workspace/Docs/Bugs/BUG-"$b"-*/BUG-"$b"-VERIFICATION.md | head -1)"
# S1: the home folder is replaced by ~ in wo verify's log
grep -qxF 'home=~/.cache/z' "$wl" || { echo "FAIL S1: wo verify kept the home folder's path in the log"; exit 1; }
# S2: the project's path is replaced: a path under it becomes relative, the project itself becomes .
{ grep -qxF 'file=a/b' "$wl" && grep -qxF 'root=.' "$wl"; } || { echo "FAIL S2: wo verify kept the project's path in the log"; exit 1; }
# S3: a longer name that only starts with the project's path, and ordinary paths, are left alone
{ grep -qxF "other=${R}x" "$wl" && grep -qxF "other3=${R}+1" "$wl" && grep -qxF 'bin=/usr/bin' "$wl"; } || { echo "FAIL S3: wo verify changed a path that is not the project's or the home folder"; exit 1; }
# S11: a project or home path after another character (a file:// URL, a -I flag, colour codes, @) is still replaced
{ grep -qxF 'url=file://a.js:1:2' "$wl" && grep -qxF 'flag=-Iinclude' "$wl" && grep -qxF "$(printf 'ansi=\033[31ma.py\033[0m')" "$wl" \
  && grep -qxF 'at=x@x' "$wl" && grep -qxF 'hurl=file://~/x.js' "$wl"; } || { echo "FAIL S11: a host path after another character stayed in the log"; exit 1; }
# S4: the record shows the suite relative to the project, with no host path, though the project's path holds [1]
{ grep -qF -- '- **Command:** `bash s/leak.sh`' "$wv" && grep -qF -- '- **Suite:** `s/leak.sh`' "$wv" && grep '^\*\*Overall status:\*\*' "$wv" | tail -1 | grep -qF 'suite s/leak.sh@' \
  && ! hostpath "$wv"; } || { echo "FAIL S4: wo verify's record holds a host path"; exit 1; }
# S5: the GitHub comment holds no host path
{ [ -s "$EVAL_TMP/gh.log" ] && grep -qF 'bash s/leak.sh' "$EVAL_TMP/gh.log" && ! hostpath "$EVAL_TMP/gh.log"; } \
  || { echo "FAIL S5: wo verify's GitHub comment holds a host path"; exit 1; }
# S6: bug verify does the same, in its log and its record
{ [ -n "$bl" ] && grep -qxF 'home=~/.cache/z' "$bl" && grep -qxF 'file=a/b' "$bl" && grep -qF -- '- **Command:** `bash s/leak.sh`' "$bv" && ! hostpath "$bv"; } \
  || { echo "FAIL S6: bug verify kept a host path in its log or record"; exit 1; }
# S7: a home of / is never replaced
HOME=/ PATH="$EVAL_TMP/gh:$PATH" $W verify "$n" --run s/leak.sh >/dev/null 2>&1
wl="$(ls -t Workspace/Docs/WorkOrders/WO-"$n"-*/WO-"$n"-VERIFICATION-*.log | head -1)"
{ grep -qxF 'bin=/usr/bin' "$wl" && grep -qxF 'slash=/' "$wl"; } || { echo "FAIL S7: a home of / was replaced in the log"; exit 1; }
# S8: an empty home is never replaced either
HOME= PATH="$EVAL_TMP/gh:$PATH" $W verify "$n" --run s/leak.sh >/dev/null 2>&1
wl="$(ls -t Workspace/Docs/WorkOrders/WO-"$n"-*/WO-"$n"-VERIFICATION-*.log | head -1)"
{ grep -qxF 'bin=/usr/bin' "$wl" && grep -qxF 'slash=/' "$wl" && grep -qxF 'file=a/b' "$wl"; } || { echo "FAIL S8: an empty home changed the log"; exit 1; }
# S9: the project's path goes first: with home above the project, a path in the project is relative, not under ~
HOME="$(cd "$EVAL_TMP" && pwd -P)" PATH="$EVAL_TMP/gh:$PATH" $W verify "$n" --run "$R/s/leak.sh" >/dev/null 2>&1
wl="$(ls -t Workspace/Docs/WorkOrders/WO-"$n"-*/WO-"$n"-VERIFICATION-*.log | head -1)"; wv="$(ls Workspace/Docs/WorkOrders/WO-"$n"-*/WO-"$n"-VERIFICATION.md | head -1)"
{ grep -qxF 'file=a/b' "$wl" && grep -qF -- '- **Command:** `bash s/leak.sh`' "$wv"; } || { echo "FAIL S9: with home above the project, the project's path was not replaced first"; exit 1; }
# S10: a home given with a trailing slash is scrubbed too
HOME="$H/" PATH="$EVAL_TMP/gh:$PATH" $W verify "$n" --run "$R/s/leak.sh" >/dev/null 2>&1
wl="$(ls -t Workspace/Docs/WorkOrders/WO-"$n"-*/WO-"$n"-VERIFICATION-*.log | head -1)"
{ grep '^home=' "$wl" | grep -q '^home=~/' && ! grep '^home=' "$wl" | grep -qF "$H"; } || { echo "FAIL S10: a home with a trailing slash was not replaced"; exit 1; }
mkdir -p "$H/x"; cp s/leak.sh "$H/x/leak.sh"
HOME="$H/" PATH="$EVAL_TMP/gh:$PATH" $W verify "$n" --run "$H/x/leak.sh" >/dev/null 2>&1
grep -qF -- '- **Command:** `bash ~/x/leak.sh`' "$wv" || { echo "FAIL S10: a suite under a home given with a trailing slash was not shown under ~"; exit 1; }
exit 0
