#!/usr/bin/env bash
# The commit hook and acp check judge credentials by bin/sanitize's own key list, so a key sanitize fails at a
# publish cannot be committed; a key list that cannot be read refuses the commit rather than passing it; and a
# long line costs one pass, not one per character.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
export HOME="$EVAL_TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$EVAL_TMP"; mkdir -p "$HOME"
git config --global user.name t && git config --global user.email t@example.com || die "the eval could not set a git identity"
has() { case "$out" in *"$1"*) return 0;; esac; return 1; }
# every value is built at run time from pieces, so this file holds no key
rep() { printf "%${2}s" "" | tr ' ' "$1"; }
R="$EVAL_TMP/r"; mkdir -p "$R" && git -C "$R" init -q || die "the eval could not make a repository"
# hook <pipeline hooks dir>: the commit hook on what is staged in $R
hook() { rc=0; out="$(cd "$R" && printf '%s' '{"tool_input":{"command":"git commit -m x"}}' \
  | perl -e 'alarm 60; exec @ARGV' python3 "$1/commit-quality.py" 2>&1)" || rc=$?; }
stage() { printf '%s\n' "$1" > "$R/k.ts" && git -C "$R" add k.ts; }
H="$PIPELINE_ROOT/core/hooks"

# K1: each key sanitize fails at a publish is refused at a commit, and sanitize fails the same line
while IFS='|' read -r what line; do
  stage "export const k = \"$line\";"
  hook "$H"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL K1: the commit hook let through $what, which sanitize fails" "exit $rc" "$out"
  rc=0; "$PIPELINE_ROOT/bin/sanitize" "$R" --quiet >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || die "FAIL K1: sanitize did not fail $what (exit $rc), so the two lists disagree"
done <<EOF
an Anthropic key|sk-$(printf 'ant')-api03-$(rep B 40)$(rep 9 40)
an OpenAI project key|sk-$(printf 'proj')-$(rep A 24)$(rep 7 24)
a GitLab token|gl$(printf 'pat')-$(rep E 10)$(rep 4 10)
an AWS temporary key id|AS$(printf 'IA')$(rep Q 8)$(rep 5 8)
a Stripe webhook secret|wh$(printf 'sec')_$(rep W 16)$(rep 8 16)
a GitHub fine-grained token|github$(printf '_pat')_$(rep a 22)_$(rep b 59)
a Slack app token|xa$(printf 'pp')-1-A$(rep B 10)-$(rep 3 13)-$(rep f 64)
a PGP private key block|-----BEGIN PGP $(printf 'PRIVATE') KEY BLOCK-----
an AWS access key id|AK$(printf 'IA')$(rep Q 8)$(rep 5 8)
an SSH2 encrypted private key|-----BEGIN SSH2 ENCRYPTED $(printf 'PRIVATE') KEY-----
EOF
# K2: acp check, which the git hooks run, judges an env file by the same list
printf 'ANTHROPIC_API_KEY=sk-%s-api03-%s\n' ant "$(rep B 40)" > "$R/.env.local"
rc=0; out="$(python3 "$H/check.py" --root "$R" --paths "$R/.env.local" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || die "FAIL K2: acp check let through a key in an env file that sanitize fails" "exit $rc" "$out"
rm -f "$R/.env.local"
# K3: an AWS secret, unquoted in an env file or a credentials file, is refused at a commit too
AWSK="wJalrXUtnFEMI$(printf 'K7MDENG')bPxRfiCYz1$(rep q 4)Abcd9Q"
for f in .env "aws/credentials.ini"; do
  mkdir -p "$(dirname "$R/$f")" && printf 'AWS_SECRET_ACCESS_%s=%s\n' KEY "$AWSK" > "$R/$f"
  [ "$f" = .env ] || printf 'aws_secret_access_%s = %s\n' key "$AWSK" > "$R/$f"
  rc=0; out="$(python3 "$H/check.py" --root "$R" --paths "$R/$f" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ] || die "FAIL K3: acp check let through an AWS secret in $f" "exit $rc" "$out"; rm -f "$R/$f"
