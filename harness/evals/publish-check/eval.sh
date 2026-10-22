#!/usr/bin/env bash
# acp publish-check reads every commit on every ref, merges and stashes included, and the files a
# commit could still add, with bin/sanitize's rules, before a first push; it reports, runs none of a
# repository's own programs, and never writes, rewrites, fetches or pushes.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
A="$PIPELINE_ROOT/bin/acp"
export HOME="$EVAL_TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$EVAL_TMP"; mkdir -p "$HOME"
git config --global user.name t && git config --global user.email t@example.com || die "the eval could not set a git identity"
# Every secret is assembled here, at run time, so this file holds none.
AWS="AKIA""QWERTYUIOPASDFGH"
GH="ghp_""$(printf 'a%.0s' $(seq 1 36))"
PK="-----BEGIN ""PRIVATE KEY-----"
HP="/Us""ers/alice/notes"
newrepo() { mkdir -p "$1" && git -C "$1" init -q && git -C "$1" symbolic-ref HEAD refs/heads/main; }
commit() { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }
pcw() { local acp="$1" d="$2"; shift 2; rc=0; out="$(cd "$d" && "$acp" publish-check --identity t@example.com "$@" 2>&1)" || rc=$?; }
pc() { pcw "$A" "$@"; }
has() { case "$out" in *"$1"*) return 0;; esac; return 1; }   # no pipe: grep -q under pipefail can end on SIGPIPE
fp() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum | shasum); }
mkpipe() { mkdir -p "$1/bin" "$1/core/hooks" && cp "$PIPELINE_ROOT/bin/acp" "$PIPELINE_ROOT/bin/sanitize" "$PIPELINE_ROOT/bin/wo" "$1/bin/" \
  && cp "$PIPELINE_ROOT/core/hooks/publish-check.py" "$PIPELINE_ROOT/core/hooks/check.py" "$1/core/hooks/"; }

R="$EVAL_TMP/r"; newrepo "$R"
printf 'hello\n' > "$R/README.md"; printf 'base\n' > "$R/stash.txt"; commit "$R" "start"
git -C "$R" branch done                                                  # merged: its tip is on main
git -C "$R" checkout -q -b old && mkdir -p "$R/old" && printf '%s\n' "$PK" > "$R/old/notes.txt" && commit "$R" "old notes"
printf 'a log\n' > "$R/old/old.log"; dd if=/dev/zero of="$R/old/huge.bin" bs=3000 count=1 2>/dev/null
git -C "$R" add -A && git -C "$R" -c user.name="Old Person" -c user.email=op@corp.example.net commit -q -m "old files"
git -C "$R" checkout -q main
mkdir -p "$R/config" && printf 'id %s\n' "$AWS" > "$R/config/aws.txt" && commit "$R" "add the key"
git -C "$R" rm -q config/aws.txt && commit "$R" "remove the key"     # gone from the tree, still in the history
printf 'more\n' >> "$R/README.md" && commit "$R" "rotate $GH"           # a token in a commit message
mkdir -p "$R/docs" && printf 'the Contoso team\n' > "$R/docs/team.md" && commit "$R" "team"
printf 'x\n' > "$R/work.txt" && git -C "$R" add work.txt && git -C "$R" -c user.name="Work Person" -c user.email=wp@corp.example.org commit -q -m "work"
printf 'a log\n' > "$R/run.log"; printf 'PK\003\004' > "$R/export.zip"; mkdir -p "$R/scratch" && printf 'x\n' > "$R/scratch/tmp.txt"
dd if=/dev/zero of="$R/big.bin" bs=2000 count=1 2>/dev/null
mkdir -p "$R/vendor/acp/bin" "$R/vendor/acp/core/hooks" && printf '#!/bin/sh\n' > "$R/vendor/acp/bin/wo" && printf '#\n' > "$R/vendor/acp/core/hooks/check.py"
mkdir -p "$R/plus" && printf '++ id %s\n' "$AWS" > "$R/plus/notes.txt"   # an added line that starts with "++ "
printf 'id %s\n' "$AWS" > "$R/a \"q\".txt"                                # a path git prints quoted
commit "$R" "files"
git -C "$R" checkout -q -b sup && printf 's\n' > "$R/sup.txt" && commit "$R" "sup"
c="$(git -C "$R" rev-parse HEAD)"; git -C "$R" checkout -q main && printf 'm\n' > "$R/main.txt" && commit "$R" "main moves on"   # so the copy below gets its own id
git -C "$R" cherry-pick "$c" >/dev/null || die "the eval could not cherry-pick"
git -C "$R" checkout -q -b side2 && printf 'side\n' > "$R/side2.txt" && commit "$R" "side2"
git -C "$R" checkout -q main && git -C "$R" merge -q --no-ff --no-commit side2 >/dev/null 2>&1 \
  && printf 'id %s\n' "$AWS" > "$R/merged.txt" && commit "$R" "merge side2" || die "the eval could not make a merge"   # a key only in the merge's own change
