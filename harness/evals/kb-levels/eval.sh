#!/usr/bin/env bash
# Builds a small project and asks the tool to describe it without an agent: the
# scaffold must produce a knowledge base that passes its own lite check, the
# levels must measure what is written rather than what exists, and re-running the
# scaffold must not destroy anything a person wrote.
set -uo pipefail
KB_PY="$PIPELINE_ROOT/core/hooks/kb.py"
P="$EVAL_TMP/proj"; KB="$P/Workspace/Docs/KnowledgeBase"
cd "$EVAL_TMP" || exit 1
K() { python3 "$KB_PY" "$@" --root "$P" --kb "$KB"; }
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }

# --- the fixture --------------------------------------------------------------
mkdir -p "$P/src/auth" "$P/src/billing" "$P/src/util" "$P/src/models"
cat > "$P/src/auth/login.ts" <<'F'
import { session } from "./session";
export async function login(email: string, password: string) {
  const user = await lookup(email);
  return user ? session.start(user) : null;
}
F
cat > "$P/src/auth/session.ts" <<'F'
export const session = {
  start(user: User) { return { id: user.id, issued: Date.now() }; },
};
F
cat > "$P/src/billing/invoice.ts" <<'F'
import { router } from "../server";
router.get('/invoices', (req, res) => res.json(list()));
export function total(lines: Line[]) {
  return lines.reduce((n, l) => n + l.amount, 0);
}
F
printf 'export const log = (m: string) => process.stdout.write(m);\n' > "$P/src/util/log.ts"
printf 'export class User {\n  id!: string;\n}\n' > "$P/src/models/user.ts"
cat > "$P/package.json" <<'F'
{
  "name": "fixture",
  "main": "src/index.ts",
  "scripts": { "build": "tsc", "test": "jest" },
  "dependencies": { "express": "^4.18.2" }
}
F

