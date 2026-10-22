#!/usr/bin/env bash
# acp check --staged judges what the commit holds (the index), not the working copy, and every staged text file
# whatever its kind: code and configuration with the whole key list, any other text with sanitize's vendor-shaped
# keys; binary files are left alone. The commit hook reads every kind of text file the same way, and placeholders
# in prose pass.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
export HOME="$EVAL_TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$EVAL_TMP"; mkdir -p "$HOME"
git config --global user.name t && git config --global user.email t@example.com || die "the eval could not set a git identity"
has() { case "$out" in *"$1"*) return 0;; esac; return 1; }
rep() { printf "%${2}s" "" | tr ' ' "$1"; }
# every key is built at run time from pieces, so this file holds none
AKIA="AK$(printf 'IA')$(rep Q 8)$(rep 5 8)"; ANT="sk-$(printf 'ant')-api03-$(rep B 40)"; GHP="gh$(printf 'p')_$(rep a 36)"
BLK="-----BEGIN $(printf 'PRIVATE') KEY-----"; KEYFILE="deploy/server.$(printf 'pem')"
LIT="Kp4v$(rep w 6)Xw9$(rep q 6)Zz"; PWD8="Zq7w$(printf '9Kd2')"; PG="post$(printf 'gres')"; GLP="gl$(printf 'pat')-$(rep E 10)$(rep 4 10)"
R="$EVAL_TMP/r"; mkdir -p "$R" && git -C "$R" init -q && printf 'x\n' > "$R/seed.txt" && git -C "$R" add seed.txt && git -C "$R" commit -q -m seed \
  || die "the eval could not make a repository"
H="$PIPELINE_ROOT/core/hooks"
chk() { rc=0; out="$(cd "$R" && python3 "$H/check.py" --root "$R" --staged 2>&1)" || rc=$?; }
hook() { rc=0; out="$(cd "$R" && printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | perl -e 'alarm 60; exec @ARGV' python3 "$H/commit-quality.py" 2>&1)" || rc=$?; }
clear() { git -C "$R" reset -q; git -C "$R" clean -qfd; }

# X1: a key staged, then rewritten away in the working copy, is still the commit's: refused
printf 'const k = "%s";\n' "$ANT" > "$R/a.ts" && git -C "$R" add a.ts && printf 'const k = "";\n' > "$R/a.ts"
chk; { [ "$rc" -eq 2 ] && has "a.ts:1: credential-like value"; } || die "FAIL X1: acp check passed a commit whose staged copy holds a key" "exit $rc" "$out"
clear
# X2: a staged file deleted from the working copy is judged from the commit's copy
printf 'const k = "%s";\n' "$ANT" > "$R/b.ts" && git -C "$R" add b.ts && rm "$R/b.ts"
chk; { [ "$rc" -eq 2 ] && has "b.ts:1: credential-like value"; } || die "FAIL X2: a staged file gone from disk was not judged" "exit $rc" "$out"
clear
# X3: every kind of text file is read, by acp check and by the commit hook
while IFS='|' read -r f line; do
  mkdir -p "$(dirname "$R/$f")" && printf '%s\n' "$line" > "$R/$f" && git -C "$R" add -- "$f" || die "the eval could not stage $f"
  chk; { [ "$rc" -eq 2 ] && has "$f:1: credential-like value"; } || die "FAIL X3: acp check let a key through in $f" "exit $rc" "$out"
  hook; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL X3: the commit hook let a key through in $f" "exit $rc" "$out"
  clear
