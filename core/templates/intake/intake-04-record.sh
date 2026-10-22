#!/usr/bin/env bash
# INTAKE-04 — record: the project's existing history is in, and it is honest.
#
# Exit codes: 0 every check passed, 1 at least one failed, 77 the checks could
# not be attempted at all. This suite reads; it never writes into the project.
set -uo pipefail

root="$(cd "$(dirname "$0")" && while [ "$PWD" != / ] && [ ! -f pipeline.config.sh ]; do cd ..; done; pwd -P)"
[ -f "$root/pipeline.config.sh" ] || {
  echo "  precondition: no pipeline.config.sh in this directory or any directory above it, so the project root cannot be resolved"
  exit 77; }
. "$root/pipeline.config.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

wo_rel="${WORKORDERS_DIR:-Workspace/Docs/WorkOrders}"
wo_dir="$root/$wo_rel"
bug_dir="$root/${BUGS_DIR:-Workspace/Docs/Bugs}"
# The inventory lives beside the work orders, wherever this project keeps them.
docs_dir="$(dirname "$wo_rel")"
# The inventory is part of the repository's description, so it lives with the
# knowledge base; the older locations are still accepted.
index="$root/${KNOWLEDGE_DIR:-Workspace/Docs/KnowledgeBase}/INDEX.md"
[ -f "$index" ] || index="$root/$docs_dir/INDEX.md"
[ -f "$index" ] || [ -z "${DOCS_DIR:-}" ] || index="$root/$DOCS_DIR/INDEX.md"

echo "== INTAKE-04 record — $root"

# 1. the inventory
if [ -f "$index" ]; then
  ok "the inventory is on file at ${index#$root/}"
else
  bad "no inventory at ${index#$root/}" "nothing has listed what this project already carries: run  acp intake inventory"
fi

# 2. adopted history must never carry evidence that was never produced
adopted=0; fabricated=0
for d in "$wo_dir"/*/ "$bug_dir"/*/; do
  [ -d "$d" ] || continue
  grep -qs '^adopted=' "$d.wo-meta" "$d.bug-meta" || continue
  adopted=$((adopted + 1))
  for v in "$d"*VERIFICATION*.md; do
    [ -f "$v" ] || continue
    grep -qE 'EXECUTED (—|–|-) PASS' "$v" || continue   # all three dashes
    logged=0
    for l in "$d"*VERIFICATION-*.log; do [ -f "$l" ] && logged=1; done
    if [ "$logged" -eq 0 ]; then
      fabricated=$((fabricated + 1))
      bad "adopted item $(basename "${d%/}") records EXECUTED — PASS in $(basename "$v") with no run log beside it" "adopted work is recorded, not verified: delete the pass line, or produce real evidence with  wo verify <number> --run <suite>"
    fi
  done
done
if [ "$fabricated" -eq 0 ]; then
  ok "no adopted item claims a pass it cannot evidence ($adopted adopted item(s) inspected)"
fi

# 3. one number, one folder
dups=""
for pair in "WO $wo_dir" "BUG $bug_dir"; do
  prefix="${pair%% *}"; dir="${pair#* }"
  [ -d "$dir" ] || continue
  d_here="$(ls -1 "$dir" 2>/dev/null | sed -n "s/^$prefix-\([0-9][0-9]*\).*/\1/p" | sed 's/^0*//;s/^$/0/' | sort | uniq -d)"
  for n in $d_here; do
    dups="$dups $prefix-$n"
    bad "$prefix number $n is used by more than one folder: $(ls -1 "$dir" | grep -E "^$prefix-0*$n(-|$)" | tr '\n' ' ')" "one number, one item: rename one of them with  git mv <folder> ${dir#$root/}/$prefix-<a free number>-<slug>"
  done
done
[ -z "$dups" ] && ok "every work-order and bug number belongs to exactly one folder"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
