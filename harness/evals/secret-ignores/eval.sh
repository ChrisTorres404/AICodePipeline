#!/usr/bin/env bash
# Projects ignore secret files: a new project's .gitignore keeps .env files, keys and certificates out of git
# (and lets their examples and public keys in); acp doctor warns when a project's own .gitignore does not,
# printing the lines to add, and never writes the file; the pipeline's own repository ignores the owner's
# private folders by a generic rule.
set -uo pipefail
. "$(dirname "$0")/../_lib/verification.sh"
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
export HOME="$EVAL_TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$EVAL_TMP"; mkdir -p "$HOME"
git config --global user.name t && git config --global user.email t@example.com || die "the eval could not set a git identity"
has() { case "$out" in *"$1"*) return 0;; esac; return 1; }
A="$PIPELINE_ROOT/bin/acp"
# ignored by the project's own .gitignore files: no global excludes file, no info/exclude
ign() { git -C "$1" -c core.excludesFile=/dev/null check-ignore -q --no-index -- "$2"; }
SECRETS=".env .env.production x.pem x.key x.p12 x.pfx id_rsa id_ed25519 id_ecdsa"
KEPT=".env.example .env.sample .env.template id_rsa.pub id_ed25519.pub id_ecdsa.pub"
JUNK=".venv/x venv/x coverage/x .pytest_cache/x x.tmp"
OLD='node_modules/
__pycache__/
dist/
build/
.env
.env.local
*.log
.DS_Store
*.swp
*~
\#*#'
doc() { rc=0; out="$("$A" doctor "$1" 2>&1)" || rc=$?; }
secret_line() { printf '%s\n' "$out" | grep 'secret files:'; }

# T1, T2: a new project, in the default layout and in acp/ + app/, ignores each secret file and keeps each example
# and public key; the template's earlier lines are kept, in their order
"$PIPELINE_ROOT/bin/new-project" p --name P >/dev/null 2>&1 || die "the eval could not make a project"
"$PIPELINE_ROOT/bin/new-project" q --name Q --pipeline-dir acp --code-dir app >/dev/null 2>&1 || die "the eval could not make an acp/ project"
for pr in p q; do
  for f in $SECRETS $JUNK; do ign "$pr" "$f" || die "FAIL T1: a new project ($pr) does not ignore $f"; done
  for f in $KEPT; do ! ign "$pr" "$f" || die "FAIL T1: a new project ($pr) ignores $f, which belongs in git"; done
  [ "$(head -11 "$pr/.gitignore")" = "$OLD" ] || die "FAIL T1: the template's earlier lines are not kept in their order ($pr)" "$(head -11 "$pr/.gitignore")"
done
for f in .env.production x.pem id_rsa; do ign q "app/$f" || die "FAIL T2: an acp/ project does not ignore app/$f"; done
ign q app/.env.example && die "FAIL T2: an acp/ project ignores app/.env.example"
# D1: on a new project acp doctor says the secret files are kept out, and warns of nothing about them
for pr in p q; do
  doc "$EVAL_TMP/$pr"; secret_line | grep -q PASS || die "FAIL D1: acp doctor did not pass a new project's .gitignore ($pr)" "$(secret_line)"
done

# D2: a project made before (the old template) is warned of, with the lines to add; its .gitignore is not touched
printf '%s\n' "$OLD" > p/.gitignore && cp p/.gitignore "$EVAL_TMP/old.keep" || die "the eval could not write the old template"
doc "$EVAL_TMP/p"
{ secret_line | grep -q WARN && has ".env.production" && has "x.pem" && has "id_rsa" && has "acp doctor --gitignore-hint"; } \
  || die "FAIL D2: acp doctor did not warn of an old project's .gitignore, naming what gets in" "$(secret_line)"
for l in '.env.*' '!.env.example' '*.pem' '*.key' '*.p12' '*.pfx' 'id_rsa*' 'id_ed25519*' 'id_ecdsa*' '!*.pub'; do
  printf '%s\n' "$out" | grep -qxF "          $l" || die "FAIL D2: acp doctor's warning does not print the line $l" "$out"
