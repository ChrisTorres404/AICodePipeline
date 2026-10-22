#!/usr/bin/env bash
# acp migrate plan never offers or suggests an answer apply would refuse, and predicts the ignored files its moves would
# make visible, offering the .gitignore lines that keep them ignored; apply adds those lines when the answer is yes, with
# its own check after the moves as the backstop. The plan and apply read one set of move rules (planned_moves), which
# gives what preflight gave before it was a function of its own.
set -uo pipefail
ACP="$PIPELINE_ROOT/bin/acp"; PY="$(command -v python3)"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global user.name t && git config --global user.email t@example.com && git config --global init.defaultBranch main \
  || { echo "FAIL setup: git identity"; exit 1; }
run() { perl -e 'alarm 300; exec @ARGV' "$@"; }
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
q() { "$PY" -c 'import json, sys; m = json.load(open(sys.argv[1])); exec(sys.argv[2])' "$1/.acp-migration/moves.json" "$2"; }

# L1-L3: a loose document whose place apply cannot file into is offered keep or delete, keep suggested; one it can is
# offered yes; no suggestion in the plan is one apply refuses
L="$EVAL_TMP/loose"
run "$PIPELINE_ROOT/bin/new-project" "$L/repo" --name Loose > "$EVAL_TMP/np1.log" 2>&1 || die "FAIL setup: new-project" "$(tail -2 "$EVAL_TMP/np1.log")"
( cd "$L" && mkdir specs && printf 's\n' > specs/a.md && printf 'w\n' > work-plan-a.md && printf 'f\n' > follow-ups.md && printf 'h\n' > handoff-a.md ) \
  || die "FAIL setup: loose documents"
run "$ACP" migrate plan --project "$L" --repo "$L/repo" > "$EVAL_TMP/plan1.log" 2>&1 || die "FAIL setup: plan" "$(tail -2 "$EVAL_TMP/plan1.log")"
q "$L" '
qs = {q["about"]: q for q in m["questions"] if "loose work document" in q["question"]}
for a in ("specs", "work-plan-a.md", "follow-ups.md"):
    assert qs[a]["options"] == ["keep where it is", "delete"] and qs[a]["suggested"] == "keep where it is", a