git -C "$R" checkout -q --detach && printf 'id %s\n' "$AWS" > "$R/tagonly.txt" && commit "$R" "tag only" && git -C "$R" tag t1 && git -C "$R" checkout -q main
printf 'local/\n' > "$R/.gitignore" && commit "$R" "ignore local"
printf 'id %s\n' "$AWS" > "$R/stash.txt" && git -C "$R" stash -q || die "the eval could not stash"   # a key only in a stash
mkdir -p "$R/local" && printf 'id %s\n' "$AWS" > "$R/local/secret.txt"   # ignored: a push cannot carry it
printf '%s\n' "$HP" > "$R/draft.txt"                                       # untracked, not ignored: the next commit could
printf 'id %s\n' "$AWS" > "$R/deploy.tfvars"                               # a name outside sanitize's text extensions
git -C "$R" -c user.name="Tag Person" -c user.email=tp@corp.example.org tag -a rel1 -m "release $GH" main || die "the eval could not tag"
git -C "$R" tag -a outer rel1 -m "outer id $AWS" 2>/dev/null && git -C "$R" tag -d rel1 >/dev/null \
  || die "the eval could not tag a tag"   # a nested tag; rel1 is now reached only through outer
printf '%s\n' "$HP" >> "$R/README.md"                                      # an uncommitted edit to a tracked file
before="$(fp "$R")"

pc "$R" --max-size 1000
# H1: a key that lives only in the history of a branch that is not checked out is found
{ [ "$rc" -eq 2 ] && has "CRITICAL secret.privkey history:old/notes.txt@"; } \
  || die "FAIL H1: acp publish-check did not find a key that lives only on another branch" "exit $rc" "$out"
# H2: a key removed from the tree is still found in the history
has "CRITICAL secret.aws history:config/aws.txt@" || die "FAIL H2: a key deleted from the tree was not found in the history" "$out"
# H3: a token in a commit message is found
has "CRITICAL secret.github history:(commit message)@" || die "FAIL H3: a token in a commit message was not found" "$out"
# H4: a key in a commit only a tag reaches is found
has "CRITICAL secret.aws history:tagonly.txt@" || die "FAIL H4: a key in a commit only a tag reaches was not found" "$out"
# H5: an added line starting with "++ " is read, and a quoted path is named as it is
has "CRITICAL secret.aws history:plus/notes.txt@" || die "FAIL H5: an added line starting with ++ was not read" "$out"
has "CRITICAL secret.aws history:a \"q\".txt@" || die "FAIL H5: a key in a file git prints quoted was not named by its path" "$out"
# H6: a key only in a merge's own change, and one only in a stash, are found
has "CRITICAL secret.aws history:merged.txt@" || die "FAIL H6: a key only in a merge commit's own change was not found" "$out"
has "CRITICAL secret.aws history:stash.txt@" || die "FAIL H6: a key only in a stash was not found" "$out"
# S1: no secret is printed whole
! has "$AWS" && ! has "$GH" || die "FAIL S1: acp publish-check printed a secret whole" "$out"
# T1: a file a commit could still add is read; T2: an ignored file, which a push cannot carry, is not;
# T3: an uncommitted edit to a tracked file is read
has "CRITICAL path.home tree:draft.txt:1" || die "FAIL T1: an untracked file holding a home path was not found" "$out"
! has "local/secret.txt" || die "FAIL T2: an ignored file was reported" "$out"
has "CRITICAL path.home tree:README.md:" || die "FAIL T3: an uncommitted edit to a tracked file was not read" "$out"
# D1: a term that must not be published is found only when it is named
! has " deny " || die "FAIL D1: a term was reported as denied without --deny" "$out"
# I1: identities not confirmed are named, on every branch; a confirmed one is not
has "WARNING history.identity history - an author, committer or tagger not confirmed for publishing: Work Person <wp@corp.example.org>" \
  || die "FAIL I1: an unconfirmed identity in the history was not named" "$out"
