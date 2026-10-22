#!/usr/bin/env bash
# kb-keeps-edits: the knowledge-base scaffold replaces one of its documents only while it is exactly what
# the scaffold wrote (the frontmatter carries its hash), so what a person adds survives a re-run. A
# document an older scaffold wrote (no hash) is never replaced by install or intake; `acp kb
# scaffold` replaces it only when it is what the scaffold writes today apart from its date and tree hash.
set -uo pipefail
KB_PY="$PIPELINE_ROOT/core/hooks/kb.py"
P="$EVAL_TMP/proj"; KB="$P/Workspace/Docs/KnowledgeBase"
K() { python3 "$KB_PY" scaffold --root "$P" --kb "$KB" "$@"; }
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
seals() { grep -c '^scaffold_sha256: [0-9a-f]\{64\}$' "$1"; }
unseal() { for f in "$1"/*.md "$1"/profiles/*.md; do perl -ni -e 'print unless /^scaffold_sha256:/' "$f"; done; }
snap() { ( cd "$1" && for f in *.md profiles/*.md source-index.tsv; do printf '%s ' "$f"; cksum < "$f"; done ); }
undated() { grep -v '^scaffold_sha256:' "$1" | sed -e 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}/D/g'; }
mkdir -p "$P/src/auth" "$P/src/billing"
printf 'export function login() { return true; }\n' > "$P/src/auth/login.ts"
printf 'export function invoice() { return 1; }\n' > "$P/src/billing/invoice.ts"
out="$(K 2>&1)" || die "the first scaffold failed" "$out"

# K1: a section a person adds to a profile still at scaffold state survives a re-run
printf '\n## Notes\n\nA person wrote this.\n' >> "$KB/profiles/auth.md"
cp "$KB/profiles/auth.md" "$EVAL_TMP/auth.md"
out="$(K 2>&1)" || die "the second scaffold failed" "$out"
cmp -s "$EVAL_TMP/auth.md" "$KB/profiles/auth.md" || die "FAIL K1: the scaffold rebuilt a profile a person had added a section to"
printf '%s\n' "$out" | grep -qxF "scaffold: kept profiles/auth.md: it was edited after the scaffold wrote it; delete it to regenerate" \
  || die "FAIL K1: the scaffold did not say it kept the edited profile" "$out"

# K2: the same for the survey
printf '\n## Our notes\n\nKept.\n' >> "$KB/analysis.md"
cp "$KB/analysis.md" "$EVAL_TMP/analysis.md"
out="$(K 2>&1)" || die "the third scaffold failed" "$out"
cmp -s "$EVAL_TMP/analysis.md" "$KB/analysis.md" || die "FAIL K2: the scaffold rebuilt an analysis.md a person had added to"
printf '%s\n' "$out" | grep -qxF "scaffold: kept analysis.md: it was edited after the scaffold wrote it; delete it to regenerate" \
  || die "FAIL K2: the scaffold did not say it kept the edited survey" "$out"

# K3: every document carries one hash; one nobody edited is still refreshed when its code changes
for f in profiles/billing.md status-matrix.md; do
  [ "$(seals "$KB/$f")" = 1 ] || die "FAIL K3: $f does not carry exactly one scaffold hash"
done
printf 'export function tax() { return 0; }\n' > "$P/src/billing/tax.ts"
printf 'export function invoice() { return 3; }\n' > "$P/src/billing/invoice.ts"
printf 'export function login() { return 1; }\n' > "$P/src/auth/login.ts"
out="$(K 2>&1)" || die "the fourth scaffold failed" "$out"
# the binding: a profile rebuilt over changed code reads current; the kept (edited) one reads stale
st="$(python3 "$KB_PY" status --root "$P" --kb "$KB" 2>&1)"   # exit 1: something is stale
printf '%s\n' "$st" | grep -q '^profiles/billing.md  *current' || die "FAIL K3: a profile rebuilt over changed code does not read current" "$st"
printf '%s\n' "$st" | grep -q '^profiles/auth.md  *stale' || die "FAIL K3: a kept profile whose code changed does not read stale" "$st"
grep -qF '`src/billing/tax.ts`' "$KB/profiles/billing.md" || die "FAIL K3: an unedited profile was not refreshed when its code changed" "$out"
grep -qF '`profiles/billing.md` | 2 |' "$KB/status-matrix.md" || die "FAIL K3: an unedited status matrix was not refreshed" "$out"
[ "$(seals "$KB/profiles/billing.md")" = 1 ] || die "FAIL K3: the refreshed profile does not carry exactly one scaffold hash"
undated "$KB/profiles/billing.md" > "$EVAL_TMP/billing.md"
out="$(K 2>&1)" || die "the fifth scaffold failed" "$out"
undated "$KB/profiles/billing.md" | cmp -s "$EVAL_TMP/billing.md" - || die "FAIL K3: two scaffolds of one tree wrote different bytes"
# a person's own document beside the profiles is not marked current either
printf -- '# Architecture\n\nInvoices are summed. <!-- SOURCE: src/billing/invoice.ts:L1 -->\n' > "$KB/architecture.md"
python3 "$KB_PY" bind --root "$P" --kb "$KB" >/dev/null 2>&1 || die "kb bind failed"
printf 'export function invoice() { return 4; }\n' > "$P/src/billing/invoice.ts"
out="$(K 2>&1)" || die "the sixth scaffold failed" "$out"
st="$(python3 "$KB_PY" status --root "$P" --kb "$KB" 2>&1)"
printf '%s\n' "$st" | grep -q '^architecture.md  *stale' || die "FAIL K3: a person's own document whose code changed does not read stale" "$st"

# K4: the orphaned mark the scaffold writes is not an edit
mv "$P/src/billing" "$EVAL_TMP/billing-away"
out="$(K 2>&1)" || die "the orphaning scaffold failed" "$out"
grep -qx 'status: orphaned' "$KB/profiles/billing.md" || die "FAIL K4: the profile of a removed feature was not marked orphaned" "$out"
mv "$EVAL_TMP/billing-away" "$P/src/billing"
out="$(K 2>&1)" || die "the restoring scaffold failed" "$out"
grep -qx 'status: SCAFFOLD' "$KB/profiles/billing.md" || die "FAIL K4: a profile the scaffold had only marked orphaned was kept as edited" "$out"
# an edited profile the scaffold marked orphaned is kept when its code returns, and no longer reads as gone
mv "$P/src/auth" "$EVAL_TMP/auth-away"
out="$(K 2>&1)" || die "the second orphaning scaffold failed" "$out"
grep -qx 'status: orphaned' "$KB/profiles/auth.md" || die "FAIL K4: the edited profile of a removed feature was not marked orphaned" "$out"
mv "$EVAL_TMP/auth-away" "$P/src/auth"
printf 'export function login() { return 5; }\n' > "$P/src/auth/login.ts"   # it comes back changed
out="$(K 2>&1)" || die "the second restoring scaffold failed" "$out"
grep -qF '## Notes' "$KB/profiles/auth.md" || die "FAIL K4: the edited profile lost its section when its code returned" "$out"
grep -qx 'status: SCAFFOLD' "$KB/profiles/auth.md" || die "FAIL K4: an edited profile whose code returned still reads as orphaned" "$out"
st="$(python3 "$KB_PY" status --root "$P" --kb "$KB" 2>&1)"
printf '%s\n' "$st" | grep -q '^profiles/auth.md  *current' && die "FAIL K4: an edited profile whose code came back changed reads current" "$st"

# K5: documents an older scaffold wrote (no hash) are left byte-identical by a run like install's, the
# binding included, though a file they cite changed: the kept profile then reads stale, as it is
unseal "$KB"; snap "$KB" > "$EVAL_TMP/legacy"
printf 'export function logout() { return false; }\n' > "$P/src/auth/logout.ts"
printf 'export function invoice() { return 2; }\n' > "$P/src/billing/invoice.ts"
out="$(K 2>&1)" || die "the legacy scaffold failed" "$out"
snap "$KB" | cmp -s "$EVAL_TMP/legacy" - || die "FAIL K5: a run without --legacy-rebuild changed a document an older scaffold wrote" "$out"
for f in profiles/billing.md status-matrix.md; do
  printf '%s\n' "$out" | grep -qxF "scaffold: kept $f: an older scaffold wrote it; acp kb scaffold replaces it if nobody edited it, or delete it to regenerate" \
    || die "FAIL K5: the scaffold did not name the older document it kept ($f)" "$out"
done
st="$(python3 "$KB_PY" status --root "$P" --kb "$KB" 2>&1)"   # exit 1: something is stale
printf '%s\n' "$st" | grep -q '^profiles/billing.md  *stale' || die "FAIL K5: a kept profile whose code changed does not read stale" "$st"
rm "$P/src/auth/logout.ts"

# K6: --legacy-rebuild replaces an older document nobody edited, whatever its dates, and keeps an edited one
perl -pi -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/2020-01-01/g' "$KB/profiles/billing.md"
cp "$KB/profiles/auth.md" "$EVAL_TMP/auth.md"
out="$(K --legacy-rebuild 2>&1)" || die "the legacy rebuild failed" "$out"
[ "$(seals "$KB/profiles/billing.md")" = 1 ] || die "FAIL K6: an older profile nobody edited was not replaced" "$out"
[ "$(seals "$KB/status-matrix.md")" = 1 ] || die "FAIL K6: an older status matrix nobody edited was not replaced" "$out"
grep -q '2020-01-01' "$KB/profiles/billing.md" && die "FAIL K6: the replaced profile kept its old dates"
cmp -s "$EVAL_TMP/auth.md" "$KB/profiles/auth.md" || die "FAIL K6: --legacy-rebuild replaced an older profile a person had edited" "$out"
printf '%s\n' "$out" | grep -qxF "scaffold: kept profiles/auth.md: an older scaffold wrote it and it is not what the scaffold writes today; delete it to regenerate" \
  || die "FAIL K6: the scaffold did not say it kept the edited older profile" "$out"

# K8: a tree with nothing in it yet keeps an edited survey too
Z="$EVAL_TMP/empty"; ZKB="$Z/Workspace/Docs/KnowledgeBase"; mkdir -p "$Z"; printf '# nothing yet\n' > "$Z/README.md"
out="$(python3 "$KB_PY" scaffold --root "$Z" --kb "$ZKB" 2>&1)" || die "the empty scaffold failed" "$out"
[ "$(seals "$ZKB/analysis.md")" = 1 ] || die "FAIL K8: the empty survey does not carry exactly one scaffold hash"
printf '\n## Plans\n\nA person wrote this.\n' >> "$ZKB/analysis.md"; cp "$ZKB/analysis.md" "$EVAL_TMP/z.md"
out="$(python3 "$KB_PY" scaffold --root "$Z" --kb "$ZKB" 2>&1)" || die "the second empty scaffold failed" "$out"
cmp -s "$EVAL_TMP/z.md" "$ZKB/analysis.md" || die "FAIL K8: the scaffold rebuilt an empty tree's survey a person had added to" "$out"
printf '%s\n' "$out" | grep -qxF "scaffold: kept analysis.md: it was edited after the scaffold wrote it; delete it to regenerate" \
  || die "FAIL K8: the scaffold did not say it kept the edited empty survey" "$out"

# K7: through acp: intake leaves older documents as they are, acp kb scaffold replaces them
cd "$EVAL_TMP" && "$PIPELINE_ROOT/bin/new-project" q --name Q >/dev/null 2>&1 && cd q || die "new-project failed"
mkdir -p src/auth && printf 'export function login() { return true; }\n' > src/auth/login.ts
printf '{ "name": "q" }\n' > package.json
A=./.aicodepipeline/bin/acp; QKB=Workspace/Docs/KnowledgeBase
out="$($A kb scaffold 2>&1)" || die "acp kb scaffold failed" "$out"
[ -f "$QKB/profiles/auth.md" ] || die "acp kb scaffold wrote no profile" "$out"
unseal "$QKB"
# an older survey from another day and another tree: only its stamps differ
perl -pi -e 's/(Tree hash \| `)[0-9a-f]+/${1}0123456789ab/; s/(tree hash `)[0-9a-f]+/${1}0123456789ab/; s/[0-9]{4}-[0-9]{2}-[0-9]{2}/2020-01-01/g' "$QKB/analysis.md"
grep -qF '0123456789ab' "$QKB/analysis.md" || die "the eval could not restamp the survey"
snap "$QKB" > "$EVAL_TMP/q-legacy"
out="$($A intake 2>&1)"
snap "$QKB" | cmp -s "$EVAL_TMP/q-legacy" - || die "FAIL K7: acp intake changed a document an older scaffold wrote" "$out"
out="$($A kb scaffold 2>&1)" || die "the second acp kb scaffold failed" "$out"
[ "$(seals "$QKB/profiles/auth.md")" = 1 ] || die "FAIL K7: acp kb scaffold did not replace an older profile nobody edited" "$out"
[ "$(seals "$QKB/analysis.md")" = 1 ] || die "FAIL K7: acp kb scaffold did not replace an older survey whose date and tree hash alone differ" "$out"
# the survey it rewrote is bound afresh: it reads current after the manifest it cites changed
printf '{ "name": "q2" }\n' > package.json
out="$($A kb scaffold 2>&1)" || die "the third acp kb scaffold failed" "$out"
st="$($A kb status 2>&1)"
printf '%s\n' "$st" | grep -q '^analysis.md  *current' || die "FAIL K7: a survey the scaffold rewrote does not read current" "$st"
echo "kb-keeps-edits: all checks passed"
exit 0