done
# N3: sanitize's name-based rows are a publish's judgment, not a commit's: ordinary placeholders and local
# defaults pass acp check and the commit hook
n3() { # <file> <line>
  mkdir -p "$(dirname "$R/$1")" && printf '%s\n' "$2" > "$R/$1"
  rc=0; out="$(python3 "$H/check.py" --root "$R" --paths "$R/$1" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || die "FAIL N3: acp check refused an ordinary line in $1: $2" "exit $rc" "$out"; rm -f "$R/$1"; }
n3 .env.example "API_""KEY=replace-me-with-a-real-key"
n3 .env.example "AWS_SECRET_ACCESS_KEY=$(rep X 40)"
n3 .env.example "AWS_SECRET_ACCESS_KEY=$(rep 0 40)"
n3 .env.example "AWS_SECRET_ACCESS_""KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCY$(printf 'EXAMPLE')KEY"
n3 .env.example "DATABASE_URL=postgres://postgres:$(printf 'dev')@localhost:5432/app"
n3 docker-compose.yml "      - POSTGRES_PASS""WORD=postgres"
n3 scripts/db.sh "export PGPASS""WORD=localdev"
stage "const api""Key = getApiKeyFromEnvironment();"; hook "$H"
[ "$rc" -eq 0 ] || die "FAIL N3: the commit hook refused an assignment from a function call" "exit $rc" "$out"
# O1: the hook's own, stricter shapes still block: a credential-named literal, a database URL with any password
for line in "const REAL_SECRET = '$(rep z 20)';" "const db = 'postgres://app:$(printf 'Zq7w')9Kd2@db:5432/app';"; do
  stage "$line"; hook "$H"; [ "$rc" -eq 2 ] || die "FAIL O1: the commit hook no longer blocks: $line" "exit $rc" "$out"
done
# N4: a database URL whose password is a placeholder (the user again, a slot, a stand-in word) is not a credential
for line in "const db = 'postgres://postgres:postgres@db:5432/app';" "const db = \`postgres://app:$(printf '%s' '${DB_PASS}')@db/app\`;" \
            "const db = 'postgres://app:<password>@db/app';" "const db = 'postgres://app:$(printf 'change')me123@db/app';"; do
  stage "$line"; hook "$H"; [ "$rc" -eq 0 ] || die "FAIL N4: the commit hook refused a placeholder database URL: $line" "exit $rc" "$out"
done
# N1: a publishable key, made for client code, and the docs' placeholders are not refused at a commit
for line in "const pk = \"p$(printf 'k')_live_$(rep P 24)\";" "const t = \"xo$(printf 'xb')-your-bot-token\";" "const apiKey = \"sk-$(printf 'proj')-xxxxx\";"; do
  stage "$line"; hook "$H"; [ "$rc" -eq 0 ] || die "FAIL N1: the commit hook refused a value that is not a secret: $line" "exit $rc" "$out"
done
# N2: a commit that takes a key line out of a file is judged on what it adds, so it is not refused
printf 'export const k = "sk-%s-api03-%s";\nexport const x = 1;\n' ant "$(rep B 40)" > "$R/k.ts" && git -C "$R" add k.ts && git -C "$R" commit -q -m key --no-verify \
  && printf 'export const x = 1;\n' > "$R/k.ts" && git -C "$R" add k.ts || die "the eval could not commit and take out a key"
hook "$H"; [ "$rc" -eq 0 ] || die "FAIL N2: a commit taking a key out was refused" "exit $rc" "$out"
git -C "$R" commit -q -m gone --no-verify || die "the eval could not commit the removal"
# A1: the per-line fixture exemption still works for the shared list
stage "export const k = \"sk-$(printf 'ant')-api03-$(rep B 40)\";  // acp:allow-secret — fixture, asserted never to be emitted"
hook "$H"; [ "$rc" -eq 0 ] || die "FAIL A1: a marked fixture line was refused" "exit $rc" "$out"
# Q2: a file named outside ASCII that is not source is not judged as source (no debug finding under strict)
q="$(printf 'caf\303\251').md"; printf 'console.log("x")\n' > "$R/$q" && git -C "$R" add -- "$q" || die "the eval could not stage $q"
rc=0; out="$(cd "$R" && printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | ACP_STRICT=1 python3 "$H/commit-quality.py" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || die "FAIL Q2: a document named $q was judged as source" "exit $rc" "$out"
git -C "$R" rm -q --cached -- "$q"; rm -f -- "$R/$q"
stage "export const k = \"sk-$(printf 'ant')-api03-$(rep B 40)\";"

# P1: a pipeline built as a plugin (hooks in hooks/scripts/, sanitize in bin/) judges with the same list
PL="$EVAL_TMP/plugin"; mkdir -p "$PL/hooks" "$PL/bin" && cp -R "$H" "$PL/hooks/scripts" && cp "$PIPELINE_ROOT/bin/sanitize" "$PL/bin/" \
  || die "the eval could not build a plugin-shaped pipeline"
hook "$PL/hooks/scripts"; [ "$rc" -eq 2 ] || die "FAIL P1: the commit hook from a plugin let through an Anthropic key" "exit $rc" "$out"
# X1: reading the key list leaves nothing behind in the pipeline (no bytecode beside bin/sanitize)
[ ! -e "$PL/bin/__pycache__" ] || die "FAIL X1: loading the key list wrote $PL/bin/__pycache__"

# R1: a key list that cannot be read refuses the commit (exit 2) and stops acp check (exit 3); it never passes
broken() { # <name> <how>: a copy of the pipeline whose bin/sanitize is missing or broken
  B="$EVAL_TMP/$1"; mkdir -p "$B/core" "$B/bin" && cp -R "$H" "$B/core/hooks" && cp "$PIPELINE_ROOT/bin/sanitize" "$B/bin/" || exit 9
  case "$2" in
    missing) rm "$B/bin/sanitize";;
    exits)   perl -0pi -e 's/\nimport argparse/\nraise SystemExit(0)\nimport argparse/' "$B/bin/sanitize";;
    parse)   printf '\ndef (:\n' >> "$B/bin/sanitize";;
    empty)   perl -0pi -e 's/\nif __name__ == "__main__":/\nPATTERNS = []\nif __name__ == "__main__":/' "$B/bin/sanitize";;
  esac
  [ "$2" = missing ] || ! cmp -s "$B/bin/sanitize" "$PIPELINE_ROOT/bin/sanitize" || exit 9; }
