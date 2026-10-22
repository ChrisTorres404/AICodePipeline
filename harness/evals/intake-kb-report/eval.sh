#!/usr/bin/env bash
# intake-kb-report: acp intake (and so every install) shows every line the knowledge-base scaffold prints, not
# only its last, and then names every knowledge-base file whose bytes it added or changed.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
"$PIPELINE_ROOT/bin/new-project" q --name Q >/dev/null 2>&1; cd q || die "new-project failed"
A=./.aicodepipeline/bin/acp
mkdir -p src/auth && printf 'export function login() { return true; }\n' > src/auth/login.ts
out="$($A intake 2>&1)" || die "acp intake failed" "$out"
printf '%s\n' "$out" | grep -qxF '  knowledge base: added profiles/auth.md' || die "FAIL I1: acp intake did not name the profile the scaffold added" "$out"
for f in analysis.md status-matrix.md source-index.tsv; do
  printf '%s\n' "$out" | grep -qxF "  knowledge base: rewrote $f" || die "FAIL I2: acp intake did not name $f, which the scaffold rewrote" "$out"
done
printf '%s\n' "$out" | grep -q '^  knowledge base: kb bind: ' || die "FAIL I3: acp intake cut the scaffold's report to its last line" "$out"
printf '%s\n' "$out" | grep -q '^  knowledge base: scaffold: 1 feature(s), 1 profile(s) written' || die "FAIL I3: acp intake did not show the scaffold's summary" "$out"
# I4: a run that changes nothing names no file
out="$($A intake 2>&1)" || die "the second acp intake failed" "$out"
printf '%s\n' "$out" | grep -qE '^  knowledge base: (added|rewrote) ' && die "FAIL I4: acp intake named a file it did not change" "$out"
# I5: an edited profile is kept, and the line saying so reaches the person
printf '\n## Notes\n\nA person wrote this.\n' >> Workspace/Docs/KnowledgeBase/profiles/auth.md
out="$($A intake 2>&1)" || die "the third acp intake failed" "$out"
printf '%s\n' "$out" | grep -qxF '  knowledge base: scaffold: kept profiles/auth.md: it was edited after the scaffold wrote it; delete it to regenerate' \
  || die "FAIL I5: acp intake did not show that it kept the edited profile" "$out"
printf '%s\n' "$out" | grep -qxF '  knowledge base: rewrote profiles/auth.md' && die "FAIL I5: acp intake says it rewrote a profile it kept" "$out"
# I6: a first install shows the same list (a project with code, and no pipeline or knowledge base yet)
mkdir -p "$EVAL_TMP/r/src/billing" && printf 'export function invoice() { return 1; }\n' > "$EVAL_TMP/r/src/billing/invoice.ts" && cp pipeline.config.sh "$EVAL_TMP/r/"
out="$("$PIPELINE_ROOT/bin/install.sh" "$EVAL_TMP/r" 2>&1)" || die "install.sh failed" "$out"
printf '%s\n' "$out" | grep -qxF '    knowledge base: added profiles/billing.md' || die "FAIL I6: install did not name the profile the scaffold added" "$out"
# I6b: an install over this existing project leaves its knowledge base alone and says so
mkdir -p src/billing && printf 'export function invoice() { return 1; }\n' > src/billing/invoice.ts
out="$("$PIPELINE_ROOT/bin/install.sh" "$PWD" 2>&1)" || die "install.sh failed" "$out"
{ printf '%s\n' "$out" | grep -qF "knowledge base: not touched: an upgrade leaves the project's knowledge base as it is" \
  && ! printf '%s\n' "$out" | grep -qE '^    knowledge base: (added|rewrote) '; } || die "FAIL I6b: an install over the project wrote its knowledge base" "$out"
# I7: a folder in the knowledge base that cannot be read does not stop intake
mkdir -p Workspace/Docs/KnowledgeBase/locked && chmod 000 Workspace/Docs/KnowledgeBase/locked
printf 'private\n' > Workspace/Docs/KnowledgeBase/secret.md && chmod 000 Workspace/Docs/KnowledgeBase/secret.md
rc=0; out="$($A intake 2>&1)" || rc=$?
chmod 755 Workspace/Docs/KnowledgeBase/locked; chmod 644 Workspace/Docs/KnowledgeBase/secret.md
[ "$rc" -eq 0 ] || die "FAIL I7: an unreadable folder in the knowledge base stopped acp intake (exit $rc)" "$out"
printf '%s\n' "$out" | grep -q '^  knowledge base: scaffold: ' || die "FAIL I7: an unreadable folder in the knowledge base kept the scaffold from running" "$out"
printf '%s\n' "$out" | grep -qF 'Permission denied' && die "FAIL I7: acp intake printed an error for a file or folder it cannot read" "$out"
echo "intake-kb-report: all checks passed"
exit 0