done <<EOF
$KEYFILE|$BLK
keys/id_rsa|$BLK
notes.txt|ANTHROPIC $ANT
README.md|use $AKIA here
Dockerfile|ENV TOKEN=$GLP
nginx/app.conf|token $GHP
infra/main.tf|access_key = "$AKIA"
Makefile|TOKEN := $GHP
config.xml|<token>$ANT</token>
.npmrc|//registry.example.com/:_authToken=$GHP
EOF
# X4: in prose, only vendor-shaped keys count: a placeholder assignment in a README passes both
printf 'Set API_%s="abcdefghijklmnop12345" in your environment.\n' KEY > "$R/README.md" && git -C "$R" add README.md
chk; [ "$rc" -eq 0 ] || die "FAIL X4: acp check refused a placeholder in a README" "exit $rc" "$out"
hook; [ "$rc" -eq 0 ] || die "FAIL X4: the commit hook refused a placeholder in a README" "exit $rc" "$out"
clear
# X5: a binary file is not read as text
printf 'x\0y %s\n' "$AKIA" > "$R/blob.bin" && git -C "$R" add blob.bin
chk; [ "$rc" -eq 0 ] || die "FAIL X5: a binary file was read as text" "exit $rc" "$out"
clear
# X7: a staged entry git cannot read back blocks, naming it: the commit would carry something nobody looked at
git -C "$R" update-index --add --info-only --cacheinfo "100644,1234567890123456789012345678901234567890,ghost.ts" || die "the eval could not stage an unreadable entry"
chk; { [ "$rc" -eq 2 ] && has "ghost.ts: the commit's copy cannot be read back from git"; } || die "FAIL X7: a staged entry git cannot read was passed" "exit $rc" "$out"
clear
# X6: a symbolic link's blob is its target's name, not content: not read
ln -s "$AKIA" "$R/link" && git -C "$R" add link
chk; [ "$rc" -eq 0 ] || die "FAIL X6: a link's target name was read as content" "exit $rc" "$out"
clear

# C4: the folder a command finds for itself ($(pwd), $PWD, the repository's top) is a place already counted
printf 'const k = "%s";\n' "$ANT" > "$R/a.ts" && git -C "$R" add a.ts
NR="$EVAL_TMP/nr"; mkdir -p "$NR"
from() { local pay; pay="$(python3 -c 'import json, sys; print(json.dumps({"tool_input": {"command": sys.argv[2]}, "cwd": sys.argv[1]}))' "$R" "$1")"
  rc=0; out="$(cd "$NR" && printf '%s' "$pay" | python3 "$H/commit-quality.py" 2>&1)" || rc=$?; }
for c in 'cd "$(git rev-parse --show-toplevel)" && git commit -m x' 'cd "$PWD" && git commit -m x' 'git -C "$(pwd)" commit -m x'; do
  from "$c"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL C4: '$c' was not judged in the session's repository" "exit $rc" "$out"
