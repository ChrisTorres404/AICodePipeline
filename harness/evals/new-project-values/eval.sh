#!/usr/bin/env bash
# new-project-values: new-project checks every value before it makes anything: a name holding a quote, backtick,
# dollar, backslash, slash, bar or control character is refused (the name is written into files run as
# shell), and the domain, levels, sets and playbooks take only what they name.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
N="$PIPELINE_ROOT/bin/new-project"
cfgval() { ( set +u; . "$1/pipeline.config.sh" >/dev/null 2>&1; eval "printf '%s' \"\${$2-}\"" ); }
nothing_ran() { [ -z "$(find . -name 'PWNED*' -print -quit)" ]; }
# Q1: a folder whose name holds shell code is refused, nothing runs, and the folder new-project made is removed
evil='x$(touch PWNED)`touch PWNED2`\$(touch PWNED3)y'
out="$("$N" "$evil" --no-git 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && nothing_ran && [ ! -e "$evil" ]; } \
  || { echo "FAIL Q1: new-project ran a folder name as code, or did not refuse it"; echo "  exit $rc"; exit 1; }
printf '%s\n' "$out" | grep -qF "quote, backtick, dollar, backslash, slash or bar" || { echo "FAIL Q1: a refused name did not say why"; exit 1; }
# Q2: each such character in --name is refused before anything is made; other punctuation is kept exactly
for c in '"' "'" '`' '$' '\' '/' '|'; do
  out="$("$N" q2 --name "a${c}b" --no-git 2>&1)" && { echo "FAIL Q2: new-project took a name holding a refused character"; echo "  $c"; exit 1; }
  [ ! -e q2 ] && nothing_ran || { echo "FAIL Q2: a refused --name left a folder"; echo "  $c"; exit 1; }
done
# a refused byte hidden inside a multibyte character of a legacy locale is still refused
sj="$(printf 'Gross \303\237`touch PWNED5 \303\237` x')"
out="$(LC_ALL=ja_JP.SJIS "$N" q2 --name "$sj" --no-git 2>&1)" && { echo "FAIL Q2: new-project took a name hiding a backtick in a multibyte character"; exit 1; }
[ ! -e q2 ] && nothing_ran || { echo "FAIL Q2: a refused multibyte name left a folder or ran"; exit 1; }
for nm0 in '!!' '*'; do
  out="$("$N" q2 --name "$nm0" --no-git 2>&1)" && { echo "FAIL Q2: new-project took a name with no letter or digit"; echo "  $nm0"; exit 1; }
  [ ! -e q2 ] || { echo "FAIL Q2: a name with no letter or digit left a folder"; exit 1; }
done
nm='Café (x) & y! #1'
"$N" q2 --name "$nm" --no-git >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cfgval q2 PROJECT_NAME)" = "$nm" ] && [ "$(head -1 q2/AGENTS.md)" = "# $nm Project Instructions" ]; } \
  || { echo "FAIL Q2: new-project did not keep a --name holding other punctuation exactly"; echo "  exit $rc"; exit 1; }
# Q3: a bad --domain is refused before anything is made; good ones are written
for d in 'a b.com' 'evil.com";touch PWNED4;"' '-a.com' 'nodot' 'a..b.com' 'a.com.' "$(printf 'x.com\nevil')" '0.0' '127.0.0.1'; do
  out="$("$N" q3 --domain "$d" --no-git 2>&1)" && { echo "FAIL Q3: new-project took a bad --domain"; echo "  $d"; exit 1; }
  printf '%s\n' "$out" | grep -qF "host name" || { echo "FAIL Q3: a bad --domain was refused without saying why"; exit 1; }
  [ ! -e q3 ] || { echo "FAIL Q3: a refused --domain left a folder"; exit 1; }