assert qs["handoff-a.md"]["options"] == ["yes", "delete", "keep where it is"] and qs["handoff-a.md"]["suggested"] == "yes"
' || die "FAIL L1: a loose document was offered or suggested an answer apply would refuse, or one it files was not offered yes"
q "$L" 'assert m["suggestions_apply_refuses"] == [], m["suggestions_apply_refuses"]' || die "FAIL L2: the plan suggests an answer apply would refuse" "$(q "$L" 'print(m["suggestions_apply_refuses"])')"
# L3b: beside the repository, apply's own step 0 judges the suggestions too: one made to suggest yes for a by-hand
# place is caught
"$PY" - "$PIPELINE_ROOT/core/hooks/migrate.py" "$L" > "$EVAL_TMP/l3b.txt" 2>&1 <<'PY' || die "FAIL L3: beside the repository, a suggestion apply would refuse was not found" "$(tail -3 "$EVAL_TMP/l3b.txt")"
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("mig", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
data = json.load(open(sys.argv[2] + "/.acp-migration/moves.json"))
pl = m.Plan(sys.argv[2], sys.argv[2] + "/repo"); pl.entries = data["entries"]; pl.questions = data["questions"]
sq = next(x for x in pl.questions if x.get("about") == "specs"); sq["options"] = ["yes", "delete", "keep where it is"]; sq["suggested"] = "yes"
m.check_suggestions(pl, open(sys.argv[2] + "/repo/pipeline.config.sh").read(), data["branch"], data["head"])
assert any("has no folder to go to" in x for x in pl.suggestion_problems), pl.suggestion_problems
PY
# L3: a suggestion apply would refuse is found and shown. Loose documents at the repository's own root are judged by
# apply's move rules (planned_moves); a moves.json made to suggest yes for one whose place is by hand is caught
RT="$EVAL_TMP/root"
run "$PIPELINE_ROOT/bin/new-project" "$RT" --name Root > "$EVAL_TMP/np4.log" 2>&1 || die "FAIL setup: new-project" "$(tail -2 "$EVAL_TMP/np4.log")"
( cd "$RT" && printf 'w\n' > work-plan-a.md && printf 'f\n' > follow-ups.md && printf 'h\n' > handoff-a.md \
  && mkdir -p tests/WO-0042-fixture && printf 'x\n' > tests/WO-0042-fixture/x.md && git add -A && git commit -qm docs ) || die "FAIL setup: root documents"
( cd "$RT" && run "$ACP" migrate plan > "$EVAL_TMP/plan4.log" 2>&1 ) || die "FAIL setup: plan" "$(tail -2 "$EVAL_TMP/plan4.log")"
q "$RT" '
qs = {q["about"]: q for q in m["questions"] if "loose work document" in q["question"]}
assert qs["follow-ups.md"]["options"] == ["keep where it is", "delete"] and qs["handoff-a.md"]["suggested"] == "yes", qs
assert m["suggestions_apply_refuses"] == [], m["suggestions_apply_refuses"]
' || die "FAIL L3: at the repository root, a loose document was offered yes into a place apply cannot file into, or a suggestion apply refuses was kept"
"$PY" - "$PIPELINE_ROOT/core/hooks/migrate.py" "$RT" > "$EVAL_TMP/l3.txt" 2>&1 <<'PY' || die "FAIL L3: a suggestion apply would refuse was not found" "$(tail -3 "$EVAL_TMP/l3.txt")"
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("mig", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
data = json.load(open(sys.argv[2] + "/.acp-migration/moves.json"))
pl = m.Plan(sys.argv[2], sys.argv[2]); pl.entries = data["entries"]; pl.questions = data["questions"]
fq = next(x for x in pl.questions if x.get("about") == "follow-ups.md"); fq["options"] = ["yes", "delete", "keep where it is"]; fq["suggested"] = "yes"
m.check_suggestions(pl, open(sys.argv[2] + "/pipeline.config.sh").read(), data["branch"], data["head"])
assert any("has no folder to go to" in x for x in pl.suggestion_problems), pl.suggestion_problems
PY

# S1: an order-shaped folder inside the product is suggested import, app still offered; a suggestion of app, which leaves
# it in the code folder where acp doctor fails it, is caught as one apply's checks would not take
q "$RT" '
oq = [x for x in m["questions"] if x.get("about") == "tests/WO-0042-fixture"]
assert len(oq) == 1 and oq[0]["options"] == ["import", "app"] and oq[0]["suggested"] == "import", oq
assert m["suggestions_apply_refuses"] == [], m["suggestions_apply_refuses"]
' || die "FAIL S1: an order-shaped folder inside the product was not suggested import (app still offered)" "$(q "$RT" 'print([x for x in m["questions"] if "order folder" in x["question"]])')"
"$PY" - "$PIPELINE_ROOT/core/hooks/migrate.py" "$RT" > "$EVAL_TMP/s1.txt" 2>&1 <<'PY' || die "FAIL S1: a suggestion that leaves an order folder in app/ was not caught" "$(tail -3 "$EVAL_TMP/s1.txt")"
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("mig", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
data = json.load(open(sys.argv[2] + "/.acp-migration/moves.json"))
pl = m.Plan(sys.argv[2], sys.argv[2]); pl.entries = data["entries"]; pl.questions = data["questions"]
oq = next(x for x in pl.questions if x.get("about") == "tests/WO-0042-fixture"); oq["suggested"] = "app"
m.check_suggestions(pl, open(sys.argv[2] + "/pipeline.config.sh").read(), data["branch"], data["head"])
assert any("acp doctor fails" in x and "tests/WO-0042-fixture" in x for x in pl.suggestion_problems), pl.suggestion_problems
PY

# G1-G4: ignored files the moves would make visible are predicted, with their lines; yes keeps them ignored, no is caught
G="$EVAL_TMP/gi"
run "$PIPELINE_ROOT/bin/new-project" "$G" --name Gi > "$EVAL_TMP/np2.log" 2>&1 || die "FAIL setup: new-project" "$(tail -2 "$EVAL_TMP/np2.log")"
# a nested .gitignore that moves with its folder (src/), an ignored file only apply's own *.log line keeps ignored
# (build.log: the root .gitignore names it anchored, and holds no *.log), and docs/, whose move is decided by its answer
( cd "$G" && mkdir -p src reports docs && printf 'print(1)\n' > src/main.py && printf 'd\n' > docs/d.md && printf 'local.cfg\n' > src/.gitignore \
  && printf 'x\n' > src/local.cfg && grep -vxF '*.log' .gitignore > .gitignore.new && mv .gitignore.new .gitignore \
  && printf '/reports/\n/coverage.out\n/build.log\n' >> .gitignore && printf 'b\n' > build.log \
  && printf 'r\n' > reports/r.txt && printf 'c\n' > coverage.out && git add -A && git commit -qm product \
  && git init -q --bare "$EVAL_TMP/gi-remote.git" && git remote add origin "$EVAL_TMP/gi-remote.git" && git push -q -u origin main 2>/dev/null ) || die "FAIL setup: product"
cp -R "$G" "$EVAL_TMP/gi-no" && cp -R "$EVAL_TMP/gi-remote.git" "$EVAL_TMP/gi-no-remote.git" && git -C "$EVAL_TMP/gi-no" remote set-url origin "$EVAL_TMP/gi-no-remote.git" || die "FAIL setup: copy"
plan_answer() { # <project> [answer for the .gitignore question]: plan, back up, answer every question (its suggestion)
  ( cd "$1" && run "$ACP" migrate plan > "$EVAL_TMP/p.log" 2>&1 && mkdir -p "$1.bk" && run "$ACP" migrate backup --to "$1.bk" > "$EVAL_TMP/b.log" 2>&1 ) \
    || die "FAIL setup: plan or backup in $1" "$(tail -2 "$EVAL_TMP/p.log" "$EVAL_TMP/b.log")"
  "$PY" -c 'import json, sys
m = json.load(open(sys.argv[1])); gq = (m.get("gitignore_add") or {}).get("question")
for x in m["questions"]: print(x["n"], sys.argv[2] if x["n"] == gq and sys.argv[2] else x["suggested"])' "$1/.acp-migration/moves.json" "${2:-}" > "$EVAL_TMP/ans" \
    || die "FAIL setup: the questions of $1 could not be read"
  while read -r n v; do ( cd "$1" && run "$ACP" migrate answer "$n" "$v" > /dev/null 2>&1 ) || die "FAIL setup: answer $n"; done < "$EVAL_TMP/ans"
}
plan_answer "$G"
q "$G" '
ga = m["gitignore_add"]; qq = [x for x in m["questions"] if x["n"] == ga["question"]][0]
assert ga["lines"] == ["/app/coverage.out", "/app/reports/"] and ga["files"] == 2, ga
assert qq["options"] == ["yes", "no"] and qq["suggested"] == "yes" and qq["question"].endswith("\n/app/coverage.out\n/app/reports/"), qq
' || die "FAIL G1: the plan did not predict the files the moves make visible, with the lines that keep them ignored" "$(q "$G" 'print(m.get("gitignore_add"))')"
grep -qxF '/app/reports/' "$G/.acp-migration/MIGRATION-PLAN.md" || die "FAIL G1: MIGRATION-PLAN.md does not show the lines"
out="$(cd "$G" && run "$ACP" migrate apply 2>&1)" || die "FAIL G2: apply with the lines answered yes did not commit" "$out"
why=""
grep -qxF '/app/coverage.out' "$G/.gitignore" && grep -qxF '/app/reports/' "$G/.gitignore" || why="$why the lines are not in .gitignore;"
git -C "$G" check-ignore -q app/coverage.out || why="$why app/coverage.out is not ignored;"
git -C "$G" check-ignore -q app/reports/r.txt || why="$why app/reports/r.txt is not ignored;"
git -C "$G" check-ignore -q app/src/local.cfg || why="$why app/src/local.cfg is not ignored;"
git -C "$G" check-ignore -q app/build.log || why="$why app/build.log is not ignored;"
[ -z "$(git --no-optional-locks -C "$G" status --porcelain)" ] || why="$why the tree is not clean ($(git --no-optional-locks -C "$G" status --porcelain | head -3 | tr '\n' ' '));"
[ "$(git -C "$G" show --name-only --format= HEAD | grep -cxF .gitignore)" = 1 ] || why="$why .gitignore is not in apply's commit;"   # -c reads to the end: -q would close the pipe under pipefail
[ -z "$why" ] || die "FAIL G2: after apply the moved files are not kept ignored by the committed lines:$why"
# G3: answered no, the moves would leave them visible, and apply's own check refuses as before, changing nothing
plan_answer "$EVAL_TMP/gi-no" no
h0="$(git -C "$EVAL_TMP/gi-no" rev-parse HEAD)"
rc=0; out="$(cd "$EVAL_TMP/gi-no" && run "$ACP" migrate apply 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'after the moves git no longer ignores' <<< "$out" && [ "$(git -C "$EVAL_TMP/gi-no" rev-parse HEAD)" = "$h0" ] \
  && [ -f "$EVAL_TMP/gi-no/coverage.out" ] && [ ! -e "$EVAL_TMP/gi-no/app" ]; } || die "FAIL G3: with the lines answered no, apply's own check did not catch the visible files and put every move back" "exit $rc" "$out"
# G4: patterns that still match at the new place (unanchored) make no question
U="$EVAL_TMP/un"
run "$PIPELINE_ROOT/bin/new-project" "$U" --name Un > "$EVAL_TMP/np3.log" 2>&1 || die "FAIL setup: new-project"
( cd "$U" && mkdir -p src && printf 'print(1)\n' > src/main.py && printf 'coverage.out\n' >> .gitignore && printf 'c\n' > coverage.out \
  && git add -A && git commit -qm product ) || die "FAIL setup: product"
( cd "$U" && run "$ACP" migrate plan > /dev/null 2>&1 ) || die "FAIL setup: plan"
q "$U" 'assert "gitignore_add" not in m and m["suggestions_apply_refuses"] == [], m.get("gitignore_add")' || die "FAIL G4: a question about .gitignore lines was asked where the moves leave every ignored file ignored"
# E1: planned_moves gives exactly what preflight's own block gave (recorded from be1bfab, before the extraction)
cat > "$EVAL_TMP/harness.py" <<'HARNESS'
"""planned_moves over a table of cases, one per branch of its rules: prints one line per case, the moves and the
entries beside the repository, or the refusal. Usage: moves-harness.py <migrate.py> [function-name]"""
import importlib.util, json, os, sys, tempfile
spec = importlib.util.spec_from_file_location("migrate_under_test", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fn = getattr(m, sys.argv[2] if len(sys.argv) > 2 else "planned_moves")
repo = tempfile.mkdtemp(prefix="moves.")
for d in ("src", "docs", ".aicodepipeline/bin", "tools", "specs", "Workspace/Docs/WorkOrders"):
    os.makedirs(os.path.join(repo, d), exist_ok=True)
for f in ("pipeline.config.sh", "README.md", "handoff-a.md", "work-plan-a.md", "Makefile", "WO-0007-x/WO-0007-SPEC.md"):
    os.makedirs(os.path.dirname(os.path.join(repo, f)) or repo, exist_ok=True); open(os.path.join(repo, f), "w").write("x\n")
E = lambda path, kind, to="", q=None: dict({"path": path, "kind": kind, "to": to, "bytes": 1, "note": ""}, **({"question": q} if q else {}))
cases = [
    ("product", [E("src", "product", "app/")], {}),
    ("pipeline", [E(".aicodepipeline", "pipeline", "acp/"), E("pipeline.config.sh", "pipeline", "acp/")], {}),
    ("tool-bound refused", [E("Makefile", "tool-bound", "(root)", 1)], {1: "app"}),
    ("tool-bound root", [E("Makefile", "tool-bound", "(root)", 1)], {1: "root"}),
    ("either acp", [E("tools", "either", "(owner)", 1)], {1: "acp"}),
    ("loose keep and delete", [E("work-plan-a.md", "loose", "regenerated (dropped)", 1), E("specs", "loose", "each order's SPEC (by hand)", 2)], {1: "keep where it is", 2: "delete"}),
    ("loose yes refused", [E("specs", "loose", "each order's SPEC (by hand)", 1)], {1: "yes"}),
    ("loose yes filed", [E("handoff-a.md", "loose", "acp/Workspace/Sessions/archive/", 1)], {1: "yes"}),
    ("beside the repository", [E("../notes", "residue", "acp/Workspace/Testing/logs/")], {}),
    ("stray order imported", [E("WO-0007-x", "stray-order", "(owner)", 1)], {1: "import"}),
    ("unknown kind", [E("docs", "something-new", "?")], {}),
    ("no longer there", [E("gone", "product", "app/")], {}),
]
for name, entries, answers in cases:
    try:
        moves, outside = fn(repo, ".", {"entries": entries}, answers, "Workspace/Docs/WorkOrders", "Workspace/Docs/Bugs", ".aicodepipeline")
        print("%s: moves %s; beside %s" % (name, json.dumps(moves), json.dumps([o["path"] for o in outside])))
    except m.Refusal as e:
        print("%s: refused: %s" % (name, e))
HARNESS
cat > "$EVAL_TMP/goldens.txt" <<'GOLDENS'
product: moves [["src", "app/src"]]; beside []
pipeline: moves [[".aicodepipeline", "acp/.aicodepipeline"]]; beside []
tool-bound refused: refused: question 1: `Makefile` is read by tools at the repository root, so it stays there; answer root
tool-bound root: moves []; beside []
either acp: moves [["tools", "acp/tools"]]; beside []
loose keep and delete: moves []; beside ["specs"]
loose yes refused: refused: question 1: `specs` has no folder to go to (each order's SPEC (by hand)); answer 'keep where it is' or 'delete'
loose yes filed: moves [["handoff-a.md", "acp/Workspace/Sessions/archive/handoff-a.md"]]; beside []
beside the repository: moves []; beside ["../notes"]
stray order imported: moves [["WO-0007-x", "Workspace/Docs/WorkOrders/WO-0007-x"]]; beside []
unknown kind: refused: `docs` is planned as something-new, which apply does not know; plan again with this ACP
no longer there: refused: `gone` is no longer there; plan again
GOLDENS
TMPDIR="$EVAL_TMP/" "$PY" -I "$EVAL_TMP/harness.py" "$PIPELINE_ROOT/core/hooks/migrate.py" > "$EVAL_TMP/moves.txt" 2>&1   || die "FAIL E1: planned_moves could not be run over the cases" "$(tail -3 "$EVAL_TMP/moves.txt")"
diff "$EVAL_TMP/goldens.txt" "$EVAL_TMP/moves.txt" > "$EVAL_TMP/moves.diff" || die "FAIL E1: planned_moves does not give what preflight gave" "$(head -8 "$EVAL_TMP/moves.diff")"

echo "migrate-plan-apply-accepts: all checks passed"
exit 0