done
# C6: quoted text naming a folder is read only for sh -c and eval: an echo of a cd adds no place
A="$EVAL_TMP/a"; mkdir -p "$A" && git -C "$A" init -q || die "the eval could not make a second repository"
rc=0; out="$(cd "$NR" && printf '%s' "{\"tool_input\":{\"command\":\"echo 'cd $R'; git -C $A commit -m x\"}}" | python3 "$H/commit-quality.py" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || die "FAIL C6: a folder in an echo was counted as a place" "exit $rc" "$out"
# E1: a commit inside quoted text is a commit, however the text is run
for c in 'bash -l -c "git commit -m x"' 'bash --login -c "git commit -m x"' 'sh -e -c "git commit -m x"' 'bash -o pipefail -c "git commit -m x"' \
         'zsh -i -c "git commit -m x"' '$SHELL -c "git commit -m x"' 'bash -c -- "git commit -m x"' 'su -c "git commit -m x"' \
         "python3 -c \"import os; os.system('git commit -m x')\""; do
  from "$c"; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL E1: '$c' hid the commit" "exit $rc" "$out"
done
# C5: a payload of any shape is answered, never a crash: nothing to judge is a pass
for pay in '[1, 2]' '{"tool_input": "git commit"}' '{"tool_input": {"command": 42}}' '"git commit"'; do
  rc=0; out="$(cd "$R" && printf '%s' "$pay" | python3 "$H/commit-quality.py" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || die "FAIL C5: the payload $pay made the hook exit $rc" "$out"
done
# C5b: should the hook itself break, a command that commits is refused and any other is let be
mkdir -p "$EVAL_TMP/brk/core" "$EVAL_TMP/brk/bin" && cp -R "$H" "$EVAL_TMP/brk/core/hooks" && cp "$PIPELINE_ROOT/bin/sanitize" "$EVAL_TMP/brk/bin/" \
  && perl -0pi -e 's/\ndef commit_candidates\(cmd, cwd\):\n/\ndef commit_candidates(cmd, cwd):\n    raise RuntimeError("planted")\n/' "$EVAL_TMP/brk/core/hooks/commit-quality.py" \
  && ! cmp -s "$H/commit-quality.py" "$EVAL_TMP/brk/core/hooks/commit-quality.py" || die "the eval could not plant a break"
rc=0; out="$(cd "$R" && printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | python3 "$EVAL_TMP/brk/core/hooks/commit-quality.py" 2>&1)" || rc=$?
{ [ "$rc" -eq 2 ] && has "the commit check broke (RuntimeError: planted)"; } || die "FAIL C5: a hook that broke let a commit through" "exit $rc" "$out"
rc=0; out="$(cd "$R" && printf '%s' '{"tool_input":{"command":"ls -la"}}' | python3 "$EVAL_TMP/brk/core/hooks/commit-quality.py" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || die "FAIL C5: a hook that broke refused a command that commits nothing" "exit $rc" "$out"
clear   # the session repository's staged key served C4-E1; the cases below stage their own
# L1: a commit of 20,000 files with long names is read in one listing, not one argument per file
LR="$EVAL_TMP/large"; mkdir -p "$LR" && git -C "$LR" init -q && python3 -c '
import os, sys
for i in range(20000):
    d = os.path.join(sys.argv[1], "packages/feature-%03d/src/components/generated" % (i // 100))
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "component-with-a-long-descriptive-name-%05d.ts" % i), "w").write("export const v = %d;\n" % i)' "$LR" \
  && git -C "$LR" add -A || die "the eval could not stage a large commit"
start=$SECONDS; rc=0; out="$(cd "$LR" && python3 "$H/check.py" --root "$LR" --staged --no-kb 2>&1)" || rc=$?; took=$((SECONDS - start))
{ [ "$rc" -eq 0 ] && [ "$took" -le 60 ]; } || die "FAIL L1: a 20,000-file commit gave exit $rc in ${took}s" "$(printf '%s\n' "$out" | tail -3)"
# F1: configuration and infrastructure files take the whole key list in both layers; their placeholders pass
while IFS='|' read -r f line ph; do
  mkdir -p "$(dirname "$R/$f")" && printf '%s\n' "$line" > "$R/$f" && git -C "$R" add -- "$f" || die "the eval could not stage $f"
  chk; { [ "$rc" -eq 2 ] && has "$f:1: credential-like value"; } || die "FAIL F1: acp check let a credential through in $f" "exit $rc" "$out"
  hook; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL F1: the commit hook let a credential through in $f" "exit $rc" "$out"
  printf '%s\n' "$ph" > "$R/$f" && git -C "$R" add -- "$f"
  chk; [ "$rc" -eq 0 ] || die "FAIL F1: acp check refused a placeholder in $f" "exit $rc" "$out"
  hook; [ "$rc" -eq 0 ] || die "FAIL F1: the commit hook refused a placeholder in $f" "exit $rc" "$out"
  clear
done <<KINDS
.env|SECRET_KEY="$LIT"|SECRET_KEY="\${SECRET_KEY}"
.env.example|SECRET_KEY="$LIT"|SECRET_KEY=""
docker-compose.yml|      DATABASE_URL: $PG://app:$PWD8@db:5432/app|      DATABASE_URL: $PG://app:\${DB_PASS}@db:5432/app
infra/main.tf|api_key = "$LIT"|api_key = var.api_key
infra/prod.tfvars|api_key = "$LIT"|api_key = ""
infra/vault.hcl|secret_key = "$LIT"|secret_key = "\${SECRET}"
nginx/app.conf|secret_key = "$LIT"|secret_key = ""
config.xml|<setting api_key="$LIT"/>|<setting api_key=""/>
.npmrc|_authToken="$LIT"|_authToken=\${NPM_TOKEN}
app.properties|db.password="$LIT"|db.password=\${DB_PASSWORD}
Dockerfile|ENV SECRET_KEY="$LIT"|ENV SECRET_KEY=""
Makefile|SECRET_KEY = "$LIT"|SECRET_KEY = \$(SECRET_KEY)
src/App.vue|const apiKey = "$LIT";|const apiKey = import.meta.env.VITE_API_KEY;
.envrc|export SECRET_KEY="$LIT"|export SECRET_KEY="\${SECRET_KEY:-}"
deploy/setup.ps1|\$SecretKey = "$LIT"|\$SecretKey = \$env:SECRET_KEY
Jenkinsfile|    SECRET_KEY = "$LIT"|    SECRET_KEY = credentials('secret-key')
KINDS
# F2: prose takes the vendor rows only: an assignment written in a note passes both layers
for f in notes.txt guide.rst CHANGELOG.md; do
  printf 'SECRET_KEY="%s"\n' "$LIT" > "$R/$f" && git -C "$R" add -- "$f"
  chk; [ "$rc" -eq 0 ] || die "FAIL F2: acp check judged prose in $f with the whole list" "exit $rc" "$out"
  hook; [ "$rc" -eq 0 ] || die "FAIL F2: the commit hook judged prose in $f with the whole list" "exit $rc" "$out"
  clear
done
# B9: a file git calls binary only by .gitattributes is still read by the commit hook
printf '*.cfg binary\n' > "$R/.gitattributes" && printf 'token = %s\n' "$GHP" > "$R/secrets.cfg" && git -C "$R" add .gitattributes secrets.cfg
hook; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL B9: a binary attribute hid a key from the commit hook" "exit $rc" "$out"
chk; [ "$rc" -eq 2 ] || die "FAIL B9: a binary attribute hid a key from acp check" "exit $rc" "$out"
clear
# S1, S2: run from a subfolder, acp check and the commit hook read the staged files named from the top
mkdir -p "$R/app" && printf 'const k = "%s";\n' "$ANT" > "$R/app/k.ts" && git -C "$R" add app/k.ts
rc=0; out="$(cd "$R/app" && python3 "$H/check.py" --root "$R/app" --staged 2>&1)" || rc=$?
{ [ "$rc" -eq 2 ] && has "app/k.ts:1: credential-like value"; } || die "FAIL S1: acp check run from a subfolder did not read the staged file" "exit $rc" "$out"
clear
mkdir -p "$R/app" && printf '*.cfg binary\n' > "$R/.gitattributes" && printf 'token = %s\n' "$GHP" > "$R/app/secrets.cfg" && git -C "$R" add .gitattributes app/secrets.cfg
rc=0; out="$(cd "$R/app" && printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | python3 "$H/commit-quality.py" 2>&1)" || rc=$?
{ [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL S2: the commit hook run from a subfolder skipped a file git calls binary" "exit $rc" "$out"
clear
# B10: removing a binary file is not a binary file the hook cannot find
printf '\0bin\n' > "$R/old.bin" && git -C "$R" add old.bin && git -C "$R" commit -q -m bin && git -C "$R" rm -q old.bin || die "the eval could not stage a removal"
hook; [ "$rc" -eq 0 ] || die "FAIL B10: a commit removing a binary file was refused" "exit $rc" "$out"
git -C "$R" commit -q -m gone || die "the eval could not commit the removal"
# B11, B12: a binary file replaced by a link, or by a submodule, holds no file content to read: passes
printf '\0bin\n' > "$R/was.bin" && git -C "$R" add was.bin && git -C "$R" commit -q -m bin && rm "$R/was.bin" && ln -s target "$R/was.bin" && git -C "$R" add was.bin \
  || die "the eval could not replace a binary file by a link"
hook; [ "$rc" -eq 0 ] || die "FAIL B11: a binary file replaced by a link was refused" "exit $rc" "$out"
git -C "$R" commit -q -m link || die "the eval could not commit the link"
printf '\0bin\n' > "$R/sub.bin" && git -C "$R" add sub.bin && git -C "$R" commit -q -m bin2 && git -C "$R" rm -q --cached sub.bin && rm "$R/sub.bin" \
  && git -C "$R" update-index --add --cacheinfo "160000,$(git -C "$R" rev-parse HEAD),sub.bin" || die "the eval could not replace a binary file by a submodule"
hook; [ "$rc" -eq 0 ] || die "FAIL B12: a binary file replaced by a submodule was refused" "exit $rc" "$out"
git -C "$R" commit -q -m sub || die "the eval could not commit the submodule"
# U16: UTF-16 text, which has NULs, is decoded by its byte-order mark and read
python3 -c 'import sys; open(sys.argv[1], "wb").write(("token = %s\n" % sys.argv[2]).encode("utf-16"))' "$R/notes16.txt" "$GHP" && git -C "$R" add notes16.txt
chk; [ "$rc" -eq 2 ] || die "FAIL U16: acp check took UTF-16 text for binary" "exit $rc" "$out"
hook; { [ "$rc" -eq 2 ] && has "credential-like values"; } || die "FAIL U16: the commit hook took UTF-16 text for binary" "exit $rc" "$out"
clear
echo "check-staged-content: all checks passed"
exit 0
