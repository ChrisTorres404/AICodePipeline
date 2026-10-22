#!/usr/bin/env bash
# The tree fingerprint covers every file name: a change to a file whose name holds a tab, a newline, a backslash, a
# leading quote or a control character changes it, in git and outside git, so the close guard sees it; two trees
# whose names differ only in how a newline or backslash could be written give different fingerprints.
set -uo pipefail
. "$(dirname "$0")/../_lib/verification.sh"
cd "$EVAL_TMP" || exit 1
G() { git -c user.name=t -c user.email=t@example.com "$@"; }
mk() { cd "$EVAL_TMP" && "$PIPELINE_ROOT/bin/new-project" "$1" --name P --no-git >/dev/null 2>&1 && cd "$EVAL_TMP/$1"; }
names=("$(printf 'tab\there')" "$(printf 'new\nline')" 'back\slash' '"quoted' "$(printf 'ctl\001x')" "$(printf 'Icon\r')")
# N1: in git, a change to each such file changes the fingerprint, whether the file is committed or untracked
mk g; echo a > src.txt; for x in "${names[@]}"; do printf v1 > "$x"; done; git init -q && G add -A && G commit -qm base >/dev/null 2>&1
W=.aicodepipeline/bin/wo
for x in "${names[@]}"; do
  a="$("$W" fingerprint)"; printf v2 > "$x"; b="$("$W" fingerprint)"; printf v1 > "$x"
  [ -n "$a" ] && [ "$a" != "$b" ] || { echo "FAIL N1: a change to a file whose name git quotes did not change the tree fingerprint"; printf '  %q\n' "$x"; exit 1; }
done
printf v1 > "$(printf 'fresh\tuntracked')"; a="$("$W" fingerprint)"; printf v2 > "$(printf 'fresh\tuntracked')"
[ "$a" != "$("$W" fingerprint)" ] || { echo "FAIL N1: a change to a file whose name git quotes did not change the tree fingerprint"; echo "  untracked"; exit 1; }
# with a name ending in a carriage return in the list (macOS writes Icon\r), a file after it still counts
a="$("$W" fingerprint)"; echo changed > src.txt; b="$("$W" fingerprint)"; echo a > src.txt
{ [ -n "$a" ] && [ "$a" != nofp ] && [ "$a" != "$b" ]; } || { echo "FAIL N1: a change to a file whose name git quotes did not change the tree fingerprint"; echo "  a file listed after Icon\\r"; exit 1; }
# N2: outside git, the same
mk n; echo a > src.txt; for x in "${names[@]}"; do printf v1 > "$x"; done; W=.aicodepipeline/bin/wo
for x in "${names[@]}"; do
  a="$("$W" fingerprint)"; printf v2 > "$x"; b="$("$W" fingerprint)"; printf v1 > "$x"
  [ -n "$a" ] && [ "$a" != "$b" ] || { echo "FAIL N2: outside git, a change to a file with such a name did not change the tree fingerprint"; printf '  %q\n' "$x"; exit 1; }
done
# N3: names are written so no two trees collide: a real newline and the two characters \n, a lone file and a
# file whose name holds that file's whole line, give different fingerprints (in git and outside)
for mode in git nogit; do
  mk "c1-$mode"; printf v > "$(printf 'a\nb')"; [ "$mode" = git ] && { git init -q; G add -A; G commit -qm b >/dev/null 2>&1; }; f1="$(.aicodepipeline/bin/wo fingerprint)"
  mk "c2-$mode"; printf v > 'a\nb'; [ "$mode" = git ] && { git init -q; G add -A; G commit -qm b >/dev/null 2>&1; }; f2="$(.aicodepipeline/bin/wo fingerprint)"
  mk "c3-$mode"; printf v > 'a\\nb'; [ "$mode" = git ] && { git init -q; G add -A; G commit -qm b >/dev/null 2>&1; }; f3="$(.aicodepipeline/bin/wo fingerprint)"
  { [ "$f1" != "$f2" ] && [ "$f1" != "$f3" ] && [ "$f2" != "$f3" ]; } || { echo "FAIL N3: two different trees gave the same fingerprint ($mode)"; exit 1; }
