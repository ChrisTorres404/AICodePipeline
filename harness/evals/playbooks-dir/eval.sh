#!/usr/bin/env bash
# PLAYBOOKS_DIR names the project's playbooks folder, relative to PROJECT_ROOT like every *_DIR (or absolute):
# install makes it, wo promote and bug promote write into it from any folder of the project, playbook finds it on
# its own from its own install's config, read as data, doctor checks it; a value that is not a plain folder path,
# or that lies outside the pipeline's and the workspace's top folders, or reaches the code folder by any spelling
# or link, is refused; unset, the playbooks stay inside the install as before.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
G() { git -c user.name=t -c user.email=t@example.com "$@"; }
listing() { find . -path ./.git -prune -o -print | LC_ALL=C sort; }
PB=Workspace/Playbooks
mk() { # <name> [config lines...]: a project whose config sets its own CODE_DIR and PLAYBOOKS_DIR lines
  local n="$1"; shift; cd "$EVAL_TMP" && "$PIPELINE_ROOT/bin/new-project" "$n" --name P --no-git >/dev/null 2>&1 && cd "$EVAL_TMP/$n" || return 1
  grep -v -E '^export (CODE_DIR|PLAYBOOKS_DIR)=' pipeline.config.sh > ../cfg && mv ../cfg pipeline.config.sh
  for l in "$@"; do printf '%s\n' "$l" >> pipeline.config.sh; done
  mkdir -p app && echo 'print(1)' > app/main.py && printf '#!/usr/bin/env bash\necho "1 passed, 0 failed"\n' > ok.sh
  git init -q && G add -A && G commit -qm base >/dev/null 2>&1
}
order() { # verify one work order and promote it from <folder>
  local n; n="$(.aicodepipeline/bin/wo new "$1" --size small --area docs | grep -o 'WO-[0-9]*' | head -1 | cut -c4-)"
  .aicodepipeline/bin/wo verify "$n" --run ./ok.sh >/dev/null 2>&1; ( cd "$2" && "$EVAL_TMP/$3/.aicodepipeline/bin/wo" promote "$n" --allow-unsanitized --allow-placeholders >/dev/null 2>&1 ); echo "$n"
}
# P1: install makes the folder PLAYBOOKS_DIR names, relative to the project
mk p 'export CODE_DIR="app"' '# export PLAYBOOKS_DIR="old/place"  (a comment is not a setting)' "export PLAYBOOKS_DIR=\"$PB\"" && "$PIPELINE_ROOT/bin/install.sh" "$PWD" >/dev/null 2>&1
{ [ -f $PB/README.md ] && [ -f $PB/INDEX.md ]; } || { echo "FAIL P1: install did not make the playbooks folder PLAYBOOKS_DIR names"; exit 1; }
# P2: wo promote writes into it, from the root and from inside the code folder, and the fingerprint does not move
a="$(.aicodepipeline/bin/wo fingerprint)"; n1="$(order First . p)"; n2="$(order Second app p)"
{ ls -d $PB/p/workorders/WO-"$n1"-* >/dev/null 2>&1 && ls -d $PB/p/workorders/WO-"$n2"-* >/dev/null 2>&1 && [ ! -e .aicodepipeline/playbooks/p ] \
  && grep -q "WO-$n2" $PB/p/CATALOG.md \
  && [ "$(.aicodepipeline/bin/wo fingerprint)" = "$a" ]; } || { echo "FAIL P2: wo promote did not write into PLAYBOOKS_DIR from every folder"; exit 1; }
# P3: bug promote writes into it, from inside the code folder too
bn="$(.aicodepipeline/bin/bug new "A bug" | grep -o 'BUG-[0-9]*' | head -1 | cut -c5-)"; .aicodepipeline/bin/bug verify "$bn" --run ./ok.sh >/dev/null 2>&1
( cd app && ../.aicodepipeline/bin/bug promote "$bn" --allow-unsanitized >/dev/null 2>&1 )
{ ls -d $PB/p/bugs/BUG-"$bn"-* >/dev/null 2>&1 && [ ! -e app/Workspace ]; } || { echo "FAIL P3: bug promote did not write into PLAYBOOKS_DIR"; exit 1; }
# P4: playbook, run on its own from the root or the code folder, reads PLAYBOOKS_DIR from the config
{ .aicodepipeline/bin/playbook list 2>&1 | grep -qw p && ( cd app && ../.aicodepipeline/bin/playbook list 2>&1 ) | grep -qw p \
  && rm -f $PB/INDEX.md && .aicodepipeline/bin/playbook index >/dev/null 2>&1 && [ -f $PB/INDEX.md ]; } \
  || { echo "FAIL P4: playbook on its own did not read PLAYBOOKS_DIR from the config"; exit 1; }