has "not confirmed for publishing: Old Person <op@corp.example.net>" || die "FAIL I1: an unconfirmed identity on another branch was not named" "$out"
! has "not confirmed for publishing: t <t@example.com>" || die "FAIL I1: a confirmed identity was reported" "$out"
# J1: logs, archives and scratch in the history are named, on every branch; J2: files over the size limit too
has "WARNING file.junk history:run.log" && has "WARNING file.junk history:export.zip" && has "WARNING file.junk history:scratch/tmp.txt" \
  || die "FAIL J1: a log, an archive or a scratch file in the history was not named" "$out"
has "WARNING file.junk history:old/old.log" || die "FAIL J1: a log on another branch was not named" "$out"
has "WARNING file.large history:big.bin - 2000 bytes, over the 1000-byte limit" || die "FAIL J2: a file over the size limit was not named" "$out"
has "WARNING file.large history:old/huge.bin - 3000 bytes" || die "FAIL J2: a file over the size limit on another branch was not named" "$out"
# A1: a second copy of the pipeline inside the repository is named
has "WARNING layout.acp-copy history:vendor/acp/" || die "FAIL A1: a second pipeline copy was not named" "$out"
# B1 to B3: a merged branch and a superseded one are named; a branch with work of its own is only noted
has "WARNING branch.merged branch:done" || die "FAIL B1: a merged branch was not named" "$out"
has "WARNING branch.superseded branch:sup" || die "FAIL B2: a superseded branch was not named" "$out"
{ has "info: branch old: 2 commit(s) not on main" && ! has "WARNING branch.merged branch:old" && ! has "WARNING branch.superseded branch:old"; } \
  || die "FAIL B3: a branch with its own work was reported as merged or superseded, or not noted" "$out"
# G2: annotated tags' messages, nested tags included, and their taggers are read
has "CRITICAL secret.github history:(tag message rel1)@" || die "FAIL G2: a token in an annotated tag's message was not found" "$out"
has "CRITICAL secret.aws history:(tag message outer)@" || die "FAIL G2: a key in a nested tag's message was not found" "$out"
has "not confirmed for publishing: Tag Person <tp@corp.example.org>" || die "FAIL G2: a tagger was not checked as an identity" "$out"
# T5: a file outside sanitize's text extensions, with no NUL byte, is read
has "CRITICAL secret.aws tree:deploy.tfvars:1" || die "FAIL T5: a .tfvars file holding a key was not read" "$out"
# R1: no remote is said
has "info: remote: none." || die "FAIL R1: acp publish-check did not say there is no remote" "$out"
# D1 (continued): with --deny the term is found; I1 (continued): --identity confirms an address
pc "$R" --max-size 1000 --deny '[Cc]ontoso' --identity wp@corp.example.org
has "CRITICAL deny history:docs/team.md@" || die "FAIL D1: a denied term in the history was not found" "$out"
! has "Work Person <wp@corp.example.org>" || die "FAIL I1: --identity did not confirm an address" "$out"
# N1: the repository, its .git folder included, is byte-identical after the runs so far
[ "$(fp "$R")" = "$before" ] || die "FAIL N1: acp publish-check changed the repository"
# R2, N2: with a remote it says privacy cannot be known, and nothing reaches the remote
git init -q --bare "$EVAL_TMP/remote.git" && git -C "$R" remote add origin "$EVAL_TMP/remote.git"
before="$(fp "$R")"
pc "$R"
has "info: remote origin (" && has "whether it is private cannot be known without asking the host" \
  || die "FAIL R2: acp publish-check did not say a remote's privacy cannot be known" "$out"