done
cmp -s p/.gitignore "$EVAL_TMP/old.keep" || die "FAIL D2: acp doctor changed the project's .gitignore"
# D3: the hint prints exactly the lines; with them added there is no warning, and examples and public keys stay in git
rc=0; hint="$("$A" doctor --gitignore-hint "$EVAL_TMP/p" 2>&1)" || rc=$?
{ [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$hint" | head -1)" = '.env.*' ] && [ "$(printf '%s\n' "$hint" | tail -1)" = '!*.pub' ]; } \
  || die "FAIL D3: acp doctor --gitignore-hint did not print the lines, the negation last" "exit $rc" "$hint"
printf '%s\n' "$hint" >> p/.gitignore
doc "$EVAL_TMP/p"; secret_line | grep -q PASS || die "FAIL D3: with the hint's lines added, acp doctor still warned" "$(secret_line)"
[ -z "$("$A" doctor --gitignore-hint "$EVAL_TMP/p")" ] || die "FAIL D3: the hint still printed lines once they were added"
for f in $SECRETS; do ign p "$f" || die "FAIL D3: with the hint's lines added, $f is not ignored"; done
for f in $KEPT; do ! ign p "$f" || die "FAIL D3: with the hint's lines added, $f is ignored"; done
# D4: what a clone does not carry does not count, each on its own (git reads info/exclude before a global
# excludes file, so with both the second would never be asked): .git/info/exclude, then a global excludes file
cp "$EVAL_TMP/old.keep" p/.gitignore && cp p/.git/info/exclude "$EVAL_TMP/exclude.keep" \
  && printf '.env.*\n*.pem\n*.key\n*.p12\n*.pfx\nid_*\n' >> p/.git/info/exclude || die "the eval could not write .git/info/exclude"
doc "$EVAL_TMP/p"; secret_line | grep -q WARN || die "FAIL D4: .git/info/exclude was taken for the project's .gitignore" "$(secret_line)"
cp "$EVAL_TMP/exclude.keep" p/.git/info/exclude && printf '.env.*\n*.pem\n*.key\n*.p12\n*.pfx\nid_*\n' > "$HOME/excludes" \
  && git config --global core.excludesFile "$HOME/excludes" || die "the eval could not set a global excludes file"
doc "$EVAL_TMP/p"; secret_line | grep -q WARN || die "FAIL D4: a global excludes file was taken for the project's .gitignore" "$(secret_line)"
git config --global --unset core.excludesFile
# D5: the code folder is probed too: a .gitignore there that lets keys back in is warned of
printf '!*.pem\n' > q/app/.gitignore; doc "$EVAL_TMP/q"
{ secret_line | grep -q WARN && has "app/x.pem"; } || die "FAIL D5: a code folder whose .gitignore lets keys in was not warned of" "$(secret_line)"
# D6: a repository without the pipeline's configuration gets the hint too
mkdir -p plain && git -C plain init -q && printf '.env\n' > plain/.gitignore
rc=0; hint="$("$A" doctor --gitignore-hint "$EVAL_TMP/plain" 2>&1)" || rc=$?
{ [ "$rc" -eq 0 ] && printf '%s\n' "$hint" | grep -qxF '*.pem'; } || die "FAIL D6: a repository without pipeline.config.sh got no hint" "exit $rc" "$hint"

# R1: the pipeline's own repository ignores the owner's private folders by one generic rule at its top
mkdir -p repo && git -C repo init -q && cp "$PIPELINE_ROOT/.gitignore" repo/.gitignore || die "the eval could not copy the pipeline's .gitignore"
{ ign repo "Private-Claude/x.md" && ign repo "Private-Anything/y" && ! ign repo "docs/Private-x/y"; } \
  || die "FAIL R1: the pipeline's .gitignore does not keep its top-level Private-* folders out of git (and only those)"
grep -qE '^/?Private-[A-Za-z]' "$PIPELINE_ROOT/.gitignore" && die "FAIL R1: the pipeline's .gitignore names a private folder by name"
echo "secret-ignores: all checks passed"
exit 0