# P5: doctor checks the folder PLAYBOOKS_DIR names
dr="$(PLAYBOOKS_DIR=/nonexistent/pb .aicodepipeline/bin/acp doctor . 2>&1)"   # it judges the config, not the shell it runs in
printf '%s\n' "$dr" | grep -F "playbooks folder present ($PB)" >/dev/null || { echo "FAIL P5: doctor did not check the folder PLAYBOOKS_DIR names"; exit 1; }
# P6: refused, with the reason, by playbook (and so by wo, bug and install): a value that is not a plain folder path;
# one outside the pipeline's and the workspace's top folders; one reaching the code folder by any spelling or link;
# an absolute spelling of the project through a link; a file or a link to nothing; any relative one when the code
# folder is the whole project. The project's own absolute spelling, ./x/ and a//b forms are the same folder.
where() { PLAYBOOKS_DIR="$1" .aicodepipeline/bin/playbook where 2>&1; }
ln -s ../app Workspace/lnk; ln -s /nonexistent/x Workspace/dang; : > Workspace/afile; ln -s "$EVAL_TMP/p" "$EVAL_TMP/plink"
mkdir -p app/books && ln -s ../app/books Workspace/pbx && ln -s "$EVAL_TMP/p/app" "$EVAL_TMP/outlink"   # links into the code folder
for v in "../x|must be a folder path" "-x|not starting with -" "a/../b|must be a folder path" "$(printf 'Workspace/a\nb')|not starting with -" \
         ".|must be a folder path" "./|must be a folder path" "Workspace/./pb|must be a folder path" \
         "Workspace/.|must be a folder path" "app/pb|must lie under .aicodepipeline/ or Workspace/" "./app/pb|must lie under" \
         "App/pb|must lie under" "other/pb|must lie under" "$EVAL_TMP/p/app/pb|lies inside the code folder (app)" "Workspace/lnk/pb|lies inside the code folder (app), through a link" \
         "Workspace/pbx|lies inside the code folder (app), through a link" "$EVAL_TMP/outlink/pb|lies inside the code folder (app), through a link" \
         "$EVAL_TMP/plink/app/pb|lies inside the code folder (app)" "$EVAL_TMP/plink/other/pb|must lie under" "Workspace/dang|is not a folder" "Workspace/afile|is not a folder" \
         "Workspace/afile/pb|is not a folder"; do
  pv="${v%|*}"; msg="${v##*|}"; out="$(where "$pv")" && { echo "FAIL P6: playbook accepted PLAYBOOKS_DIR=$pv"; exit 1; }
  printf '%s\n' "$out" | grep -qF -- "$msg" || { echo "FAIL P6: playbook refused PLAYBOOKS_DIR=$pv without saying why"; printf '%s\n' "$out" | tail -1; exit 1; }
