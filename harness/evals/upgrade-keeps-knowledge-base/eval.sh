#!/usr/bin/env bash
# upgrade-keeps-knowledge-base: an upgrade leaves the project's knowledge base alone (D-3); a first install
# scaffolds it as before; acp doctor writes nothing in the project, its lifecycle probe running in a scratch copy.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
export TMPDIR="$EVAL_TMP/tmp"; mkdir -p "$TMPDIR"
die() { echo "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | tail -8; exit 1; }
G() { git -c user.name=t -c user.email=t@example.com "$@"; }
ci() { G add -A && { G diff --cached --quiet || G commit -qm "$1"; }; }   # commit what is staged, if anything
KB=Workspace/Docs/KnowledgeBase
snap() { ( cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(cksum < "$f" | cut -d' ' -f1)" "$f"; done ); }

# U1: a first install scaffolds the knowledge base, as before
"$PIPELINE_ROOT/bin/new-project" p --name P >/dev/null 2>&1 || die "FAIL setup: new-project failed"
cd p || exit 1
[ -f "$KB/source-index.tsv" ] || die "FAIL U1: a first install did not scaffold the knowledge base" "$(find Workspace -maxdepth 3)"
ci install >/dev/null 2>&1 || die "FAIL setup: commit"

# U2: an install over the project, after new code, leaves the knowledge base byte for byte, and says how to scaffold
mkdir -p src/billing && printf 'export function charge() { return 1; }\n' > src/billing/charge.ts && ci code >/dev/null 2>&1
before="$(snap "$KB")"; out="$("$PIPELINE_ROOT/bin/install.sh" "$PWD" 2>&1)" || die "FAIL U2: the upgrade failed" "$out"
[ "$(snap "$KB")" = "$before" ] || die "FAIL U2: an upgrade wrote the knowledge base" "$(diff <(printf '%s\n' "$before") <(snap "$KB"))"
printf '%s\n' "$out" | grep -qF "knowledge base: not touched: an upgrade leaves the project's knowledge base as it is. To create or extend it:  acp kb scaffold" \
  || die "FAIL U2: the upgrade did not say how to scaffold the knowledge base by hand" "$out"

# U3: an upgrade where the knowledge base is gone does not make one
mv "$KB" "$EVAL_TMP/kb.away"
out="$("$PIPELINE_ROOT/bin/install.sh" "$PWD" 2>&1)" || die "FAIL U3: the upgrade failed" "$out"
[ ! -e "$KB" ] || die "FAIL U3: an upgrade created a knowledge base" "$(find "$KB" | head -5)"
mv "$EVAL_TMP/kb.away" "$KB"

# U4: a first pipeline install into a project that already has a knowledge base leaves it alone
mkdir -p "$EVAL_TMP/q/$KB" && printf '# ours\n' > "$EVAL_TMP/q/$KB/README.md" && cp pipeline.config.sh "$EVAL_TMP/q/"
before="$(snap "$EVAL_TMP/q/$KB")"; out="$("$PIPELINE_ROOT/bin/install.sh" "$EVAL_TMP/q" 2>&1)" || die "FAIL U4: the install failed" "$out"
[ "$(snap "$EVAL_TMP/q/$KB")" = "$before" ] || die "FAIL U4: an install wrote a knowledge base the project already had" "$(diff <(printf '%s\n' "$before") <(snap "$EVAL_TMP/q/$KB"))"

# U5: acp doctor writes nothing in the project; its probe completes a work order in a scratch copy and leaves none
mkdir -p src/ledger && printf 'export const post = 1;\n' > src/ledger/post.ts && ci more >/dev/null 2>&1
before="$(snap .)"; out="$(.aicodepipeline/bin/acp doctor . 2>&1)"
[ "$(snap .)" = "$before" ] || die "FAIL U5: acp doctor wrote into the project" "$(diff <(printf '%s\n' "$before") <(snap .))"
printf '%s\n' "$out" | grep -qF "lifecycle probe: a work order opened, verified and closed in this layout (in a scratch copy)" \
  || die "FAIL U5: the lifecycle probe did not complete in a scratch copy" "$out"
[ -z "$(ls -A "$TMPDIR" | grep '^acp-doctor\.' || true)" ] || die "FAIL U5: the probe left its scratch copy behind" "$(ls -A "$TMPDIR")"

# U6: a configuration that pins PROJECT_ROOT to the project still has the probe run in the scratch copy
cp pipeline.config.sh "$EVAL_TMP/config.keep"
printf '\nexport PROJECT_ROOT=%q\n' "$(pwd -P)" >> pipeline.config.sh; ci pin >/dev/null 2>&1
before="$(snap .)"; out="$(.aicodepipeline/bin/acp doctor . 2>&1)"
[ "$(snap .)" = "$before" ] || die "FAIL U6: with PROJECT_ROOT pinned, acp doctor wrote into the project" "$(diff <(printf '%s\n' "$before") <(snap .))"

# U7: the probe still finds a layout the drivers cannot complete (here, no work-order template to read)
chmod 000 .aicodepipeline/core/templates/workorders
out="$(.aicodepipeline/bin/acp doctor . 2>&1)"; chmod 755 .aicodepipeline/core/templates/workorders
printf '%s\n' "$out" | grep -qE 'lifecycle probe(: wo new)? failed|lifecycle probe: wo new failed' || die "FAIL U7: the probe passed a layout the drivers cannot complete" "$out"
[ -z "$(ls -A "$TMPDIR" | grep '^acp-doctor\.' || true)" ] || die "FAIL U7: a failed probe left its scratch copy behind" "$(ls -A "$TMPDIR")"

# U8: with a code folder (CODE_DIR=src) the probe's scratch copy has one, and the probe completes
cp "$EVAL_TMP/config.keep" pipeline.config.sh && printf '\nexport CODE_DIR="src"\n' >> pipeline.config.sh && ci codedir
before="$(snap .)"; out="$(.aicodepipeline/bin/acp doctor . 2>&1)"
{ [ "$(snap .)" = "$before" ] && printf '%s\n' "$out" | grep -qF "lifecycle probe: a work order opened, verified and closed in this layout (in a scratch copy)"; } \
  || die "FAIL U8: with CODE_DIR=src the probe did not complete, or doctor wrote into the project" "$out"

# U9: a code folder that would lead out of the scratch (CODE_DIR=../escape275) writes nothing outside it: the
# probe leaves it to wo, which refuses it, and the probe says it failed
cp "$EVAL_TMP/config.keep" pipeline.config.sh && printf '\nexport CODE_DIR="../escape275"\n' >> pipeline.config.sh && ci escape
before="$(snap .)"; out="$(.aicodepipeline/bin/acp doctor . 2>&1)"
[ ! -e "$TMPDIR/escape275" ] && [ ! -e "$EVAL_TMP/escape275" ] || die "FAIL U9: the probe wrote outside its scratch folder" "$(ls -A "$TMPDIR" "$EVAL_TMP")"
{ [ "$(snap .)" = "$before" ] && printf '%s\n' "$out" | grep -qE 'lifecycle probe(: wo new)? failed'; } || die "FAIL U9: with CODE_DIR outside the project the probe passed, or doctor wrote into the project" "$out"
[ -z "$(ls -A "$TMPDIR" | grep '^acp-doctor\.' || true)" ] || die "FAIL U9: the probe left its scratch copy behind" "$(ls -A "$TMPDIR")"
cp "$EVAL_TMP/config.keep" pipeline.config.sh && ci restore

echo "upgrade-keeps-knowledge-base: all checks passed"
