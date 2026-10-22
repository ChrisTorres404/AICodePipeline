#!/usr/bin/env bash
# The two-folder layout: new-project --pipeline-dir/--code-dir makes one repository holding the pipeline folder and
# the code folder side by side; acp layout is the one writer of that layout's settings; install checks the repository
# and then the config, and refuses anything unusual, writing nothing; a default install is as before plus a VERSION.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
P="$PIPELINE_ROOT"; G() { git -c user.name=t -c user.email=t@example.com "$@"; }
listing() { find . -path ./.git -prune -o -print | LC_ALL=C sort; }
locs='^export (PIPELINE_ROOT|WORKSPACE_DIR|DOCS_DIR|WORKORDERS_DIR|BUGS_DIR|TESTING_DIR|KNOWLEDGE_DIR|SESSIONS_DIR|CODE_DIR|PLAYBOOKS_DIR)='
want="$(printf '%s\n' 'PIPELINE_ROOT="acp/.aicodepipeline"' 'WORKSPACE_DIR="acp/Workspace"' 'DOCS_DIR="acp/Workspace/Docs"' \
  'WORKORDERS_DIR="acp/Workspace/Docs/WorkOrders"' 'BUGS_DIR="acp/Workspace/Docs/Bugs"' 'TESTING_DIR="acp/Workspace/Testing"' \
  'KNOWLEDGE_DIR="acp/Workspace/Docs/KnowledgeBase"' 'SESSIONS_DIR="acp/Workspace/Sessions"' 'CODE_DIR="app"' 'PLAYBOOKS_DIR="acp/playbooks"')"
got_locs() { grep -E "$locs" "$1" | sed -E 's/^export //; s/"[[:space:]]+#.*$/"/'; }
ver="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$P/bin/acp" | head -1)"
# L1: new-project --pipeline-dir acp --code-dir app makes the layout: the top holds only the tool wiring, the config,
# acp/ and app/; the config names the layout (ten locations); the work, the playbooks, the hooks and the version are under acp/
"$P/bin/new-project" pm --name Pm --pipeline-dir acp --code-dir app >np.log 2>&1 || { echo "FAIL L1: new-project --pipeline-dir acp --code-dir app did not make the two-folder layout"; tail -3 np.log; exit 1; }
cd pm || exit 1
top="$(ls -A | LC_ALL=C sort | tr '\n' ' ')"
{ [ "$top" = ".claude .git .gitignore AGENTS.md CLAUDE.md acp app pipeline.config.sh " ] && [ "$(got_locs pipeline.config.sh)" = "$want" ] \
  && [ "$(cat acp/.aicodepipeline/VERSION)" = "$ver" ] && [ -f app/.gitkeep ] && ls -d acp/Workspace/Docs/WorkOrders/WO-0001-* >/dev/null 2>&1 \
  && [ -f acp/playbooks/README.md ] && [ ! -e acp/.aicodepipeline/playbooks ] \
  && grep -qF '/acp/.aicodepipeline/core/hooks/run-hook.sh' .claude/settings.json \
  && grep -qF '/acp/.aicodepipeline/core/hooks/wo-reference.py' .git/hooks/commit-msg && [ -z "$(git status --porcelain)" ] \
  && grep -qxF '*.log' .gitignore && grep -qxF '.acp-migration/' .gitignore; } \
  || { echo "FAIL L1: new-project --pipeline-dir acp --code-dir app did not make the two-folder layout"; echo "  top: $top"; exit 1; }