# fill every bracketed writing prompt in a profile, the way a writer would
fill() { python3 - "$1" <<'F'
import sys, re
p = sys.argv[1]; t = open(p).read()
t = t.replace("[Unwritten at scaffold — replace this line with what the prompt above asks for.]",
              "Written by a reader of the source, in sentences that say what the code does.")
t = re.sub(r"- \*\*\[Scenario name\]:\*\*", "- **A named actor, a real quantity:** and what happens to them.", t)
t = re.sub(r"- \*\*\[Label\]:\*\*", "- **A real limitation:** and the consequence of hitting it.", t)
open(p, "w").write(t)
F
}
validate() { python3 - "$1" <<'F'
import sys
p = sys.argv[1]; t = open(p).read()
open(p, "w").write(t.replace("validated: false", "validated: true").replace("reviewed-by: N/A", "reviewed-by: a.reviewer"))
F
}
strip_dates() { grep -v '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "$1"; }
snap_kb() { ( cd "$KB" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
  printf '%s ' "$f"; strip_dates "$f" | shasum -a 256 2>/dev/null || strip_dates "$f" | sha256sum; done ) ; }

# --- 1. the scaffold writes a whole knowledge base, with no agent --------------
out="$(K scaffold 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "scaffold exited $rc, expected 0" "$out"
echo "$out" | grep -q "^scaffold: 4 feature(s), 4 profile(s) written, 0 kept, 0 orphaned, 1 endpoint(s), 1 model(s)" \
  || die "scaffold did not report what it did" "$out"
for f in analysis.md status-matrix.md source-index.tsv level profiles/auth.md profiles/billing.md profiles/util.md profiles/models.md; do
  [ -f "$KB/$f" ] || die "the scaffold did not write $f"
done
[ "$(cat "$KB/level")" = "lite" ] || die "the level file does not say lite: $(cat "$KB/level")"

# the survey is prose and tables about this tree, and it cites it
grep -q "^| Auth | \`src/auth\` | 2 |" "$KB/analysis.md" || { echo "the layout table is wrong:"; grep -n '^| ' "$KB/analysis.md"; exit 1; }
grep -q "src/billing/invoice.ts:L2" "$KB/analysis.md" || die "the route line was not found or not cited"
grep -q "src/models/user.ts" "$KB/analysis.md" || die "the data model was not found"
grep -q '`express`' "$KB/analysis.md" || die "the dependency was not read from the manifest"
grep -q 'script `build`' "$KB/analysis.md" || die "the manifest scripts were not read as entry points"
grep -q "tree hash" "$KB/analysis.md" || die "the survey does not record the tree it was generated against"

# every citation in every scaffolded document resolves to a line that is there
python3 - "$P" "$KB" <<'F' || exit 1
import os, re, sys
root, kb = sys.argv[1], sys.argv[2]
rx = re.compile(r"<!--\s*SOURCE:\s*([^\s:>]+)(?::L?(\d+))?[^>]*-->")
bad = 0
for d, _, fs in os.walk(kb):
    for f in sorted(fs):
        if not f.endswith(".md"): continue
        p = os.path.join(d, f)
        for m in rx.finditer(open(p, encoding="utf-8").read()):
            ref, line = m.group(1), m.group(2)
            if ref.startswith(("path", "<", "[")): continue
            full = os.path.join(root, ref)
            if not os.path.isfile(full):
                print(f"{f}: {ref} does not exist"); bad += 1; continue
            if line and int(line) > sum(1 for _ in open(full, encoding="utf-8", errors="ignore")):
                print(f"{f}: {ref}:L{line} is past the end of the file"); bad += 1
print("citations checked")
sys.exit(1 if bad else 0)
F
grep -q "SOURCE: src/auth/login.ts:L1" "$KB/profiles/auth.md" || die "the auth profile does not cite its own first file"
grep -q "SOURCE: src/billing/invoice.ts:L2" "$KB/profiles/billing.md" || die "the billing profile does not cite its route line"
grep -q "^| Auth | \`undocumented\` |" "$KB/status-matrix.md" || { echo "the matrix badge is wrong:"; grep -n '^| ' "$KB/status-matrix.md"; exit 1; }
for b in undocumented described validated; do
  grep -q "| \`$b\` |" "$KB/status-matrix.md" || die "the matrix does not define the badge $b"
done
grep -q "bound_tree=[0-9a-f]\{16\}" "$KB/source-index.tsv" || die "the scaffold did not bind"

# --- 2. lite passes on its own; standard does not -----------------------------
out="$(K status 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "status at lite exited $rc, expected 0" "$out"
echo "$out" | grep -q "0 short of lite" || die "the summary does not carry the level" "$out"
out="$(K status --level standard 2>&1)"; rc=$?
[ "$rc" -eq 4 ] || die "status at standard exited $rc, expected 4" "$out"
for f in auth billing util models; do
  echo "$out" | grep -q "^  profiles/$f.md .*writing prompts unanswered" || die "$f was not named as short of standard" "$out"
done
echo "$out" | grep -q "4 short of standard" || die "the short count is wrong" "$out"

# --- 3. a profile whose narrative is written stops being short ----------------
fill "$KB/profiles/auth.md"
out="$(K status --level standard 2>&1)"; rc=$?
[ "$rc" -eq 4 ] || die "status at standard exited $rc with three profiles still short, expected 4" "$out"
echo "$out" | grep -q "^  profiles/auth.md" && die "the written profile is still listed as short" "$out"
echo "$out" | grep -q "3 short of standard" || die "the short count did not fall" "$out"

for f in billing util models; do fill "$KB/profiles/$f.md"; done
out="$(K status --level standard 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "status at standard exited $rc with every narrative written, expected 0" "$out"
out="$(K status --level full 2>&1)"; rc=$?
[ "$rc" -eq 4 ] || die "status at full exited $rc with nothing validated, expected 4" "$out"
echo "$out" | grep -q "validated: false" || die "full does not say what is missing" "$out"

# --- 4. full is reached by a reviewer, not by a writer ------------------------
for f in auth billing util models; do validate "$KB/profiles/$f.md"; done
out="$(K status --level full 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "status at full exited $rc once every profile was validated, expected 0" "$out"

# --- 5. freshness outranks the level -----------------------------------------
printf 'export function refresh() { return true; }\n' >> "$P/src/auth/login.ts"
out="$(K status --level full 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || die "an edit under a validated profile exited $rc, expected 1 (stale outranks short)" "$out"
echo "$out" | grep -q "^profiles/auth.md  *stale" || die "the edited profile is not stale" "$out"
K bind >/dev/null 2>&1

# --- 6. re-running the scaffold keeps what was written ------------------------
cp "$KB/profiles/auth.md" "$EVAL_TMP/auth-before.md"
mkdir -p "$P/src/search"; printf 'export function query(q: string) { return []; }\n' > "$P/src/search/index.ts"
rm -rf "$P/src/util"
out="$(K scaffold 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "re-running the scaffold exited $rc" "$out"
diff "$EVAL_TMP/auth-before.md" "$KB/profiles/auth.md" >/dev/null \
  || { echo "the scaffold rewrote a profile whose narrative had been written:"; diff "$EVAL_TMP/auth-before.md" "$KB/profiles/auth.md"; exit 1; }
[ -f "$KB/profiles/search.md" ] || die "a new feature directory got no profile"
[ -f "$KB/profiles/util.md" ] || die "the profile of a deleted feature was deleted"
grep -q "^status: orphaned" "$KB/profiles/util.md" || { echo "the vanished feature is not marked orphaned:"; sed -n '1,14p' "$KB/profiles/util.md"; exit 1; }
echo "$out" | grep -q "orphaned (none of the paths it covers exists; the profile is kept): util" || die "the scaffold did not list the orphan" "$out"
echo "$out" | grep -q "1 profile(s) written, 3 kept, 1 orphaned" || die "the scaffold miscounted what it did" "$out"
out="$(K status 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "an orphaned profile left status at $rc; a kept record is not a failure" "$out"
echo "$out" | grep -q "^profiles/util.md  *orphaned" || die "the orphan is not reported as orphaned" "$out"

# --- 7. --force regenerates, and says so --------------------------------------
out="$(K scaffold --force 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "scaffold --force exited $rc" "$out"
echo "$out" | grep -q -- "--force — every scaffolded document was regenerated" || die "--force did not say what it did" "$out"
diff "$EVAL_TMP/auth-before.md" "$KB/profiles/auth.md" >/dev/null && die "--force left a written profile alone"
grep -q "scaffold_prompts: 11" "$KB/profiles/auth.md" || die "the regenerated profile carries no prompt count"

# --- 8. the same tree scaffolds to the same bytes -----------------------------
snap_kb > "$EVAL_TMP/kb1"
out="$(K scaffold --force 2>&1)" || die "the second scaffold failed" "$out"
snap_kb > "$EVAL_TMP/kb2"
diff "$EVAL_TMP/kb1" "$EVAL_TMP/kb2" >/dev/null \
  || { echo "two scaffolds of one tree differ outside the date lines:"; diff "$EVAL_TMP/kb1" "$EVAL_TMP/kb2"; exit 1; }

# --- 9. --grow adds without re-binding what close has to leave stale ----------
G="$EVAL_TMP/grow"; GKB="$G/Workspace/Docs/KnowledgeBase"
mkdir -p "$G/src/auth" "$G/src/billing"
printf 'export function login() {}\n' > "$G/src/auth/login.ts"
printf 'export function invoice() {}\n' > "$G/src/billing/invoice.ts"
python3 "$KB_PY" scaffold --root "$G" --kb "$GKB" >/dev/null 2>&1 || die "the grow fixture would not scaffold"
grep -v '^#' "$GKB/source-index.tsv" | LC_ALL=C sort > "$EVAL_TMP/rows-before"
printf 'export function login(user) { return user; }\n' > "$G/src/auth/login.ts"
mkdir -p "$G/src/search"; printf 'export function query() {}\n' > "$G/src/search/q.ts"
out="$(python3 "$KB_PY" scaffold --root "$G" --kb "$GKB" --grow 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "scaffold --grow exited $rc" "$out"
echo "$out" | grep -q "^grow: 1 profiles added (search)$" || die "--grow did not report what it added" "$out"
[ -f "$GKB/profiles/search.md" ] || die "--grow wrote no profile for the new feature"
grep -v '^#' "$GKB/source-index.tsv" | LC_ALL=C sort > "$EVAL_TMP/rows-after"
comm -23 "$EVAL_TMP/rows-before" "$EVAL_TMP/rows-after" | grep -q . \
  && { echo "--grow changed rows that were already bound:"; comm -23 "$EVAL_TMP/rows-before" "$EVAL_TMP/rows-after"; exit 1; }
grep -q "^src/search/q.ts	" "$EVAL_TMP/rows-after" || { echo "--grow did not bind the new profile's citation"; cat "$EVAL_TMP/rows-after"; exit 1; }
rc=0; python3 "$KB_PY" status --root "$G" --kb "$GKB" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || die "the profile describing the edited file is not stale after --grow (exit $rc)"
out="$(python3 "$KB_PY" scaffold --root "$G" --kb "$GKB" --grow 2>&1)"
echo "$out" | grep -q "^grow: nothing new" || die "--grow with nothing to add did not say so" "$out"

# --- 10. a tree with nothing in it yet ---------------------------------------
E="$EVAL_TMP/empty"; EKB="$E/Workspace/Docs/KnowledgeBase"
mkdir -p "$E/docs"; printf '# nothing here yet\n' > "$E/README.md"
out="$(python3 "$KB_PY" scaffold --root "$E" --kb "$EKB" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "scaffolding an empty tree exited $rc, expected 0" "$out"
echo "$out" | grep -q "^scaffold: nothing to describe yet (0 features)" || die "the empty scaffold did not say so" "$out"
for f in analysis.md status-matrix.md source-index.tsv level; do
  [ -f "$EKB/$f" ] || die "the empty scaffold did not write $f"
done
[ "$(grep -vc '^#' "$EKB/source-index.tsv")" -eq 0 ] || die "the empty index is not empty"
grep -q "no source yet" "$EKB/analysis.md" || die "the empty survey does not say the tree is empty"
grep -q "grows as work orders close" "$EKB/analysis.md" || die "the empty survey does not say how it grows"
for L in lite standard full; do
  out="$(python3 "$KB_PY" status --root "$E" --kb "$EKB" --level "$L" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || die "status at $L on an empty knowledge base exited $rc, expected 0" "$out"
  echo "$out" | grep -q "^kb: 0 profiles — nothing to describe yet" || die "the empty summary line is wrong at $L" "$out"
done
# a knowledge base that is absent is still exit 3, not exit 0
rc=0; python3 "$KB_PY" status --root "$E" --kb "$E/Workspace/Docs/Nothing" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || die "a missing knowledge base exited $rc, expected 3"

# the first feature turns the empty base into a described one
mkdir -p "$E/src/auth"; printf 'export function login() { return true; }\n' > "$E/src/auth/login.ts"
out="$(python3 "$KB_PY" scaffold --root "$E" --kb "$EKB" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "re-scaffolding after the first feature exited $rc" "$out"
[ -f "$EKB/profiles/auth.md" ] || die "the first feature got no profile"
grep -q "no source yet" "$EKB/analysis.md" && die "the empty survey was not replaced once there was source"
rc=0; python3 "$KB_PY" status --root "$E" --kb "$EKB" --level standard >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] || die "status at standard on the new profile exited $rc, expected 4"
out="$(python3 "$KB_PY" status --root "$E" --kb "$EKB" --level standard 2>&1)"
echo "$out" | grep -q "^  profiles/auth.md" || die "the new profile was not named as short of standard" "$out"

exit 0