[ -z "$(git -C "$EVAL_TMP/remote.git" for-each-ref)" ] || die "FAIL N2: something was pushed to the remote"
[ "$(fp "$R")" = "$before" ] || die "FAIL N1: acp publish-check changed the repository"
# A2: the project's own pipeline, inside the repository, is not a second copy; another one is
P="$EVAL_TMP/p"; newrepo "$P"; mkpipe "$P/.aicodepipeline" && mkpipe "$P/vendor/acp" || die "the eval could not copy the pipeline"; commit "$P" "start"
pcw "$P/.aicodepipeline/bin/acp" "$P"
{ has "WARNING layout.acp-copy history:vendor/acp/" && has "this project's own is .aicodepipeline/" && ! has "layout.acp-copy history:.aicodepipeline/"; } \
  || die "FAIL A2: the project's own pipeline was reported as a second copy, or another copy was missed" "exit $rc" "$out"
# A3: a repository that is the pipeline itself is not a second copy of itself
Q="$EVAL_TMP/q"; newrepo "$Q"; mkpipe "$Q" || die "the eval could not copy the pipeline"; commit "$Q" "start"
pcw "$Q/bin/acp" "$Q"
! has "layout.acp-copy" || die "FAIL A3: the pipeline's own repository was reported as a second copy of itself" "exit $rc" "$out"
# G1: a received repository's own programs are not run (signature checker, diff drivers, filters, fsmonitor, pager, hooks, GIT_* variables)
G="$EVAL_TMP/g"; newrepo "$G"; printf '*.txt diff=evil\n* filter=evil\n' > "$G/.gitattributes"; printf 'a\n' > "$G/a.txt"; commit "$G" "a"
git -C "$G" checkout -q -b side && printf 'b\n' >> "$G/a.txt" && commit "$G" "b" && git -C "$G" checkout -q main
tree="$(git -C "$G" rev-parse 'HEAD^{tree}')"; parent="$(git -C "$G" rev-parse HEAD)"
sig="$(printf 'tree %s\nparent %s\nauthor t <t@example.com> 1700000000 +0000\ncommitter t <t@example.com> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n -----END PGP SIGNATURE-----\n\nsigned\n' "$tree" "$parent" \
  | git -C "$G" hash-object -t commit -w --stdin)" && git -C "$G" update-ref refs/heads/main "$sig" || die "the eval could not make a signed commit"
EV="$EVAL_TMP/evil.sh"; printf '#!/bin/sh\necho "$0 $*" >> "%s/ran.txt"\nexit 1\n' "$EVAL_TMP" > "$EV"; chmod +x "$EV"
mkdir -p "$EVAL_TMP/hooks"; for h in pre-commit post-checkout post-merge pre-push reference-transaction; do cp "$EV" "$EVAL_TMP/hooks/$h"; done
for kv in log.showSignature=true gpg.program="$EV" gpg.ssh.program="$EV" diff.evil.textconv="$EV" diff.evil.command="$EV" \
          core.fsmonitor="$EV" core.pager="$EV" core.hooksPath="$EVAL_TMP/hooks" \
          filter.evil.clean="$EV" filter.evil.smudge="$EV" filter.evil.process="$EV" filter.evil.required=true; do git -C "$G" config "${kv%%=*}" "${kv#*=}"; done
