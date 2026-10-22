#!/usr/bin/env bash
# migrate-plan-order-strays: acp migrate plan files each order's stray material into that order's folder, drops an
# exact copy of the order's own document, and asks about whatever it cannot place safely. Everything here is synthetic.
set -uo pipefail
ACP="$PIPELINE_ROOT/bin/acp"
G() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
die() { echo "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | tail -8; exit 1; }
P="$EVAL_TMP/proj"; R="$P/eng"; WO=Workspace/Docs/WorkOrders; BG=Workspace/Docs/Bugs
mkdir -p "$R" && G -C "$R" init -q || die "FAIL setup: git init"
printf 'export WORKORDERS_DIR="Workspace/Docs/WorkOrders"\nexport BUGS_DIR="Workspace/Docs/Bugs"\nexport PIPELINE_ROOT=".aicodepipeline"\n' > "$R/pipeline.config.sh"
mkdir -p "$R/.aicodepipeline/bin" "$R/src" && printf 'tool\n' > "$R/.aicodepipeline/bin/wo" && printf 'print(1)\n' > "$R/src/main.py"
for o in WO-0007-alpha WO-0008-beta; do id="${o%-*}"; mkdir -p "$R/$WO/$o" && printf '# spec %s\n' "$id" > "$R/$WO/$o/$id-SPEC.md" && printf 'status=open\n' > "$R/$WO/$o/.wo-meta"; done
printf '# notes already\n' > "$R/$WO/WO-0007-alpha/WO-0007-NOTES-1.md"; printf '# lower case\n' > "$R/$WO/WO-0007-alpha/WO-0007-notes-2.md"
: > "$R/$WO/WO-0008-beta/WO-0008-EMPTY.md"; mkdir -p "$R/$WO/WO-0008-beta/artifacts" && printf 'old\n' > "$R/$WO/WO-0008-beta/artifacts/WO-0008.out"
mkdir -p "$R/$BG/BUG-0100-crash" && printf '# crash\n' > "$R/$BG/BUG-0100-crash/BUG-0100-crash.md" && printf 'status=open\n' > "$R/$BG/BUG-0100-crash/.bug-meta"
{ G -C "$R" add -A && G -C "$R" commit -qm base; } >/dev/null 2>&1 || die "FAIL setup: commit"
w="$P/work"; mkdir -p "$w"
printf '# n\n' > "$w/WO-0007-notes.md"; printf '# h\n' > "$w/WO-0007-handoff.md"; printf '# d\n' > "$w/wo-0008-draft.md"
mkdir -p "$w/wo-0007-logs" && printf 'run\n' > "$w/wo-0007-logs/run1.log"; printf 'o\n' > "$w/WO-0008.out"; printf 'a\n' > "$w/WO-0007-list.txt"
mkdir -p "$w/WO-0007-scratch" && printf 'x\n' > "$w/WO-0007-scratch/x.sh"; mkdir -p "$w/WO-0008-review" && printf 'r\n' > "$w/WO-0008-review/r.md"; printf 'p\n' > "$w/WO-0007.patch"
cp "$R/$WO/WO-0007-alpha/WO-0007-SPEC.md" "$w/WO-0007-copy.md"; printf '# different\n' > "$w/WO-0007-SPEC.md"; : > "$w/WO-0008-empty.log"
mkdir -p "$w/WO-0000-placeholder" && printf 's\n' > "$w/WO-0000-placeholder/WO-0000-SPEC.md"
printf 'p\n' > "$w/wo-0000-notes.md"   # a placeholder that is a file: numbered after the folder's
mkdir -p "$w/WO-0009-new" && printf 'n\n' > "$w/WO-0009-new/WO-0009-SPEC.md"   # an order only outside: imported, so the placeholder skips it
mkdir -p "$w/wo-0999-logs" && printf 'l\n' > "$w/wo-0999-logs/a.log"; printf 'b\n' > "$w/bug-0001-notes.md"; printf 'n\n' > "$w/0007-misc.txt"
printf 'c\n' > "$w/WO-0007-vs-WO-0008.md"
mkdir -p "$w/runs/nightly" && printf 'r\n' > "$w/runs/nightly/wo-0007-alpha.log" && printf 'r\n' > "$w/runs/nightly/wo-0008-beta.log" && printf 'r\n' > "$w/runs/nightly/summary.txt"
# the key-shaped line and the key file's name are built here, so this file holds neither
printf 'key=%s%s\n' AKIA ABCDEFGHIJKLMNOP > "$w/runs/nightly/wo-0008-secret.log"; printf 'k\n' > "$w/WO-0007-deploy.$(printf '%s%s' pe m)"
printf 'SECRET_KEY=%s\n' 0123456789abcdefABCDEF0123456789abcdef > "$w/runs/nightly/wo-0007-env.log"   # sanitize's generic NAME=value row
mkdir -p "$w/suite-runs" && printf 'r\n' > "$w/suite-runs/bug-0100-crash.log"; printf 'tmp\n' > "$w/scratch.tmp"
for f in 2026-10-21-notes.md 20261001-run.log 2026-10.log 123-x.log 0007_x.py 2024; do printf 'd\n' > "$w/$f"; done
mkdir -p "$w/WO-0008-trial/WO-0007-alpha" && cp -R "$R/$WO/WO-0007-alpha/." "$w/WO-0008-trial/WO-0007-alpha/" && printf 't\n' > "$w/WO-0008-trial/run.log"
mkdir -p "$P/work2" && printf 'o2\n' > "$P/work2/WO-0008.out"
mkdir -p "$P/notes" && printf '# n2\n' > "$P/notes/WO-0008-notes.md"                    # a folder with no order copy in it
# S20: a copy that differs, in a folder planned after the top, carries in WO-0008-NOTES-1.md; a stray note at the top
# must not be given that name
mkdir -p "$P/zcopies/WO-0008-beta" && cp -R "$R/$WO/WO-0008-beta/." "$P/zcopies/WO-0008-beta/" && printf '# copy only\n' > "$P/zcopies/WO-0008-beta/WO-0008-NOTES-1.md" && printf '# changed\n' > "$P/zcopies/WO-0008-beta/WO-0008-SPEC.md"
printf '# top\n' > "$P/WO-0008-topnote.md"
# S21: a private-named folder (and a knowledge base) is never broken apart, even holding a named item
mkdir -p "$w/team/profiles" && printf '# p\n' > "$w/team/profiles/WO-0007-notes.md" && printf 'x\n' > "$w/team/profiles/other.txt"
# S23: an item for an order the repository lacks, holding a key line: the private folder is suggested, and why
printf 'k=%s%s\n' AKIA ZYXWVUTSRQPONMLK > "$w/wo-0998-key.log"
# S24: a binary item (not a picture) is not read for secrets, and asked
printf 'BIN\000\001\002' > "$w/wo-0007-dump.bin"
# S27, S28: a file not read never hides a later one: a binary file before a key line, in a residue folder and in a
# folder named for an order (which names the key's file, not the binary)
mkdir -p "$w/runs2" && printf 'B\000\001' > "$w/runs2/01-blob.bin" && printf 'k=%s%s\n' AKIA MNBVCXZLKJHGFDSA > "$w/runs2/env.log"
mkdir -p "$w/WO-0008-review2" && printf 'B\000\001' > "$w/WO-0008-review2/01-blob.bin" && printf 'k=%s%s\n' AKIA POIUYTREWQLKJHGF > "$w/WO-0008-review2/env.log"
# S29: a residue text file over 50 MB is asked, not read; a binary one stays residue
python3 -c 'import sys; f = open(sys.argv[1], "w"); f.write("log line\n" * 1000); f.truncate(51 << 20)' "$w/huge.txt"
printf 'B\000\001' > "$w/blob.bin"
# S31: a binary file sorted first does not hide a text file over 50 MB after it: the folder is asked
mkdir -p "$w/mix" && printf 'B\000\001' > "$w/mix/a.db"
python3 -c 'import sys; f = open(sys.argv[1], "w"); f.write("log line\n" * 1000); f.truncate(60 << 20)' "$w/mix/b-huge.log"
# S30: a folder named for an order holding only pictures is filed, not asked for being binary
mkdir -p "$w/WO-0007-shots" && printf 'PNG\000\001' > "$w/WO-0007-shots/a.png" && printf 'J\000\001' > "$w/WO-0007-shots/b.jpg"
# S25: a folder mostly of bare numbers is a sequence (frames), residue, not one question per frame
mkdir -p "$w/frames" && for i in 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 0011; do printf 'f\n' > "$w/frames/$i.png"; done
# S26: a residue file holding a key line is asked, never filed with the logs
printf 'token=%s%s\n' AKIA QWERTYUIOPASDFGH > "$w/deploy-notes.txt"
printf 'e\n' > "$P/WO-0008-extra.txt"; printf 'top\n' > "$P/WO-0008.out"; mkdir -p "$P/2024-taxes" && printf 't\n' > "$P/2024-taxes/t.txt"
out="$(perl -e 'alarm 60; exec @ARGV' "$ACP" migrate plan --project "$P" 2>&1)" || die "FAIL setup: acp migrate plan" "$out"
check() { python3 -I - "$P/.acp-migration/moves.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); E = {e["path"]: e for e in d["entries"]}; Q = {q["n"]: q for q in d["questions"]}
want = [  # (step, path, kind, file_as or None, id or None)
    ("S1", "work/WO-0007-notes.md", "order-note", "WO-0007-NOTES-3.md", "WO-0007"),   # after NOTES-1 and notes-2, without case
    ("S20", "WO-0008-topnote.md", "order-note", "WO-0008-NOTES-2.md", "WO-0008"),      # NOTES-1 comes in with the copy
    ("S23", "work/wo-0998-key.log", "order-missing", None, None),
    ("S24", "work/wo-0007-dump.bin", "order-private", None, "WO-0007"),
    ("S28", "work/WO-0008-review2", "order-private", None, "WO-0008"),
    ("S30", "work/WO-0007-shots", "order-artifact", "artifacts/work/WO-0007-shots", "WO-0007"),
    ("S1", "work/WO-0007-handoff.md", "order-note", "WO-0007-HANDOFF-1.md", "WO-0007"),
    ("S1", "work/wo-0008-draft.md", "order-note", "WO-0008-DRAFT-1.md", "WO-0008"),
    ("S2", "work/wo-0007-logs", "order-artifact", "artifacts/work/wo-0007-logs", "WO-0007"),
    ("S2", "work/WO-0007-list.txt", "order-artifact", "artifacts/work/WO-0007-list.txt", "WO-0007"),
    ("S2", "work/WO-0007.patch", "order-artifact", "artifacts/work/WO-0007.patch", "WO-0007"),
    ("S3", "work/WO-0007-scratch", "order-artifact", "artifacts/work/WO-0007-scratch", "WO-0007"),
    ("S3", "work/WO-0008-review", "order-artifact", "artifacts/work/WO-0008-review", "WO-0008"),
    ("S4", "work/runs/nightly/wo-0007-alpha.log", "order-artifact", "artifacts/work/runs/nightly/wo-0007-alpha.log", "WO-0007"),
    ("S4", "work/suite-runs/bug-0100-crash.log", "order-artifact", "artifacts/work/suite-runs/bug-0100-crash.log", "BUG-0100"),
    ("S5", "work/WO-0007-copy.md", "order-duplicate", None, "WO-0007"),
    ("S6", "work/WO-0000-placeholder", "outside-order-placeholder", None, "WO-0000"),
    ("S6", "work/wo-0000-notes.md", "order-placeholder", None, None),
    ("S6", "work/wo-0999-logs", "order-missing", None, None),
    ("S6", "work/bug-0001-notes.md", "order-missing", None, None),
    ("S6", "work/0007-misc.txt", "order-ambiguous", None, None),
    ("S9", "WO-0008-extra.txt", "order-artifact", "artifacts/WO-0008-extra.txt", "WO-0008"),
    ("S10", "work/WO-0008.out", "order-artifact", "artifacts/work/WO-0008.out", "WO-0008"),        # two folders, one name each
    ("S10", "work2/WO-0008.out", "order-artifact", "artifacts/work2/WO-0008.out", "WO-0008"),
    ("S10", "WO-0008.out", "order-clash", None, "WO-0008"),                                        # the order already has artifacts/WO-0008.out
    ("S13", "work/runs/nightly/wo-0008-secret.log", "order-private", None, "WO-0008"),
    ("S13", "work/WO-0007-deploy." + "pe" + "m", "order-private", None, "WO-0007"),
    ("S13", "work/runs/nightly/wo-0007-env.log", "order-private", None, "WO-0007"),
    ("S14", "work/WO-0007-vs-WO-0008.md", "order-ambiguous", None, None),
    ("S15", "notes/WO-0008-notes.md", "order-note", "WO-0008-NOTES-3.md", "WO-0008"),
    ("S19", "work/WO-0007-SPEC.md", "order-clash", None, "WO-0007"),
    ("S19", "work/WO-0008-empty.log", "order-artifact", "artifacts/work/WO-0008-empty.log", "WO-0008"),   # never a duplicate of an empty document
]
for step, path, kind, fa, oid in want:
    e = E.get(path)
    if not e or e["kind"] != kind: sys.exit(f"FAIL {step}: {path} is {e and e['kind']}, not {kind}")
    if fa and e.get("file_as") != fa: sys.exit(f"FAIL {step}: {path} is filed as {e.get('file_as')}, not {fa}")
    if oid and e.get("id") != oid: sys.exit(f"FAIL {step}: {path} is with {e.get('id')}, not {oid}")
    if not (e.get("digest") or {}).get("self"): sys.exit(f"FAIL S7: {path} carries no digest")
    if kind in ("order-placeholder", "outside-order-placeholder", "order-missing", "order-ambiguous", "order-clash", "order-private") and "question" not in e: sys.exit(f"FAIL {step}: {path} is not asked about")
fas = [e["file_as"].lower() for e in d["entries"] if "file_as" in e]
if len(fas) != len(set(fas)): sys.exit("FAIL S10: two entries are filed to the same place")
opts = lambda path: Q[E[path]["question"]]["options"]
if E["work/WO-0007-copy.md"].get("same_as") != "eng/Workspace/Docs/WorkOrders/WO-0007-alpha/WO-0007-SPEC.md": sys.exit("FAIL S5: the duplicate does not name the document it copies")
if opts("work/WO-0000-placeholder") != ["adopt as WO-0010", "retire", "private folder"]: sys.exit(f"FAIL S16: the placeholder's options are {opts('work/WO-0000-placeholder')}")
if opts("work/wo-0000-notes.md") != ["adopt as WO-0011", "logs", "private folder", "delete"]: sys.exit(f"FAIL S16: the file placeholder's options are {opts('work/wo-0000-notes.md')}")
q = Q[E["work/wo-0998-key.log"]["question"]]
if q["suggested"] != "private folder" or "may hold something private" not in q["question"]: sys.exit("FAIL S23: a key line in an item for a missing order does not suggest the private folder, saying why")
holder = [e for e in d["entries"] if "work/team/profiles/WO-0007-notes.md".startswith(e["path"] + "/")]
if "work/team/profiles/WO-0007-notes.md" in E or [e["kind"] for e in holder] != ["private-residue"]: sys.exit(f"FAIL S21: a private folder was broken apart ({[(e['path'], e['kind']) for e in holder]})")
if not any(q2["options"] == ["<a folder outside the project>"] for q2 in d["questions"]): sys.exit("FAIL S22: \"private folder\" is offered but the folder question is not asked")
if E.get("work/frames", {}).get("kind") != "residue": sys.exit(f"FAIL S25: a folder of numbered frames is {E.get('work/frames', {}).get('kind')}, not residue")
if E.get("work/deploy-notes.txt", {}).get("kind") != "private-residue": sys.exit(f"FAIL S26: a residue file holding a key line is {E.get('work/deploy-notes.txt', {}).get('kind')}")
if E.get("work/runs2", {}).get("kind") != "private-residue": sys.exit(f"FAIL S27: a key line after a binary file in a residue folder is {E.get('work/runs2', {}).get('kind')}")
q = Q[E["work/WO-0008-review2"]["question"]]["question"]
if "review2/env.log" not in q or "binary" in q: sys.exit("FAIL S28: the question does not name the key's file, or names the binary instead")
if E.get("work/huge.txt", {}).get("kind") != "private-residue" or "not scanned: larger than 50 MB" not in Q[E["work/huge.txt"]["question"]]["question"]: sys.exit(f"FAIL S29: a residue text file over 50 MB is {E.get('work/huge.txt', {}).get('kind')}, not asked as not scanned")
if E.get("work/mix", {}).get("kind") != "private-residue" or "mix/b-huge.log (not scanned: larger than 50 MB)" not in Q[E["work/mix"]["question"]]["question"]: sys.exit(f"FAIL S31: a binary file hides a text file over 50 MB after it: work/mix is {E.get('work/mix', {}).get('kind')}")
if E.get("work/blob.bin", {}).get("kind") != "residue": sys.exit(f"FAIL S29: a binary residue file is {E.get('work/blob.bin', {}).get('kind')}, not residue")
if opts("work/0007-misc.txt") != ["work order", "bug", "logs", "private folder", "delete"]: sys.exit(f"FAIL S6: the bare number's options are {opts('work/0007-misc.txt')}")
if opts("work/WO-0007-vs-WO-0008.md") != ["WO-0007", "WO-0008", "logs", "private folder", "delete"]: sys.exit("FAIL S14: two orders named are not both offered")
for path in ("work/runs/nightly/wo-0008-secret.log", "work/WO-0007-deploy." + "pe" + "m", "work/runs/nightly/wo-0007-env.log"):
    if Q[E[path]["question"]]["suggested"] != "private folder": sys.exit(f"FAIL S13: {path} does not suggest the private folder")
if E.get("2024-taxes", {}).get("kind") != "unknown" or "private folder" not in opts("2024-taxes"): sys.exit(f"FAIL S11: 2024-taxes is {E.get('2024-taxes', {}).get('kind')}")
if "work/WO-0008-trial" in E or E.get("work/WO-0008-trial/WO-0007-alpha", {}).get("kind", "").startswith("outside-order") is not True: sys.exit("FAIL S12: a folder named for an order and holding an order copy is an entry of its own, or the copy is not")
for path in ("work/runs/nightly/summary.txt", "work/scratch.tmp", "work/2026-10-21-notes.md", "work/20261001-run.log", "work/2026-10.log", "work/123-x.log", "work/0007_x.py", "work/2024", "work/WO-0008-trial/run.log"):   # S8
    if E.get(path, {}).get("kind") != "residue": sys.exit(f"FAIL S8: {path} is {E.get(path, {}).get('kind')}, not residue")
PY
}
r="$(check 2>&1)" || die "$r"
# S22: a second project whose only offer of "private folder" is an order question still gets the folder question
P2="$EVAL_TMP/proj2"; mkdir -p "$P2" && cp -R "$R" "$P2/eng" && mkdir -p "$P2/work" && printf 'l\n' > "$P2/work/wo-0999-only.log" || die "FAIL setup: second project"
out="$(perl -e 'alarm 60; exec @ARGV' "$ACP" migrate plan --project "$P2" 2>&1)" || die "FAIL setup: acp migrate plan (second project)" "$out"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(q["options"] == ["<a folder outside the project>"] for q in d["questions"]) else 1)' "$P2/.acp-migration/moves.json" \
  || die "FAIL S22: \"private folder\" is offered, and the folder question is not asked"
echo "migrate-plan-order-strays: all checks passed"