# L2: the drivers work in it unchanged: a work order is made under acp/, its evidence covers app/ only, promote writes acp/playbooks
W=acp/.aicodepipeline/bin/wo; n="$("$W" new First --size small --area backend | grep -o 'WO-[0-9]*' | head -1 | cut -c4-)"
echo 'print(1)' > app/main.py; G add -A && G commit -qm code >/dev/null 2>&1
a="$("$W" fingerprint)"; echo x > notes.txt; b="$("$W" fingerprint)"; rm -f notes.txt
printf '#!/usr/bin/env bash\nexit 0\n' > acp/Workspace/Testing/suites/ok.sh; "$W" verify "$n" --run acp/Workspace/Testing/suites/ok.sh >/dev/null 2>&1
"$W" promote "$n" --allow-unsanitized --allow-placeholders >/dev/null 2>&1
{ [ -n "$n" ] && [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" = "$("$W" fingerprint app)" ] && ls -d acp/playbooks/pm/workorders/WO-"$n"-* >/dev/null 2>&1 \
  && grep -qF -- "- **Commit:** $(git rev-parse HEAD)" acp/Workspace/Docs/WorkOrders/WO-"$n"-*/WO-"$n"-VERIFICATION.md; } \
  || { echo "FAIL L2: the drivers did not work in the two-folder layout"; exit 1; }
# L3: a reinstall with the same flags keeps the project as it is (the config and the work untouched)
cp pipeline.config.sh ../cfg.before; "$P/bin/install.sh" "$PWD" --pipeline-dir acp --code-dir app >/dev/null 2>&1 \
  && cmp -s pipeline.config.sh ../cfg.before && [ -z "$(git status --porcelain -- app pipeline.config.sh .gitignore)" ] \
  || { echo "FAIL L3: a reinstall in the two-folder layout changed the project"; exit 1; }
cd "$EVAL_TMP" || exit 1
# a single-folder project with a code folder and no install yet, as a plain repository looks before it takes the layout
mk() { rm -rf "${EVAL_TMP:?}/$1"; mkdir -p "$1/app" && cd "$1" && echo 'print(1)' > app/main.py && cp "$P/pipeline.config.example.sh" pipeline.config.sh \
  && printf '*.log\n.acp-migration/\n' > .gitignore && git init -q && G add -A && G commit -qm base && cd "$EVAL_TMP"; }
# L4: install with the flags refuses a config that does not state the layout, naming what differs, and writes nothing
mk single; cd single; before="$(listing)"
out="$("$P/bin/install.sh" "$PWD" --pipeline-dir acp --code-dir app 2>&1)" && { echo "FAIL L4: install accepted a config that does not state the layout"; exit 1; }
{ printf '%s\n' "$out" | grep -qF 'pipeline.config.sh does not state the acp/ + app/ layout' && printf '%s\n' "$out" | grep -qF 'PIPELINE_ROOT' \
  && printf '%s\n' "$out" | grep -qF 'nothing was written' && [ "$(listing)" = "$before" ]; } \
  || { echo "FAIL L4: install with a mismatched config did not refuse cleanly"; printf '%s\n' "$out" | tail -2; exit 1; }
# L5: acp layout --check says the config can be set and writes nothing; acp layout converts it (the one writer; an older
# config gains CODE_DIR and PLAYBOOKS_DIR), twice is a no-op, and then install with the flags makes the layout
grep -v '^export CODE_DIR=' pipeline.config.sh > ../c && mv ../c pipeline.config.sh; cp pipeline.config.sh ../c0
{ "$P/bin/acp" layout --check --pipeline-dir acp --code-dir app 2>&1 | grep -F 'can be set for the acp/ + app/ layout (nothing written)' >/dev/null \
  && cmp -s pipeline.config.sh ../c0; } || { echo "FAIL L5: acp layout --check wrote the config or did not say it can be set"; exit 1; }
"$P/bin/acp" layout --pipeline-dir acp --code-dir app >/dev/null 2>&1; cp pipeline.config.sh ../c1
"$P/bin/acp" layout --pipeline-dir acp --code-dir app 2>&1 | grep -qF 'already names the acp/ + app/ layout' || { echo "FAIL L5: acp layout did not convert the config once and then stay"; exit 1; }
{ [ "$(got_locs pipeline.config.sh)" = "$want" ] && cmp -s pipeline.config.sh ../c1 \
  && "$P/bin/install.sh" "$PWD" --pipeline-dir acp --code-dir app >/dev/null 2>&1 && [ -f acp/.aicodepipeline/VERSION ] && [ -f acp/playbooks/README.md ] \
  && [ ! -e .aicodepipeline ] && [ ! -e Workspace ]; } \
  || { echo "FAIL L5: acp layout did not convert the config once and then stay"; exit 1; }
cd "$EVAL_TMP"
# L6: install refuses, writing nothing, a repository or flags it cannot use with certainty
lay() { mk "$1"; ( cd "$1" && "$P/bin/acp" layout --pipeline-dir acp --code-dir app >/dev/null 2>&1 && G add -A && G commit -qm layout ); }
refuse() { # <folder> <message part> [extra install args...]: install refuses with the message and the folder is unchanged
  local d="$1" msg="$2" before out; shift 2; before="$(cd "$d" && listing)"
  out="$("$P/bin/install.sh" "$EVAL_TMP/$d" "$@" 2>&1)" && return 1
  printf '%s\n' "$out" | grep -qF -- "$msg" && [ "$(cd "$d" && listing)" = "$before" ]
}
lay nocode; rm -rf nocode/app;                 refuse nocode 'app/ must be a folder in the repository' --pipeline-dir acp --code-dir app || { echo "FAIL L6: install did not refuse a missing code folder"; exit 1; }
lay linked; mv linked/app linked/real && ln -s real linked/app; refuse linked 'app/ must be a folder in the repository' --pipeline-dir acp --code-dir app || { echo "FAIL L6: install did not refuse a code folder that is a link"; exit 1; }
lay second; mkdir second/.aicodepipeline;      refuse second '.aicodepipeline at the top of the repository' --pipeline-dir acp --code-dir app || { echo "FAIL L6: install did not refuse a second ACP copy at the top"; exit 1; }
lay rootws; mkdir rootws/Workspace;            refuse rootws 'Workspace at the top of the repository' --pipeline-dir acp --code-dir app || { echo "FAIL L6: install did not refuse a workspace at the top"; exit 1; }
lay incode; : > incode/app/pipeline.config.sh; refuse incode 'app/pipeline.config.sh: pipeline files do not belong in the code folder' --pipeline-dir acp --code-dir app || { echo "FAIL L6: install did not refuse pipeline files in the code folder"; exit 1; }
lay inacp; mkdir inacp/acp; : > inacp/acp/pipeline.config.sh; refuse inacp 'acp/pipeline.config.sh: the config lives at the top' --pipeline-dir acp --code-dir app || { echo "FAIL L6: install did not refuse a second config in the pipeline folder"; exit 1; }
lay acpfile; : > acpfile/acp;                  refuse acpfile 'acp must be a folder or absent' --pipeline-dir acp --code-dir app || { echo "FAIL L6: install did not refuse a pipeline folder that is a file"; exit 1; }
lay nolog; printf '.acp-migration/\n' > nolog/.gitignore; refuse nolog '.gitignore must hold the line  *.log' --pipeline-dir acp --code-dir app || { echo "FAIL L6: install did not refuse a .gitignore that lets logs into git"; exit 1; }
lay nomig; printf '*.log\n' > nomig/.gitignore; refuse nomig '.gitignore must hold the line  .acp-migration/' --pipeline-dir acp --code-dir app || { echo "FAIL L6: install did not refuse a .gitignore that lets the migration's records into git"; exit 1; }
lay nopb; perl -ni -e 'print unless /^export PLAYBOOKS_DIR=/' nopb/pipeline.config.sh; refuse nopb 'does not state the acp/ + app/ layout (differs: PLAYBOOKS_DIR)' --pipeline-dir acp --code-dir app || { echo "FAIL L6: install did not refuse a config without the playbooks location"; exit 1; }
mkdir -p "$EVAL_TMP/elsewhere"   # a PROJECT_ROOT that is not the project, kept inside this eval's scratch even if a check fails
lay moved; E="$EVAL_TMP/elsewhere" perl -pi -e 's{^export PROJECT_ROOT=.*}{export PROJECT_ROOT="$ENV{E}"}' moved/pipeline.config.sh
for fl in "--pipeline-dir acp --code-dir app" ""; do
  # shellcheck disable=SC2086
  refuse moved "PROJECT_ROOT to $EVAL_TMP/elsewhere, not this project" $fl || { echo "FAIL L6: install did not refuse a config whose PROJECT_ROOT is elsewhere${fl:+ (with the flags)}"; exit 1; }
done
[ -z "$(ls -A "$EVAL_TMP/elsewhere")" ] || { echo "FAIL L6: install wrote under a PROJECT_ROOT that is not the project"; exit 1; }
lay rel; perl -pi -e 's{^export PROJECT_ROOT=.*}{export PROJECT_ROOT="."}' rel/pipeline.config.sh; before="$(cd rel && listing)"   # "." is the project only from inside it
out="$(cd rel && "$P/bin/install.sh" "$PWD" 2>&1)" && { echo "FAIL L6: install accepted a relative PROJECT_ROOT"; exit 1; }
{ printf '%s\n' "$out" | grep -qF 'sets PROJECT_ROOT to ., not this project' && [ "$(cd rel && listing)" = "$before" ]; } || { echo "FAIL L6: install did not refuse a relative PROJECT_ROOT cleanly"; exit 1; }
lay dbl; D="/$(cd dbl && pwd -P)" perl -pi -e 's{^export PROJECT_ROOT=.*}{export PROJECT_ROOT="$ENV{D}"}' dbl/pipeline.config.sh   # //abs: the same folder
{ "$P/bin/install.sh" "$EVAL_TMP/dbl" --pipeline-dir acp --code-dir app >/dev/null 2>&1 && [ -f dbl/acp/.aicodepipeline/VERSION ]; } || { echo "FAIL L6: install refused a PROJECT_ROOT that names the project with a leading //"; exit 1; }
one='each one folder name'; same='must differ, also ignoring case'; used='a name the layout or the tools use'
for v in "--pipeline-dir acp|$one" "--code-dir app|$one" "--pipeline-dir ../x --code-dir app|$one" "--pipeline-dir acp --code-dir .app|$one" \
         "--pipeline-dir a/b --code-dir app|$one" "--pipeline-dir app --code-dir app|$same" "--pipeline-dir acp --code-dir ACP|$same" \
         "--pipeline-dir acp --code-dir Workspace|$used" "--pipeline-dir workspace --code-dir app|$used" "--pipeline-dir acp --code-dir AGENTS.md|$used" \
         "--pipeline-dir CLAUDE.md --code-dir app|$used" "--pipeline-dir acp --code-dir Pipeline.Config.sh|$used"; do
  args="${v%|*}"
  # shellcheck disable=SC2086
  refuse nolog "${v##*|}" $args || { echo "FAIL L6: install did not refuse the flags: $args"; exit 1; }
done
out="$("$P/bin/install.sh" "$EVAL_TMP/nolog" --pipeline-dir 2>&1)" && { echo "FAIL L6: install accepted a flag with no value"; exit 1; }
printf '%s\n' "$out" | grep -qF 'usage:' || { echo "FAIL L6: install did not give its usage for a flag with no value"; exit 1; }
# L7: acp layout refuses a config it cannot read with certainty, and changes nothing; --check refuses the same
mk bad; cd bad; cp pipeline.config.sh ../orig
lr() { local msg="$1" out o2; out="$("$P/bin/acp" layout --pipeline-dir acp --code-dir app 2>&1)" && return 1; printf '%s\n' "$out" | grep -qF -- "$msg" || return 1
  o2="$("$P/bin/acp" layout --check --pipeline-dir acp --code-dir app 2>&1)" && return 1; printf '%s\n' "$o2" | grep -qF -- "$msg"; }
case7() { cp ../orig pipeline.config.sh; "$@"; cp pipeline.config.sh ../edited; }
case7 sh -c "printf 'WORKORDERS_DIR=elsewhere\n' >> pipeline.config.sh"; { lr 'WORKORDERS_DIR must be set exactly once' && cmp -s pipeline.config.sh ../edited; } || { echo "FAIL L7: acp layout did not refuse a second definition"; exit 1; }
case7 sh -c "printf 'export NOTES=\"\$WORKORDERS_DIR/notes\"\n' >> pipeline.config.sh"; { lr 'WORKORDERS_DIR must be set exactly once' && cmp -s pipeline.config.sh ../edited; } || { echo "FAIL L7: acp layout did not refuse a location used elsewhere"; exit 1; }
case7 perl -pi -e 's/^export TESTING_DIR=.*/export TESTING_DIR="\$HOME\/t"/' pipeline.config.sh; { lr 'TESTING_DIR must be set exactly once' && cmp -s pipeline.config.sh ../edited; } || { echo "FAIL L7: acp layout did not refuse a value that is not plain"; exit 1; }
case7 sh -c "printf '. ./more.sh\n' >> pipeline.config.sh"; { lr 'runs other code' && cmp -s pipeline.config.sh ../edited; } || { echo "FAIL L7: acp layout did not refuse a config that runs another file"; exit 1; }
case7 perl -pi -e 's/\n/\r\n/' pipeline.config.sh; { lr 'carriage return' && cmp -s pipeline.config.sh ../edited; } || { echo "FAIL L7: acp layout did not refuse CRLF line ends"; exit 1; }
case7 env E="$EVAL_TMP/elsewhere" perl -pi -e 's{^export PROJECT_ROOT=.*}{export PROJECT_ROOT="$ENV{E}"}' pipeline.config.sh; { lr 'PROJECT_ROOT must be set once' && cmp -s pipeline.config.sh ../edited; } || { echo "FAIL L7: acp layout did not refuse a PROJECT_ROOT that is not its own folder"; exit 1; }
case7 perl -pi -e 's/pwd -P\)"/pwd)"/ if /^export PROJECT_ROOT=/' pipeline.config.sh; { lr 'a config from before 1.2 says pwd' && cmp -s pipeline.config.sh ../edited; } || { echo "FAIL L7: acp layout did not say what to do with a config from before 1.2"; exit 1; }
case7 perl -ni -e 'print unless /^export KNOWLEDGE_DIR=/' pipeline.config.sh; { lr 'a config from before 1.3' && cmp -s pipeline.config.sh ../edited; } || { echo "FAIL L7: acp layout did not say what to do with a config from before 1.3"; exit 1; }
cp ../orig pipeline.config.sh
for args in "--pipeline-dir . --code-dir app" "--pipeline-dir a/b --code-dir app" "--pipeline-dir acp --code-dir ../x" "--pipeline-dir app --code-dir app" "--pipeline-dir acp" \
            "--pipeline-dir app --code-dir APP --check" "--pipeline-dir Workspace --code-dir app" "--pipeline-dir acp --code-dir claude.md" "--pipeline-dir"; do
  # shellcheck disable=SC2086
  out="$("$P/bin/acp" layout $args 2>&1)" && { echo "FAIL L7: acp layout accepted: $args"; exit 1; }
done
cmp -s pipeline.config.sh ../orig || { echo "FAIL L7: acp layout changed the config while refusing"; exit 1; }
out="$("$P/bin/acp" layout --code-dir app --pipeline-dir 2>&1)"; printf '%s\n' "$out" | grep -qF 'usage: acp layout' || { echo "FAIL L7: acp layout did not give its usage for a flag with no value"; exit 1; }
mv app ../app.kept; out="$("$P/bin/acp" layout --pipeline-dir acp --code-dir app 2>&1)" && { echo "FAIL L7: acp layout accepted a layout with no code folder"; exit 1; }
{ printf '%s\n' "$out" | grep -qF 'app/ is not a folder' && cmp -s pipeline.config.sh ../orig; } || { echo "FAIL L7: acp layout did not refuse a layout with no code folder"; exit 1; }
mv ../app.kept app
cd "$EVAL_TMP"
# L8: a default install (no flags) is as before: the single-folder layout, plus the VERSION file
mk plain; ( cd plain && "$P/bin/install.sh" "$PWD" >/dev/null 2>&1 ) && [ -f plain/.aicodepipeline/VERSION ] && [ "$(cat plain/.aicodepipeline/VERSION)" = "$ver" ] \
  && [ -d plain/Workspace/Docs/WorkOrders ] && [ -d plain/.aicodepipeline/playbooks ] && [ ! -e plain/acp ] || { echo "FAIL L8: a default install was not the single-folder layout with its VERSION"; exit 1; }
# L9: an installed single-folder project is never half-converted: acp layout refuses (pointing at acp migrate) with
# the config unchanged, --check still answers, and install with the flags refuses on the repository before the config
cd plain; G add -A >/dev/null 2>&1; G commit -qm installed >/dev/null 2>&1; cp pipeline.config.sh ../p0; before="$(listing)"
out="$("$P/bin/acp" layout --pipeline-dir acp --code-dir app 2>&1)" && { echo "FAIL L9: acp layout rewrote the config of an installed single-folder project"; exit 1; }
{ printf '%s\n' "$out" | grep -qF 'acp migrate' && cmp -s pipeline.config.sh ../p0 && [ "$(listing)" = "$before" ] \
  && "$P/bin/acp" layout --check --pipeline-dir acp --code-dir app >/dev/null 2>&1 && cmp -s pipeline.config.sh ../p0; } \
  || { echo "FAIL L9: acp layout rewrote the config of an installed single-folder project"; exit 1; }
out="$("$P/bin/install.sh" "$PWD" --pipeline-dir acp --code-dir app 2>&1)" && { echo "FAIL L9: install accepted an installed single-folder project"; exit 1; }
{ printf '%s\n' "$out" | grep -qF 'acp migrate' && ! printf '%s\n' "$out" | grep -qF 'does not state' && [ "$(listing)" = "$before" ]; } \
  || { echo "FAIL L9: install did not refuse on the repository first"; exit 1; }
# the same project with its config pointing at the new place but its pipeline copy still at the old one: never a first install beside it
perl -pi -e 's{^export PIPELINE_ROOT=.*}{export PIPELINE_ROOT="acp/.aicodepipeline"}' pipeline.config.sh
out="$("$P/bin/install.sh" "$PWD" 2>&1)" && { echo "FAIL L9: install accepted a project whose pipeline copy is not the configured one"; exit 1; }
{ printf '%s\n' "$out" | grep -qF 'is a pipeline copy, but pipeline.config.sh names acp/.aicodepipeline' && [ "$(listing)" = "$before" ]; } \
  || { echo "FAIL L9: install did not refuse a pipeline copy that is not the configured one cleanly"; exit 1; }
cp ../p0 pipeline.config.sh
# anything else at that name that is not the configured pipeline (an empty folder, a link to nothing) is plainly in the way
cd "$EVAL_TMP"; for k in empty dangling; do
  lay "stray-$k"; if [ "$k" = empty ]; then mkdir "stray-$k/.aicodepipeline"; else ln -s /nonexistent/x "stray-$k/.aicodepipeline"; fi
  refuse "stray-$k" '.aicodepipeline at the top of the project is in the way' || { echo "FAIL L9: install did not refuse a stray .aicodepipeline ($k) cleanly"; exit 1; }
done
exit 0