touch -t 203001010000 "$G/a.txt"   # stat-dirty against the index, as git status would then run the clean filter
rm -f "$EVAL_TMP/ran.txt"
rc=0; out="$(cd "$G" && GIT_EXTERNAL_DIFF="$EV" GIT_PAGER="$EV" "$A" publish-check --identity t@example.com 2>&1)" || rc=$?
[ ! -e "$EVAL_TMP/ran.txt" ] || die "FAIL G1: acp publish-check ran a program the repository's configuration names" "$(cat "$EVAL_TMP/ran.txt")" "$out"
# K1 to K10: a setting or attribute that changes what git shows cannot hide a key (each one committed, then deleted)
keyrepo() { newrepo "$1" && printf 'x\n' > "$1/a.txt" && commit "$1" "a"; }
addkey() { printf 'id %s\n' "$AWS" > "$1/$2" && commit "$1" "key" && git -C "$1" rm -q "$2" && commit "$1" "gone"; }
K="$EVAL_TMP/k1"; keyrepo "$K"; mkdir -p "$K/attr" && printf '*.env -diff\n' > "$K/attr/.gitattributes" && commit "$K" "attrs"; addkey "$K" attr/prod.env
pc "$K"; has "CRITICAL secret.aws history:attr/prod.env@" || die "FAIL K1: a key a committed -diff attribute hides was not found" "$out"
K="$EVAL_TMP/k2"; keyrepo "$K"; printf '*.dat binary\n' > "$K/.git/info/attributes"; addkey "$K" key.dat
pc "$K"; has "CRITICAL secret.aws history:key.dat@" || die "FAIL K2: a key a binary attribute in .git/info/attributes hides was not found" "$out"
K="$EVAL_TMP/k3"; keyrepo "$K"; addkey "$K" big.txt; git -C "$K" config core.bigFileThreshold 1
pc "$K"; has "CRITICAL secret.aws history:big.txt@" || die "FAIL K3: a key core.bigFileThreshold hides was not found" "$out"
K="$EVAL_TMP/k4"; newrepo "$K"; addkey "$K" root.txt; git -C "$K" config log.showRoot false   # the key is in the root commit
pc "$K"; has "CRITICAL secret.aws history:root.txt@" || die "FAIL K4: a key in the root commit, with log.showRoot false, was not found" "$out"
K="$EVAL_TMP/k5"; keyrepo "$K"; printf 'id %s\n' "$AWS" > "$K/bad.txt" && commit "$K" "bad"; bad="$(git -C "$K" rev-parse HEAD)"
git -C "$K" checkout -q --detach HEAD~1 && printf 'y\n' > "$K/ok.txt" && commit "$K" "clean"; clean="$(git -C "$K" rev-parse HEAD)"
git -C "$K" checkout -q main && git -C "$K" replace "$bad" "$clean" || die "the eval could not replace a commit"   # a push still sends the original
pc "$K"; has "CRITICAL secret.aws history:bad.txt@" || die "FAIL K5: a key in a commit hidden by git replace was not found" "$out"
K="$EVAL_TMP/k6"; keyrepo "$K"; printf 'id %s\n' "$AWS" > "$K/graft.txt" && commit "$K" "key"; k="$(git -C "$K" rev-parse HEAD)"
printf 'z\n' > "$K/z.txt" && commit "$K" "z"; c="$(git -C "$K" rev-parse HEAD)"; git -C "$K" rm -q graft.txt && commit "$K" "gone"
printf '%s %s\n' "$k" "$c" > "$K/.git/info/grafts"
pc "$K"; has "CRITICAL secret.aws history:graft.txt@" || die "FAIL K6: a key hidden by .git/info/grafts was not found" "$out"
K="$EVAL_TMP/k7"; keyrepo "$K"; addkey "$K" k7.txt; git -C "$K" config diff.srcPrefix x/; git -C "$K" config diff.dstPrefix y/
pc "$K"; has "CRITICAL secret.aws history:k7.txt@" || die "FAIL K7: diff prefix settings changed the path a finding names" "$out"
K="$EVAL_TMP/k7b"; keyrepo "$K"; mkdir -p "$K/b" && addkey "$K" b/inner.txt; git -C "$K" config diff.noprefix true   # a real folder named b
pc "$K"; has "CRITICAL secret.aws history:b/inner.txt@" || die "FAIL K7: diff.noprefix changed the path a finding names" "$out"
K="$EVAL_TMP/k8"; keyrepo "$K"; printf 'e\n' > "$K/e.txt" && git -C "$K" add e.txt && git -C "$K" -c user.name="Enc Person" -c user.email=ep@corp.example.com commit -q -m "enc"
git -C "$K" config i18n.logOutputEncoding UTF-16
pc "$K"; has "not confirmed for publishing: Enc Person <ep@corp.example.com>" || die "FAIL K8: i18n.logOutputEncoding garbled an identity" "$out"
K="$EVAL_TMP/k9"; keyrepo "$K"; nlp="$(printf 'nl\nkey.txt')"; addkey "$K" "$nlp"
pc "$K"; has 'CRITICAL secret.aws history:nl\x0akey.txt@' || die "FAIL K9: a path holding a newline was not printed on one line" "$out"
git clone -q --depth 1 "file://$EVAL_TMP/k1" "$EVAL_TMP/k10" 2>/dev/null || die "the eval could not make a shallow clone"
pc "$EVAL_TMP/k10"; has "info: this repository is shallow" || die "FAIL K10: a shallow repository was not said to be shallow" "$out"
# E1: a clean repository exits 0, one with warnings only exits 1; it works from a subfolder too
C="$EVAL_TMP/c"; newrepo "$C"; mkdir -p "$C/src"; printf 'ok\n' > "$C/src/a.txt"; commit "$C" "start"
pc "$C/src"
{ [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "publish-check: clean; nothing matched bin/sanitize's rules in the history or the working tree" ]; } \
  || die "FAIL E1: a clean repository did not pass" "exit $rc" "$out"