done
pp="$(cd "$EVAL_TMP/p" && pwd -P)"
for v in "./$PB/" "$pp/$PB" "$PB//" "$EVAL_TMP/p/$PB" "$EVAL_TMP/plink/$PB" "Workspace//Playbooks" ".//$PB" "$pp//Workspace///Playbooks"; do [ "$(where "$v")" = "$pp/$PB" ] || { echo "FAIL P6: PLAYBOOKS_DIR=$v did not name $PB"; exit 1; }; done
{ [ "$(where Workspace/New)" = "$pp/Workspace/New" ] && [ ! -e Workspace/New ]; } || { echo "FAIL P6: playbook where made the folder it names"; exit 1; }
n5="$(.aicodepipeline/bin/wo new Five --size small --area docs | grep -o 'WO-[0-9]*' | head -1 | cut -c4-)"; .aicodepipeline/bin/wo verify "$n5" --run ./ok.sh >/dev/null 2>&1
setpb() { V="$1" perl -pi -e 's{^export PLAYBOOKS_DIR=.*}{export PLAYBOOKS_DIR="$ENV{V}"}' pipeline.config.sh; }   # the config's value wins over the environment's
setpb app/pb; out="$(.aicodepipeline/bin/wo promote "$n5" --allow-unsanitized --allow-placeholders 2>&1)" && { echo "FAIL P6: wo promote accepted a playbooks folder in the code folder"; exit 1; }
{ printf '%s\n' "$out" | grep -qF 'must lie under' && [ ! -e app/pb ] && [ ! -e .aicodepipeline/playbooks/p ]; } || { echo "FAIL P6: wo promote did not refuse a playbooks folder in the code folder cleanly"; exit 1; }
setpb Workspace/lnk/pb; out="$(.aicodepipeline/bin/bug promote "$bn" --allow-unsanitized 2>&1)" && { echo "FAIL P6: bug promote accepted a playbooks folder in the code folder"; exit 1; }
{ printf '%s\n' "$out" | grep -qF 'through a link' && [ ! -e app/pb ] && [ ! -e .aicodepipeline/playbooks/p ]; } || { echo "FAIL P6: bug promote did not refuse a playbooks folder in the code folder cleanly"; exit 1; }
rm -f Workspace/afile
for v in "app/pb|must lie under" "Workspace/dang|is not a folder"; do
  pv="${v%|*}"; msg="${v##*|}"; setpb "$pv"; G add -A >/dev/null 2>&1; G commit -qm "pb $pv" >/dev/null 2>&1; before="$(listing)"
  out="$("$PIPELINE_ROOT/bin/install.sh" "$PWD" 2>&1)" && { echo "FAIL P6: install accepted PLAYBOOKS_DIR=$pv"; exit 1; }
  { printf '%s\n' "$out" | grep -qF "$msg" && printf '%s\n' "$out" | grep -qF 'nothing was written' && [ "$(listing)" = "$before" ]; } \
    || { echo "FAIL P6: install did not refuse PLAYBOOKS_DIR=$pv cleanly"; exit 1; }
done
setpb "$PB"; G commit -qam restored >/dev/null 2>&1
mk q; out="$(PLAYBOOKS_DIR=$PB .aicodepipeline/bin/playbook where 2>&1)" && { echo "FAIL P6: a relative playbooks folder was accepted with the whole project as code"; exit 1; }
printf '%s\n' "$out" | grep -qF 'CODE_DIR is the whole project' || { echo "FAIL P6: a relative playbooks folder with the whole project as code was refused without saying why"; exit 1; }
printf 'export PLAYBOOKS_DIR="../out"\n' >> pipeline.config.sh; out="$(.aicodepipeline/bin/playbook list 2>&1)" && { echo "FAIL P6: playbook accepted PLAYBOOKS_DIR=../out from the config"; exit 1; }
grep -v '^export PLAYBOOKS_DIR=' pipeline.config.sh > ../cfg && mv ../cfg pipeline.config.sh; G commit -qam c >/dev/null 2>&1
# P7: an absolute PLAYBOOKS_DIR outside the project is used as it is
mkdir -p "$EVAL_TMP/abs"
n3b="$(.aicodepipeline/bin/wo new Abs2 --size small --area docs | grep -o 'WO-[0-9]*' | head -1 | cut -c4-)"; .aicodepipeline/bin/wo verify "$n3b" --run ./ok.sh >/dev/null 2>&1
PLAYBOOKS_DIR="$EVAL_TMP/abs" .aicodepipeline/bin/wo promote "$n3b" --allow-unsanitized --allow-placeholders >/dev/null 2>&1
CODE_DIR=app PLAYBOOKS_DIR="$EVAL_TMP/abs" "$PIPELINE_ROOT/bin/install.sh" "$PWD" >/dev/null 2>&1
{ ls -d "$EVAL_TMP"/abs/p/workorders/WO-"$n3b"-* >/dev/null 2>&1 && [ -f "$EVAL_TMP/abs/README.md" ]; } || { echo "FAIL P7: an absolute PLAYBOOKS_DIR was not used as it is"; exit 1; }
# P8: unset, the playbooks stay inside the install, as before
n4="$(order Default . q)"; dr="$(.aicodepipeline/bin/acp doctor . 2>&1)"; wcat=""; grep -q "WO-$n4" .aicodepipeline/playbooks/p/CATALOG.md 2>/dev/null && wcat=1
qb="$(.aicodepipeline/bin/bug new "Default bug" | grep -o 'BUG-[0-9]*' | head -1 | cut -c5-)"; .aicodepipeline/bin/bug verify "$qb" --run ./ok.sh >/dev/null 2>&1
.aicodepipeline/bin/bug promote "$qb" --allow-unsanitized >/dev/null 2>&1; qrc=$?
{ ls -d .aicodepipeline/playbooks/p/workorders/WO-"$n4"-* >/dev/null 2>&1 && [ ! -e $PB ] && [ -n "$wcat" ] \
  && [ "$qrc" -eq 0 ] && grep -q "BUG-$qb" .aicodepipeline/playbooks/p/CATALOG.md \
  && printf '%s\n' "$dr" | grep -F 'playbooks folder present (.aicodepipeline/playbooks)' >/dev/null; } \
  || { echo "FAIL P8: unset, the playbooks did not stay inside the install"; exit 1; }
