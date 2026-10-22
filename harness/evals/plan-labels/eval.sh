#!/usr/bin/env bash
# plan-labels: bin/lint fails on a plan label in any file or folder name or text under core, harness, bin
# and docs, sanitize-ignored files and any suffix included; the generated reports in harness/evals/results
# are not read; a file it cannot read is an error; installed copies are not held to it; and the shipped tree
# carries none.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | tail -8; exit 1; }
U="ACP""-123"; l="acp""-123"   # built here, so this file carries no label of its own
lint() { out="$(python3 "$1/bin/lint" "$1" 2>&1)"; rc=$?; }
fresh() {   # a copy of the source repository's four trees (and the file that marks it the source), no reports
  rm -rf "$EVAL_TMP/t" && mkdir "$EVAL_TMP/t" || die "could not make the copy"
  for s in core harness bin docs; do cp -R "$PIPELINE_ROOT/$s" "$EVAL_TMP/t/" || die "could not copy $s"; done
  cp "$PIPELINE_ROOT/pipeline.config.example.sh" "$EVAL_TMP/t/" || die "could not copy pipeline.config.example.sh"
  rm -rf "$EVAL_TMP/t/harness/evals/results"
}

# P1: the shipped tree carries no plan label
lint "$PIPELINE_ROOT"
printf '%s\n' "$out" | grep -q 'plan label' && die "FAIL P1: the shipped tree carries a plan label" "$(printf '%s\n' "$out" | grep 'plan label')"

# P2: a clean copy lints clean; a comment citing a label in bin/wo is then an error, naming the line
fresh; lint t
[ "$rc" -eq 0 ] || die "FAIL P2: the clean copy does not lint clean" "$out"
n="$(($(wc -l < t/bin/wo) + 1))"; printf '# keeps the lock (%s)\n' "$U" >> t/bin/wo; lint t
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "ERROR  bin/wo: plan label '$U' on line $n;"; } \
  || die "FAIL P2: a plan label in bin/wo was not an error naming its line" "$out"

# P3: a folder named for a label, holding no label in its files
fresh; mkdir -p "t/harness/evals/$l-x" && printf '#!/usr/bin/env bash\nexit 0\n' > "t/harness/evals/$l-x/eval.sh"; lint t
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "ERROR  harness/evals/$l-x: plan label '$l' in a file or folder name"; } \
  || die "FAIL P3: a folder named for a plan label was not an error" "$out"

# P4: a file .sanitize-ignore exempts from the scans (bin/sanitize) and a file of any suffix are read
fresh; printf '# (%s)\n' "$U" >> t/bin/sanitize; printf 'see %s\n' "$U" > t/docs/notes.txt; lint t
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "ERROR  bin/sanitize: plan label '$U'" \
  && printf '%s\n' "$out" | grep -qF "ERROR  docs/notes.txt: plan label '$U' on line 1;"; } \
  || die "FAIL P4: a label in a sanitize-ignored file or a .txt file was not an error" "$out"

# P5: the generated reports are not read (they name evaluations as they were when they ran)
fresh; mkdir -p t/harness/evals/results && printf '| %s-x | PASS |\n' "$l" > t/harness/evals/results/r.md; lint t
{ [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'plan label'; } \
  || die "FAIL P5: a generated report was read for plan labels" "$out"

# P6: a file lint cannot read is an error, not a pass: one only the label rule reads (.txt), and one every
# text check reads (.md)
fresh; printf 'x\n' > t/docs/locked.txt && printf 'x\n' > t/docs/locked.md && chmod 000 t/docs/locked.txt t/docs/locked.md
lint t; chmod 600 t/docs/locked.txt t/docs/locked.md
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "ERROR  docs/locked.txt: could not be read for plan labels" \
  && printf '%s\n' "$out" | grep -qF "ERROR  docs/locked.md: could not be read ("; } \
  || die "FAIL P6: a file lint could not read was passed, or lint broke on it" "$out"

# P7: an installed copy is not held to the rule: install writes the project's own path into it, and that path
# may hold anything (here, a label)
"$PIPELINE_ROOT/bin/new-project" "$EVAL_TMP/$U-proj" --name Labelled --no-git >/dev/null 2>&1 || die "could not make the project"
lint "$EVAL_TMP/$U-proj/.aicodepipeline"
{ [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'plan label'; } || die "FAIL P7: lint failed an installed copy for the project's own path" "$out"

echo "plan-labels: all checks passed"
