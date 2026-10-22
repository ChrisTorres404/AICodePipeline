#!/usr/bin/env bash
# acp migrate plan never files private or knowledge-base material found beside the work orders with the logs inside the
# project: an item that holds a private-looking name (profiles, a setup file, a restore note, a shared package, a zip) or
# a knowledge-base-shaped folder, at any depth, is its own entry with its own question, suggesting the private folder,
# and the private folder is asked for; nothing of it is dropped; a knowledge base is named before zips. Plain logs, and
# a link to a knowledge base outside (never followed), stay residue. An unknown item alone also asks for the folder.
set -uo pipefail
ACP="$PIPELINE_ROOT/bin/acp"; PY="$(command -v python3)"
G() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
P="$EVAL_TMP/proj"; R="$P/eng"; J="$P/.acp-migration/moves.json"; W="$P/work"
mkdir -p "$R/src" && G -C "$R" init -q && : > "$R/pipeline.config.sh" && printf 'x\n' > "$R/src/a.py" && G -C "$R" add -A && G -C "$R" commit -qm base \
  || { echo "FAIL setup: repository"; exit 1; }
mkdir -p "$W/WO-0001-alpha" "$W/logs" "$W/builder1/deep/profiles" "$W/notes" "$W/bundles" "$W/cfg" "$W/kbx/inner" "$W/kb-old/profiles" \
  && printf 'o\n' > "$W/WO-0001-alpha/WO-0001-Prompt.md" && printf 'l\n' > "$W/logs/run.log" && printf 'p\n' > "$W/builder1/deep/profiles/p.md" \
  && printf 'r\n' > "$W/notes/RESTORE-steps.md" && printf 'z' > "$W/bundles/pkg.zip" && printf 'c: 1\n' > "$W/cfg/client.setup.yaml" \
  && printf 'i\n' > "$W/kbx/inner/source-index.tsv" && printf 'k\n' > "$W/kb-old/profiles/k.md" && printf 's\n' > "$W/scratch.txt" \
  || { echo "FAIL setup: work folder"; exit 1; }
mkdir -p "$W/mixed/z-kb" && for z in a b c d e f; do printf 'z' > "$W/mixed/$z.zip"; done && printf 'i\n' > "$W/mixed/z-kb/source-index.tsv" \
  && mkdir -p "$EVAL_TMP/outside-kb/profiles" "$W/refs" && printf 'k\n' > "$EVAL_TMP/outside-kb/profiles/k.md" && ln -s "$EVAL_TMP/outside-kb" "$W/refs/kblink" \
  || { echo "FAIL setup: mixed and linked"; exit 1; }
out="$(cd "$P" && perl -e 'alarm 60; exec @ARGV' "$ACP" migrate plan 2>&1)" || { echo "FAIL setup: plan: $out"; exit 1; }
kind() { "$PY" -c 'import json, sys; e = [x for x in json.load(open(sys.argv[1]))["entries"] if x["path"] == sys.argv[2]]; print(e[0]["kind"] if len(e) == 1 else "missing")' "$J" "$1"; }
# R1: every item holding private or knowledge-base material is its own entry, never residue (and never dropped)
for x in work/builder1 work/notes work/bundles work/cfg work/kbx work/kb-old work/mixed; do
  k="$(kind "$x")"; [ "$k" = private-residue ] || { echo "FAIL R1: $x holds private or knowledge-base material and was planned as $k"; exit 1; }
done
# R2: plain logs and scratch stay residue, and so does a folder whose only link leads to a knowledge base outside
for x in work/logs work/scratch.txt work/refs; do k="$(kind "$x")"; [ "$k" = residue ] || { echo "FAIL R2: $x is plain residue and was planned as $k"; exit 1; }; done
# R3: each such entry has its own question, options private folder / logs / delete, suggesting the private folder, naming
# what was found; the private folder itself is asked for
"$PY" - "$J" <<'PYEOF' || exit 1
import json, sys
d = json.load(open(sys.argv[1])); qs = {q["n"]: q for q in d["questions"]}
held = [e for e in d["entries"] if e["kind"] == "private-residue"]
ns = [e.get("question") for e in held]
if len(set(ns)) != len(held) or not all(n in qs for n in ns): print("FAIL R3: each private or knowledge-base item does not have its own question"); sys.exit(1)
for e in held:
    q = qs[e["question"]]
    if q["options"] != ["private folder", "logs", "delete"] or q["suggested"] != "private folder" or q.get("about") != e["path"]:
        print(f"FAIL R3: the question for {e['path']} is not private folder / logs / delete suggesting the private folder: {q}"); sys.exit(1)
want = {"work/builder1": "builder1/deep/profiles", "work/notes": "notes/RESTORE-steps.md", "work/bundles": "bundles/pkg.zip",
        "work/cfg": "cfg/client.setup.yaml", "work/kbx": "kbx/inner", "work/kb-old": "kb-old/profiles", "work/mixed": "(7 found: mixed/z-kb, mixed/a.zip"}
for e in held:
    if want[e["path"]] not in qs[e["question"]]["question"]: print(f"FAIL R3: the question for {e['path']} does not name {want[e['path']]}"); sys.exit(1)
if not [q for q in d["questions"] if q["options"] == ["<a folder outside the project>"]]: print("FAIL R3: the private folder is not asked for"); sys.exit(1)
if any(e["kind"] == "kb-snapshot" and e["path"].startswith("work/") for e in d["entries"]): print("FAIL R3: a knowledge-base folder beside the orders was dropped"); sys.exit(1)
PYEOF
# R5: an unknown item, with nothing private, still asks for the private folder: "private folder" is one of its options
U="$EVAL_TMP/proj2"; mkdir -p "$U/eng" && G -C "$U/eng" init -q && : > "$U/eng/pipeline.config.sh" && G -C "$U/eng" add -A && G -C "$U/eng" commit -qm b \
  && printf 'm\n' > "$U/mystery.bin" || { echo "FAIL setup: proj2"; exit 1; }
out="$(cd "$U" && perl -e 'alarm 60; exec @ARGV' "$ACP" migrate plan 2>&1)" || { echo "FAIL setup: plan 2: $out"; exit 1; }
"$PY" -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if any(e["kind"] == "unknown" for e in d["entries"]) and any(q["options"] == ["<a folder outside the project>"] for q in d["questions"]) else 1)' "$U/.acp-migration/moves.json" \
  || { echo "FAIL R5: an unknown item was planned without the private folder being asked for"; exit 1; }
# R4: the plan's markdown shows them as their own entries
grep -qF '| `work/builder1` | private-residue |' "$P/.acp-migration/MIGRATION-PLAN.md" || { echo "FAIL R4: MIGRATION-PLAN.md does not list work/builder1 as its own entry"; exit 1; }
exit 0