# P9: playbook uses only its own install's config, read as data: a config above the folder it runs from is never
# run or used, nor one above the install whose PIPELINE_ROOT is another folder
mkdir -p "$EVAL_TMP/foreign/sub" "$EVAL_TMP/r/inst/bin"
printf ': > "%s/ran"\nexport PIPELINE_ROOT="x"\nexport PLAYBOOKS_DIR="%s/foreign-pb"\n' "$EVAL_TMP" "$EVAL_TMP" > "$EVAL_TMP/foreign/pipeline.config.sh"
rm -f "$EVAL_TMP/p/$PB/INDEX.md"; ( cd "$EVAL_TMP/foreign/sub" && "$EVAL_TMP/p/.aicodepipeline/bin/playbook" index >/dev/null 2>&1 )
cp "$PIPELINE_ROOT/bin/playbook" "$EVAL_TMP/r/inst/bin/"; printf 'export PIPELINE_ROOT="other"\nexport CODE_DIR="app"\nexport PLAYBOOKS_DIR="other/pb"\n' > "$EVAL_TMP/r/pipeline.config.sh"
ri="$(cd "$EVAL_TMP/r/inst" && pwd -P)"
{ [ ! -e "$EVAL_TMP/ran" ] && [ ! -e "$EVAL_TMP/foreign-pb" ] && [ -f "$EVAL_TMP/p/$PB/INDEX.md" ] \
  && [ "$("$EVAL_TMP/r/inst/bin/playbook" where 2>&1)" = "$ri/playbooks" ] \
  && case "$(PLAYBOOKS_DIR=other/pb "$EVAL_TMP/r/inst/bin/playbook" where 2>&1)" in *'no pipeline.config.sh names this install'*) true;; *) false;; esac; } \
  || { echo "FAIL P9: playbook ran or used a config that is not its own install's"; exit 1; }
# P10: doctor reads PLAYBOOKS_DIR under $PROJECT_ROOT as the drivers do, and any other $ form is not checked, never a failure
cd "$EVAL_TMP/p" || exit 1
perl -pi -e 's{^export PLAYBOOKS_DIR=.*}{export PLAYBOOKS_DIR="\$PROJECT_ROOT/Workspace/Playbooks"}' pipeline.config.sh
dr="$(.aicodepipeline/bin/acp doctor . 2>&1)"; printf '%s\n' "$dr" | grep -F "playbooks folder present ($PB)" >/dev/null || { echo "FAIL P10: doctor did not read PLAYBOOKS_DIR under \$PROJECT_ROOT"; exit 1; }
perl -pi -e 's{^export PLAYBOOKS_DIR=.*}{export PLAYBOOKS_DIR="\$\{PROJECT_ROOT\}/Workspace/Playbooks"}' pipeline.config.sh
dr="$(.aicodepipeline/bin/acp doctor . 2>&1)"; printf '%s\n' "$dr" | grep -F "playbooks folder present ($PB)" >/dev/null || { echo "FAIL P10: doctor did not read PLAYBOOKS_DIR under \${PROJECT_ROOT}"; exit 1; }
cp pipeline.config.sh ../cfg.kept
for form in 's{^export PLAYBOOKS_DIR=.*}{export PLAYBOOKS_DIR="\$\{HOME\}/pb"}' 's{^(export PLAYBOOKS_DIR=.*)$}{$1\nPLAYBOOKS_DIR="other/pb"}'; do
  cp ../cfg.kept pipeline.config.sh; perl -pi -e "$form" pipeline.config.sh; dr="$(.aicodepipeline/bin/acp doctor . 2>&1)"
  { printf '%s\n' "$dr" | grep -F 'the playbooks folder is not checked' >/dev/null && ! printf '%s\n' "$dr" | grep -F 'no playbooks folder' >/dev/null; } \
    || { echo "FAIL P10: doctor did not leave a PLAYBOOKS_DIR it cannot read as data unchecked"; exit 1; }
done
exit 0