printf 'a log\n' > "$C/notes.log" && commit "$C" "log"
pc "$C"
[ "$rc" -eq 1 ] || die "FAIL E1: a repository with warnings only did not exit 1" "exit $rc" "$out"
# U2: a ref that points at a blob is a refusal, exit 3, naming the ref
BR="$EVAL_TMP/br"; newrepo "$BR"; printf 'ok\n' > "$BR/a.txt"; commit "$BR" "start"
git -C "$BR" tag blobtag "$(git -C "$BR" hash-object -w a.txt)" || die "the eval could not tag a blob"
pc "$BR"; { [ "$rc" -eq 3 ] && has "refs/tags/blobtag points at a blob"; } || die "FAIL U2: a ref pointing at a blob was not refused" "exit $rc" "$out"
# U3: a .sanitize-ignore that is not a regular file is a refusal, exit 3
SI="$EVAL_TMP/si"; newrepo "$SI"; printf 'ok\n' > "$SI/a.txt"; commit "$SI" "start"; ln -s /etc/hosts "$SI/.sanitize-ignore"
pc "$SI"; { [ "$rc" -eq 3 ] && has ".sanitize-ignore is a .sanitize-ignore that is not a regular file; refusing"; } \
  || die "FAIL U3: a .sanitize-ignore that is a link was not refused" "exit $rc" "$out"
# U4: an unexpected error is exit 3, never the warnings code
printf 'def (:\n' > "$EVAL_TMP/broken"
rc=0; out="$(python3 "$PIPELINE_ROOT/core/hooks/publish-check.py" --root "$C" --sanitize "$EVAL_TMP/broken" 2>&1)" || rc=$?
{ [ "$rc" -eq 3 ] && has "internal error"; } || die "FAIL U4: an unexpected error did not exit 3" "exit $rc" "$out"
# V1: a line too long to match is not read but reported, so the result is never clean, and the run ends quickly
LL="$EVAL_TMP/ll"; newrepo "$LL"; python3 -c 'import sys; open(sys.argv[1], "w").write("x" * 100000 + "\n")' "$LL/long.txt"; commit "$LL" "long"
pc "$LL"
{ [ "$rc" -eq 1 ] && has "WARNING line.long history:long.txt@" && has "WARNING line.long tree:long.txt:1"; } \
  || die "FAIL V1: a line longer than the limit was not reported" "exit $rc" "$out"
# U1: outside a repository it refuses with exit 3
mkdir -p "$EVAL_TMP/none"; pc "$EVAL_TMP/none"
{ [ "$rc" -eq 3 ] && has "acp publish-check: not inside a git repository"; } || die "FAIL U1: outside a repository it did not refuse" "exit $rc" "$out"
echo "publish-check: all checks passed"
exit 0