done
"$N" q3 --domain my-app.example.co.uk --no-git >/dev/null 2>&1 && [ "$(cfgval q3 PROJECT_DOMAIN)" = my-app.example.co.uk ] && [ "$(cfgval q3 PROJECT_DOMAIN_RE)" = 'my-app\.example\.co\.uk' ] \
  || { echo "FAIL Q3: a good --domain was not written"; exit 1; }
set -f   # the values below are passed as separate words, never as patterns
# Q4: --kb-level and --profile take only their values, refused before anything is made
for a in "--kb-level huge" "--kb-level lite;x" "--profile max"; do
  out="$("$N" q4 $a --no-git 2>&1)" && { echo "FAIL Q4: new-project took a bad value"; echo "  $a"; exit 1; }
  [ ! -e q4 ] || { echo "FAIL Q4: a refused value left a folder"; exit 1; }
done
"$N" q4 --kb-level standard --no-git >/dev/null 2>&1 && grep -qx 'export KNOWLEDGE_LEVEL="standard"' q4/pipeline.config.sh || { echo "FAIL Q4: --kb-level standard was not written"; exit 1; }
# Q5: a set or playbook name must name one: no path, no pattern, no unknown name; real sets are taken, written as checked
for a in "--agent-set ../x" "--agent-set *" "--agent-set Nope" "--agent-set no-such-set" "--agent-set ../sets/ml" "--skill-set no-such-set" "--skill-set ml;x" "--skill-set ../skill-sets/ml" "--playbook ../x" "--playbook .hidden"; do
  out="$("$N" q5 $a --no-git 2>&1)" && { echo "FAIL Q5: new-project took a bad set or playbook name"; echo "  $a"; exit 1; }
  [ ! -e q5 ] || { echo "FAIL Q5: a refused name left a folder"; exit 1; }
done
set +f
"$N" q5 --agent-set "$(printf 'identity\nml')" --skill-set ml --no-git >/dev/null 2>&1 \
  && grep -qx 'export AGENT_SETS="identity ml"' q5/pipeline.config.sh && grep -qx 'export SKILL_SETS="ml"' q5/pipeline.config.sh \
  || { echo "FAIL Q5: real set names were not taken, one line each"; exit 1; }
# Q6: a name holding a newline is refused, from --name or from the folder; only a folder new-project made is removed
out="$("$N" q6 --name "$(printf 'a\nb')" --no-git 2>&1)" && { echo "FAIL Q6: new-project took a name holding a newline"; exit 1; }
[ ! -e q6 ] || { echo "FAIL Q6: a refused --name left a folder"; exit 1; }
nl="$(printf 'two\nlines')"
out="$("$N" "$nl" --no-git 2>&1)" && { echo "FAIL Q6: new-project took a folder name holding a newline"; exit 1; }
[ ! -e "$nl" ] || { echo "FAIL Q6: a refused folder name left the folder new-project made"; exit 1; }
nl2="$(printf 'kept\nfolder')"; mkdir "$nl2"
out="$("$N" "$nl2" --no-git 2>&1)" && { echo "FAIL Q6: new-project took a folder name holding a newline"; exit 1; }
[ -d "$nl2" ] || { echo "FAIL Q6: new-project removed a folder it did not make"; exit 1; }
# Q7: an ordinary project's values are written exactly as before
"$N" q7 --name "My App" --no-git >/dev/null 2>&1
L=local
for l in 'export PROJECT_NAME="My App"' 'export PROJECT_SLUG="my-app"' "export PROJECT_DOMAIN=\"my-app.$L\"" "export PROJECT_DOMAIN_RE=\"my-app\\.$L\"" \
         'export DB_NAME="my_app_dev"' 'export KNOWLEDGE_LEVEL="lite"' 'export AGENT_SETS=""' 'export SKILL_SETS=""' \
         'export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"   # the directory this file lives in; portable across clones'; do
  grep -qxF "$l" q7/pipeline.config.sh || { echo "FAIL Q7: an ordinary project's config line changed"; echo "  $l"; exit 1; }
done
exit 0