done
# outside git, a name holding a newline cannot pass for a file and its content: "a<newline>b" holding v, and "a"
# holding "b<newline>v", give different fingerprints
mk f1; printf v > "$(printf 'a\nb')"; f1="$(.aicodepipeline/bin/wo fingerprint)"
mk f2; printf 'b\nv' > a; f2="$(.aicodepipeline/bin/wo fingerprint)"
[ -n "$f1" ] && [ "$f1" != "$f2" ] || { echo "FAIL N3: two different trees gave the same fingerprint (a name and a file's content, nogit)"; exit 1; }
# N4: the close guard sees it: after a PASS, a change to a file whose name git quotes refuses wo close
cd "$EVAL_TMP/g"; W=.aicodepipeline/bin/wo; printf '#!/usr/bin/env bash\nexit 0\n' > ok.sh; G add -A; G commit -qm s >/dev/null 2>&1
n="$("$W" new Names --size small --area backend | grep -o 'WO-[0-9]*' | head -1 | cut -c4-)"; "$W" verify "$n" --run ./ok.sh >/dev/null 2>&1; fill_wo "$n"
printf changed > "$(printf 'tab\there')"
rc=0; "$W" close "$n" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL N4: wo close accepted a PASS after a file whose name git quotes changed"; exit 1; }
# N5: bug verify records the same fingerprint, so its status line moves with such a file too
B=.aicodepipeline/bin/bug; bn="$("$B" new "Names bug" | grep -o 'BUG-[0-9]*' | head -1 | cut -c5-)"
tree() { grep -m1 '^\*\*Overall status:\*\*' Workspace/Docs/Bugs/BUG-"$bn"-*/BUG-"$bn"-VERIFICATION.md | sed -n 's/.*, tree \([0-9a-f]*\),.*/\1/p'; }
"$B" verify "$bn" --run ./ok.sh >/dev/null 2>&1; t1="$(tree)"; printf again > "$(printf 'new\nline')"; "$B" verify "$bn" --run ./ok.sh >/dev/null 2>&1; t2="$(tree)"
{ [ -n "$t1" ] && [ "$t1" != "$t2" ] && [ "$t2" = "$("$W" fingerprint)" ]; } || { echo "FAIL N5: bug verify did not record a change to a file whose name holds a newline"; exit 1; }
# N6: a code folder holding only such a file is not empty to the fingerprint
grep -v '^export CODE_DIR=' pipeline.config.sh > ../cfg && mv ../cfg pipeline.config.sh   # CODE_DIR comes from the environment here
mkdir -p odd && printf v > "odd/$(printf 'only\nfile')"
CODE_DIR=odd "$W" fingerprint >/dev/null 2>&1 || { echo "FAIL N6: a code folder holding only a file with such a name was refused as empty"; exit 1; }
# N7: the fingerprint of plain names is exactly the documented one, in byte order of the names (the order a folder
# lists them in is not sorted): outside git, sha256 of "<path>\n<content>" per file; in git, of "<blob> <path>\n"
sha() { { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-16; }
for mode in nogit git; do
  mk "o-$mode"; grep -v '^export CODE_DIR=' pipeline.config.sh > ../cfg && mv ../cfg pipeline.config.sh
  mkdir sub; for x in zeta alpha mu beta; do echo "$x" > "sub/$x"; done
  if [ "$mode" = git ]; then
    git init -q && G add -A && G commit -qm b >/dev/null 2>&1
    want="$(for x in alpha beta mu zeta; do printf '%s sub/%s\n' "$(git hash-object "sub/$x")" "$x"; done | sha)"
  else
    want="$(for x in alpha beta mu zeta; do printf './sub/%s\n%s\n' "$x" "$x"; done | sha)"
  fi
  [ "$(CODE_DIR=sub .aicodepipeline/bin/wo fingerprint)" = "$want" ] || { echo "FAIL N7: the fingerprint of plain names is not the documented one ($mode)"; exit 1; }
done
# N8: a project in a subfolder of its git repository: its fingerprint reads the files' content (git resolves
# --stdin-paths from the repository's top folder), so a change to a file's content changes it and refuses wo close
mkdir -p "$EVAL_TMP/repo" && cd "$EVAL_TMP/repo" && git init -q && "$PIPELINE_ROOT/bin/new-project" proj --name P --no-git >/dev/null 2>&1 && cd proj || { echo "FAIL setup: subfolder project"; exit 1; }
mkdir -p src && echo v1 > src/app.txt && printf '#!/usr/bin/env bash\nexit 0\n' > ok.sh && G add -A && G commit -qm base >/dev/null 2>&1
W=.aicodepipeline/bin/wo; a="$("$W" fingerprint)"; echo v2 > src/app.txt; b="$("$W" fingerprint)"; echo v1 > src/app.txt
{ [ -n "$a" ] && [ "$a" != nofp ] && [ "$a" != "$b" ]; } || { echo "FAIL N8: in a subfolder of its repository, a change to a file's content did not change the fingerprint"; exit 1; }
n="$("$W" new Sub --size small --area backend | grep -o 'WO-[0-9]*' | head -1 | cut -c4-)"; "$W" verify "$n" --run ./ok.sh >/dev/null 2>&1; fill_wo "$n"
echo v3 > src/app.txt; rc=0; "$W" close "$n" >/dev/null 2>&1 || rc=$?; echo v1 > src/app.txt
[ "$rc" -ne 0 ] || { echo "FAIL N8: in a subfolder of its repository, wo close accepted a PASS after the content changed"; exit 1; }
sb="$(.aicodepipeline/bin/bug new "Sub bug" | grep -o 'BUG-[0-9]*' | head -1 | cut -c5-)"
btree() { grep -m1 '^\*\*Overall status:\*\*' Workspace/Docs/Bugs/BUG-"$sb"-*/BUG-"$sb"-VERIFICATION.md | sed -n 's/.*, tree \([0-9a-f]*\),.*/\1/p'; }
.aicodepipeline/bin/bug verify "$sb" --run ./ok.sh >/dev/null 2>&1; t1="$(btree)"; echo v4 > src/app.txt
.aicodepipeline/bin/bug verify "$sb" --run ./ok.sh >/dev/null 2>&1; t2="$(btree)"; echo v1 > src/app.txt
{ [ -n "$t1" ] && [ "$t1" != "$t2" ]; } || { echo "FAIL N8: in a subfolder of its repository, bug verify did not see a change to a file's content"; exit 1; }
# N9: a file git cannot hash makes the fingerprint refuse: wo fingerprint fails, and wo verify and bug verify run
# nothing and record no status
echo locked > src/locked.txt; chmod 000 src/locked.txt
out="$("$W" fingerprint 2>&1)"; rc=$?
v="$(ls Workspace/Docs/WorkOrders/WO-"$n"-*/WO-"$n"-VERIFICATION.md)"; st1="$(grep -m1 '^\*\*Overall status:\*\*' "$v")"
vo="$("$W" verify "$n" --run ./ok.sh 2>&1)"; vrc=$?; st2="$(grep -m1 '^\*\*Overall status:\*\*' "$v")"
bn="$(.aicodepipeline/bin/bug new "Locked" | grep -o 'BUG-[0-9]*' | head -1 | cut -c5-)"; bo="$(.aicodepipeline/bin/bug verify "$bn" --run ./ok.sh 2>&1)"; brc=$?
chmod 644 src/locked.txt
nl="src/$(printf 'locked\nname')"; echo x > "$nl"; chmod 000 "$nl"; out2="$("$W" fingerprint 2>&1)"; rc2=$?; chmod 644 "$nl"
{ [ "$rc2" -ne 0 ] && printf '%s\n' "$out2" | grep -qF 'cannot fingerprint the source' && [ "$rc" -ne 0 ] \
  && printf '%s\n' "$out" | grep -qF 'cannot read src/locked.txt' && printf '%s\n' "$vo" | grep -qF 'cannot read src/locked.txt' \
  && printf '%s\n' "$out2" | grep -qF "cannot read \$'src/locked\\nname'" && printf '%s\n' "$out" | grep -qF 'cannot fingerprint the source' && [ "$vrc" -ne 0 ] && printf '%s\n' "$vo" | grep -qF 'cannot fingerprint the source' \
  && [ "$st1" = "$st2" ] && [ "$brc" -ne 0 ] && printf '%s\n' "$bo" | grep -qF 'cannot fingerprint the source' && printf '%s\n' "$bo" | grep -qF 'cannot read src/locked.txt'; } \
  || { echo "FAIL N9: a file git cannot hash did not make the fingerprint refuse"; exit 1; }
# a file git cannot hash on its own (a name holding a carriage return; here a git that refuses it) refuses too, naming
# it, never a fingerprint of what was left; and perl that cannot start says so as itself
mkdir -p "$EVAL_TMP/gw"; cr="$(printf 'Icon\r')"; printf v > "src/$cr"; realgit="$(command -v git)"
printf '#!/bin/sh\ncr="$(printf "\\r")"\nfor a in "$@"; do case "$a" in *"$cr") echo "git: refused" >&2; exit 1;; esac; done\nexec "%s" "$@"\n' "$realgit" > "$EVAL_TMP/gw/git"; chmod +x "$EVAL_TMP/gw/git"
go="$(PATH="$EVAL_TMP/gw:$PATH" "$W" fingerprint 2>&1)"; grc=$?
po="$(PERL5OPT=-MNoSuchModuleHere "$W" fingerprint 2>&1)"; prc=$?
bgo="$(PATH="$EVAL_TMP/gw:$PATH" .aicodepipeline/bin/bug verify "$sb" --run ./ok.sh 2>&1)"; bgrc=$?
bpo="$(PERL5OPT=-MNoSuchModuleHere .aicodepipeline/bin/bug verify "$sb" --run ./ok.sh 2>&1)"; bprc=$?; rm -f "src/$cr"
{ [ "$grc" -ne 0 ] && printf '%s\n' "$go" | grep -qF "git could not hash \$'src/Icon\\r'" \
  && [ "$prc" -ne 0 ] && printf '%s\n' "$po" | grep -qF 'NoSuchModuleHere' \
  && [ "$bgrc" -ne 0 ] && printf '%s\n' "$bgo" | grep -qF "git could not hash \$'src/Icon\\r'" \
  && [ "$bprc" -ne 0 ] && printf '%s\n' "$bpo" | grep -qF 'NoSuchModuleHere'; } \
  || { echo "FAIL N9: a file git cannot hash on its own, or a perl that cannot start, did not refuse with its reason"; printf '%s\n' "$go" "$po" | head -3; exit 1; }
# N10: the refusal names the file once and comes before anything runs: wo close names it once, verify prints no
# Running line; outside git an unreadable file refuses too, never hashed as if it were empty
chmod 000 src/locked.txt; co="$("$W" close "$n" 2>&1)"; crc=$?; vo="$("$W" verify "$n" --run ./ok.sh 2>&1)"; chmod 644 src/locked.txt
cd "$EVAL_TMP/n" || exit 1; echo x > locked.txt; chmod 000 locked.txt; no="$(.aicodepipeline/bin/wo fingerprint 2>&1)"; nrc=$?; chmod 644 locked.txt
{ [ "$crc" -ne 0 ] && [ "$(printf '%s\n' "$co" | grep -c 'cannot read src/locked.txt')" -eq 1 ] && ! printf '%s\n' "$vo" | grep -q '^Running:' \
  && [ "$nrc" -ne 0 ] && printf '%s\n' "$no" | grep -qF 'cannot read ./locked.txt'; } \
  || { echo "FAIL N10: an unreadable file was not named once before anything ran, or was read as empty outside git"; exit 1; }
# bug verify outside git: its status line moves with a file whose name holds a newline, and an unreadable file refuses it
B=.aicodepipeline/bin/bug; printf '#!/usr/bin/env bash\nexit 0\n' > ok.sh; nb="$("$B" new "Nogit bug" | grep -o 'BUG-[0-9]*' | head -1 | cut -c5-)"
ntree() { grep -m1 '^\*\*Overall status:\*\*' Workspace/Docs/Bugs/BUG-"$nb"-*/BUG-"$nb"-VERIFICATION.md | sed -n 's/.*, tree \([0-9a-f]*\),.*/\1/p'; }
"$B" verify "$nb" --run ./ok.sh >/dev/null 2>&1; t1="$(ntree)"; printf v3 > "$(printf 'new\nline')"; "$B" verify "$nb" --run ./ok.sh >/dev/null 2>&1; t2="$(ntree)"
chmod 000 locked.txt; bo2="$("$B" verify "$nb" --run ./ok.sh 2>&1)"; brc2=$?; chmod 644 locked.txt
{ [ -n "$t1" ] && [ "$t1" != "$t2" ] && [ "$brc2" -ne 0 ] && printf '%s\n' "$bo2" | grep -qF 'cannot read ./locked.txt'; } \
  || { echo "FAIL N10: outside git, bug verify did not see a file with such a name, or read an unreadable file"; exit 1; }
# outside git nothing of the source is left in TMPDIR: the content is streamed into the hash, scratch files go with it
mkdir -p "$EVAL_TMP/td"; TMPDIR="$EVAL_TMP/td" .aicodepipeline/bin/wo fingerprint >/dev/null 2>&1; TMPDIR="$EVAL_TMP/td" "$B" verify "$nb" --run ./ok.sh >/dev/null 2>&1
[ -z "$(ls -A "$EVAL_TMP/td")" ] || { echo "FAIL N10: the fingerprint left files in TMPDIR: $(ls -A "$EVAL_TMP/td" | head -3)"; exit 1; }
exit 0