for how in missing exits parse empty; do
  broken "b-$how" "$how" || die "the eval could not break a copy of the pipeline ($how)"
  hook "$B/core/hooks"
  { [ "$rc" -eq 2 ] && has "Commit blocked — the key list in"; } || die "FAIL R1: with bin/sanitize $how, the commit hook did not refuse" "exit $rc" "$out"
  rc=0; out="$(python3 "$B/core/hooks/check.py" --root "$R" --paths "$R/k.ts" 2>&1)" || rc=$?
  { [ "$rc" -eq 3 ] && has "the key list in"; } || die "FAIL R1: with bin/sanitize $how, acp check did not stop with exit 3" "exit $rc" "$out"
done

# R2, R3: staged changes or a staged-file list git will not give (here, a git that fails that one call) refuse the
# commit rather than pass it
REAL="$(command -v git)"
fake() { # <dir> <argument the stand-in fails on>
  mkdir -p "$1" && printf '#!/bin/sh\ncase "$*" in *"%s"*) exit 1;; esac\nexec "%s" "$@"\n' "$2" "$REAL" > "$1/git" && chmod +x "$1/git"; }
fake "$EVAL_TMP/fg2" "--unified=0" && fake "$EVAL_TMP/fg3" "--name-only" || die "the eval could not make a stand-in git"
rc=0; out="$(cd "$R" && printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | PATH="$EVAL_TMP/fg2:$PATH" python3 "$H/commit-quality.py" 2>&1)" || rc=$?
{ [ "$rc" -eq 2 ] && has "could not be read"; } || die "FAIL R2: a staged change git could not show was let through" "exit $rc" "$out"
rc=0; out="$(cd "$R" && printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | PATH="$EVAL_TMP/fg3:$PATH" python3 "$H/commit-quality.py" 2>&1)" || rc=$?
{ [ "$rc" -eq 2 ] && has "git could not list the staged files"; } || die "FAIL R3: a staged-file list git could not give was read as nothing staged" "exit $rc" "$out"
# E1: a file that is not UTF-8 in the same commit neither refuses the commit nor hides a key beside it
printf 'name,city\nJos\351,M\341laga\n' > "$R/data.csv" && printf 'export const x = 1;\n' > "$R/k.ts" && git -C "$R" add data.csv k.ts || die "the eval could not stage a latin-1 file"
hook "$H"; [ "$rc" -eq 0 ] || die "FAIL E1: a commit with a latin-1 file was refused" "exit $rc" "$out"
stage "export const k = \"sk-$(printf 'ant')-api03-$(rep B 40)\";"
hook "$H"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL E1: a key beside a latin-1 file was let through" "exit $rc" "$out"
# S1: the user's diff settings (no prefix, mnemonic prefixes, colour, an external diff) do not hide a key
for c in "diff.noprefix true" "diff.mnemonicPrefix true" "color.diff always" "diff.external true"; do
  git -C "$R" config $c && hook "$H"; git -C "$R" config --unset "${c%% *}"
  { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL S1: with $c, the commit hook let a key through" "exit $rc" "$out"
done
# S2: with the user's diff.noprefix, a document that is not source is still not judged as source
git -C "$R" config diff.noprefix true && printf 'console.log("x")\n' > "$R/notes.md" && git -C "$R" add notes.md && printf 'export const x = 1;\n' > "$R/k.ts" && git -C "$R" add k.ts \
  || die "the eval could not stage notes.md"
rc=0; out="$(cd "$R" && printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | ACP_STRICT=1 python3 "$H/commit-quality.py" 2>&1)" || rc=$?
git -C "$R" config --unset diff.noprefix; git -C "$R" rm -q --cached notes.md; rm -f "$R/notes.md"
[ "$rc" -eq 0 ] || die "FAIL S2: with diff.noprefix, a document was judged as source" "exit $rc" "$out"
# Q1: a file whose name git has to quote, or one with a space (git ends it with a tab), is still judged
git -C "$R" reset -q; rm -f "$R/data.csv" "$R/k.ts"
for q in "$(printf 'caf\303\251').ts" "$(printf 'a\tb').ts" "my key.ts"; do
  printf 'export const k = "sk-%s-api03-%s";\n' ant "$(rep B 40)" > "$R/$q" && git -C "$R" add -- "$q" || die "the eval could not stage $q"
  hook "$H"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL Q1: a key in a file named $q was let through" "exit $rc" "$out"
  git -C "$R" rm -q --cached -- "$q"; rm -f -- "$R/$q"
done
stage "export const k = \"sk-$(printf 'ant')-api03-$(rep B 40)\";"

# D1-D7: the repository the commit is for is the one judged, wherever the session's folder is
NR="$EVAL_TMP/not-a-repo"; mkdir -p "$NR"; SP2="$EVAL_TMP/with space"; mkdir -p "$SP2" && git -C "$SP2" init -q \
  && printf 'export const k = "sk-%s-api03-%s";\n' ant "$(rep B 40)" > "$SP2/k.ts" && git -C "$SP2" add k.ts || die "the eval could not make a second repository"
from() { # <folder the hook runs in> <payload cwd or ""> <command>
  local pay; pay="$(python3 -c 'import json, sys; d = {"tool_input": {"command": sys.argv[2]}}; d.update({"cwd": sys.argv[1]} if sys.argv[1] else {}); print(json.dumps(d))' "$2" "$3")"
  rc=0; out="$(cd "$1" && printf '%s' "$pay" | perl -e 'alarm 60; exec @ARGV' python3 "$H/commit-quality.py" 2>&1)" || rc=$?; }
for c in "cd $R && git commit -m x" "git -C $R commit -m x" "git -c user.name=t -C $R commit -m x" "cd \"$SP2\" && git add . && git commit -m x" \
         "git --git-dir=$R/.git --work-tree=$R commit -m x" "bash -c \"cd $R && git commit -m x\"" "/usr/bin/git -C $R commit" "git --no-pager -P -C $R commit -m x" "cd $EVAL_TMP && cd r && git commit -m x" "git --git-dir=$R/.git commit -m x"; do
  from "$NR" "" "$c"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL D1: from a folder that is not a repository, '$c' was not judged" "exit $rc" "$out"
done
from "$NR" "$R" "git commit -m x"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL D2: the session's folder in the payload was not used" "exit $rc" "$out"
from "$NR" "" "git commit -m x"; [ "$rc" -eq 0 ] || die "FAIL D3: a commit where git cannot commit (not a repository) was refused" "exit $rc" "$out"
mkdir -p "$NR/sub"; from "$NR" "" "cd sub && git commit -m x"; [ "$rc" -eq 0 ] || die "FAIL D3: a commit where no folder named is a repository was refused" "exit $rc" "$out"
from "$R" "" "cd \$ACP_NO_SUCH_VAR_X && git commit -m x"; { [ "$rc" -eq 2 ] && has "cannot be told"; } || die "FAIL D4: a commit whose folder cannot be told was not refused" "exit $rc" "$out"
from "$R" "" "git status"; [ "$rc" -eq 0 ] || die "FAIL D5: a command that commits nothing was judged" "exit $rc" "$out"
for c in "cd \$ACP_NO_SUCH_VAR_X && make" "pushd +1; ls" "cd \$(git rev-parse --show-toplevel)/web && npm test"; do
  from "$R" "" "$c"; [ "$rc" -eq 0 ] || die "FAIL D5: '$c', which commits nothing, was refused" "exit $rc" "$out"
done
# D6: subshells, conditions and pipes do not move the judgment off the repository holding the key (every folder
# the command names is judged, the session's included)
mkdir -p "$EVAL_TMP/plain" && A="$EVAL_TMP/a" && mkdir -p "$A" && git -C "$A" init -q || die "the eval could not make the side folders"
for c in "(cd ../plain && make) ; git commit -m x" "[ -d x ] && cd ../a; git commit -m x" "true || cd ../a; git commit -m x" \
         "cd ../a | true; git commit -m x" "( cd ../a ); git commit -m x" "cd ../a & git commit -m x"; do
  from "$NR" "$R" "$c"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL D6: '$c' moved the judgment off the repository holding the key" "exit $rc" "$out"
done
# D7: every commit in a command is judged, not only the first
for c in "git -C $A commit -m x && git -C $R commit -m y" "cd $A && git commit -m x; cd $R && git commit -m y"; do
  from "$NR" "" "$c"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL D7: a second commit in '$c' was not judged" "exit $rc" "$out"
done
# D7: a repository named twice (as a folder and as its git folder) is judged once, its key reported once
from "$NR" "" "git -C $R --git-dir=$R/.git commit -m x"
{ [ "$rc" -eq 2 ] && [ "$(printf '%s\n' "$out" | grep -c 'k.ts: ')" -eq 1 ]; } || die "FAIL D7: a repository named twice was reported twice" "exit $rc" "$out"
# D8: GIT_DIR and GIT_WORK_TREE however set, and pushd, name places too; the session's own GIT_DIR is one more
# place, never the lens every other place is read through
for c in "GIT_DIR=$R/.git git commit -m x" "export GIT_DIR=$R/.git; git commit -m x" "env GIT_WORK_TREE=$R git commit -m x" "pushd $R && git commit -m x"; do
  from "$NR" "" "$c"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL D8: '$c' was not judged" "exit $rc" "$out"
done
rc=0; out="$(cd "$NR" && printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | GIT_DIR="$R/.git" python3 "$H/commit-quality.py" 2>&1)" || rc=$?
{ [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL D8: the session's GIT_DIR was not judged" "exit $rc" "$out"
rc=0; out="$(cd "$NR" && printf '%s' "{\"tool_input\":{\"command\":\"git -C $R commit -m x\"}}" | GIT_DIR="$A/.git" python3 "$H/commit-quality.py" 2>&1)" || rc=$?
{ [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL D8: the session's GIT_DIR hid the repository the command names" "exit $rc" "$out"
# D9: a folder named over and over is one place, judged; a command naming more places than can be checked is refused
from "$NR" "" "cd . && cd .. && cd not-a-repo && cd .. && cd r && cd .. && cd r && git commit -m x"
{ [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL D9: a command naming the same folders again was not judged" "exit $rc" "$out"
from "$NR" "$R" "cd d1 && cd d2 && cd d3 && cd d4 && cd d5 && cd d6 && cd d7 && cd d8 && git commit -m x"
{ [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL D9: folders that do not exist filled the places and hid the key" "exit $rc" "$out"
many=""; for n in $(seq 1 34); do mkdir -p "$NR/e$n"; many="$many cd $NR/e$n;"; done
from "$NR" "" "$many git commit -m x"
{ [ "$rc" -eq 2 ] && has "more folders than can be checked"; } || die "FAIL D9: a command naming too many places was not refused" "exit $rc" "$out"
# H1-H3: a here-document's body is data, not shell: a quote in it neither hides a later cd nor refuses a commit
# message; a new line separates commands
c="$(printf "cat <<'EOF'\ndon't\nEOF\ncd %s && git commit -m x" "$R")"; from "$NR" "" "$c"
{ [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL H1: a quote in a here-document hid the cd after it" "exit $rc" "$out"
c="$(printf "git commit -F - <<'EOF'\nit's done\nEOF")"; from "$NR" "$A" "$c"
[ "$rc" -eq 0 ] || die "FAIL H2: a commit message in a here-document was refused" "exit $rc" "$out"
c="$(printf "git -C %s commit -m x\ncd %s" "$A" "$R")"; from "$NR" "" "$c"
{ [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL H3: a cd on the next line was taken for the commit's arguments" "exit $rc" "$out"
# Q3: quoted text naming a folder is read; a commit's own message never is
from "$NR" "" "sh -c \"cd $R\"; git commit -m x"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL Q3: a folder named inside quotes was not counted" "exit $rc" "$out"
from "$NR" "" "git -C $A commit -m \"cd $R\""; [ "$rc" -eq 0 ] || die "FAIL Q3: a commit message was read as shell" "exit $rc" "$out"
# B1-B3: cd - and popd return to a place already counted; a simple assignment names its folder; an untellable -C
# on a git command that is not the commit does not refuse the commit
for c in "cd $A && cd - && git commit -m x" "pushd $A && popd && git commit -m x"; do
  from "$NR" "" "$c"; [ "$rc" -eq 0 ] || die "FAIL B1: '$c' was refused" "exit $rc" "$out"
done
from "$NR" "" "REPO=$R; cd \"\$REPO\" && git commit -m x"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL B2: a folder set by an assignment was not followed" "exit $rc" "$out"
from "$NR" "" "git -C \"\$(pwd)\" status && git -C $R commit -m x"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL B3: an untellable -C on git status stopped the commit being judged" "exit $rc" "$out"
# I1: a commit run through xargs, find -exec or submodule foreach cannot be placed, so it is refused; xargs alone is not
for c in "ls | xargs git commit -m x" "find . -exec git commit -m x \\;" "git submodule foreach 'git commit -m x'"; do
  from "$NR" "$A" "$c"; { [ "$rc" -eq 2 ] && has "cannot be told"; } || die "FAIL I1: '$c' was not refused" "exit $rc" "$out"
done
for c in "ls | xargs rm" "ls | xargs echo; git commit -m x"; do
  from "$NR" "$A" "$c"; [ "$rc" -eq 0 ] || die "FAIL I1: '$c', whose commit is not run through xargs, was refused" "exit $rc" "$out"
done
# W1: the report names the repository holding the key, even when the command commits in another
from "$NR" "$R" "cd $A && git commit -m x"
{ [ "$rc" -eq 2 ] && has "in $(cd "$R" && pwd -P):"; } || die "FAIL W1: the report did not name the repository holding the key" "exit $rc" "$out"
# T2: a git that runs out of time is refused by the hook, well inside Claude Code's 30 s
fake "$EVAL_TMP/fgslow" "--unified=0" && perl -0pi -e 's/exit 1;;/sleep 20; exit 0;;/' "$EVAL_TMP/fgslow/git" || die "the eval could not make a slow git"
start=$SECONDS; rc=0; out="$(cd "$R" && printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | PATH="$EVAL_TMP/fgslow:$PATH" python3 "$H/commit-quality.py" 2>&1)" || rc=$?; took=$((SECONDS - start))
{ [ "$rc" -eq 2 ] && has "the check ran out of time" && [ "$took" -le 15 ]; } || die "FAIL T2: a slow git took ${took}s and gave exit $rc" "$out"
# T3: a key is reported before any linter runs, so a slow linter cannot outlast the hook and lose it
mkdir -p "$R/node_modules/.bin" && printf '#!/bin/sh\nsleep 40\n' > "$R/node_modules/.bin/eslint" && chmod +x "$R/node_modules/.bin/eslint" && printf 'node_modules/\n' > "$R/.git/info/exclude"
start=$SECONDS; hook "$H"; took=$((SECONDS - start)); rm -rf "$R/node_modules"
{ [ "$rc" -eq 2 ] && has "credential-like values" && [ "$took" -le 5 ]; } || die "FAIL T3: with a slow linter the key took ${took}s (exit $rc)" "$out"

# T1: a long line with no spaces costs one pass: three 200,000-character lines are judged in a few seconds
python3 -c 'import sys; n = 200000; sys.stdout.write("const a = \"%s\";\nconst b = \"%s\";\nconst c = \"%s\";\n" % ("x" * n, "a_" * (n // 2), "secret_" * (n // 7)))' > "$R/k.ts" \
  && git -C "$R" add k.ts || die "the eval could not write a long line"
start=$SECONDS; hook "$H"; took=$((SECONDS - start))
{ [ "$rc" -eq 0 ] && [ "$took" -le 5 ]; } || die "FAIL T1: the commit hook took ${took}s (exit $rc) on three 200,000-character lines" "$out"
echo "commit-keys: all checks passed"
exit 0
