#!/usr/bin/env bash
# acp doctor and acp check report what sits outside the project's layout: work outside the workspace, pipeline
# material in the code folder, one order in two places, a second knowledge base or pipeline copy, plan files and
# anything the layout does not name at the root. They only report; submodules and nested repositories are named,
# never looked into; a commit is judged on the files it touches.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
A="$PIPELINE_ROOT/bin/acp"
export HOME="$EVAL_TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$EVAL_TMP"; mkdir -p "$HOME"
git config --global user.name t && git config --global user.email t@example.com || die "the eval could not set a git identity"
has() { case "$out" in *"$1"*) return 0;; esac; return 1; }
m() { mkdir -p "$(dirname "$1")" && printf 'x\n' > "$1"; }
fp() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum | shasum); }
doc() { rc=0; out="$("$A" doctor "$1" 2>&1)" || rc=$?; }
chk() { local d="$1"; shift; rc=0; out="$(cd "$d" && "$A" check "$@" 2>&1)" || rc=$?; }
acpcfg() { cat > "$1/pipeline.config.sh" <<'CFG'
export PIPELINE_ROOT="acp/.aicodepipeline"
export WORKSPACE_DIR="acp/Workspace"
export WORKORDERS_DIR="acp/Workspace/Docs/WorkOrders"
export BUGS_DIR="acp/Workspace/Docs/Bugs"
export KNOWLEDGE_DIR="acp/Workspace/Docs/KnowledgeBase"
export CODE_DIR="app"
export PLAYBOOKS_DIR="acp/playbooks"
export LAYOUT_ROOT_EXTRA="netlify.toml"
CFG
}
clean_acp() { mkdir -p "$1" && git -C "$1" init -q && acpcfg "$1" && m "$1/app/src/x.js" && m "$1/acp/Workspace/Docs/WorkOrders/WO-0001-a/WO-0001-SPEC.md" \
  && printf 'size=small\n' > "$1/acp/Workspace/Docs/WorkOrders/WO-0001-a/.wo-meta" \
  && m "$1/acp/Workspace/Docs/KnowledgeBase/source-index.tsv" && m "$1/acp/.aicodepipeline/bin/wo" && m "$1/acp/.aicodepipeline/core/hooks/check.py" \
  && m "$1/acp/playbooks/auth/workorders/WO-0001-x/WO-0001-SPEC.md" && m "$1/app/src/components/Workspace/Button.tsx" \
  && m "$1/README.md" && m "$1/LICENSE" && m "$1/.github/workflows/ci.yml" && m "$1/.gitattributes" && m "$1/CLAUDE.md" && m "$1/AGENTS.md" \
  && m "$1/.mcp.json" && m "$1/.editorconfig" && m "$1/CODEOWNERS" && m "$1/CHANGELOG.md" && m "$1/CONTRIBUTING.md" && m "$1/SECURITY.md" \
  && m "$1/.acp-migration/moves.json" && m "$1/.gitlab-ci.yml" && m "$1/.gitlab/a.yml" && m "$1/.pre-commit-config.yaml" && m "$1/.vscode/s.json" \
  && m "$1/.devcontainer/d.json" && m "$1/.tool-versions" && m "$1/.idea/a.xml" && m "$1/netlify.toml" \
  && m "$1/.claude/settings.json" && m "$1/.claude/agents/a.md" && m "$1/.claude/skills/s/SKILL.md" && printf 'node_modules/\n' > "$1/.gitignore"; }
# (acp doctor stops with no message when .claude/agents is missing, a fault outside this order, so the
# stand-in install has both folders)

# L1: in the acp/ layout, acp doctor names each thing out of place, and fails
R="$EVAL_TMP/r"; clean_acp "$R" || die "the eval could not build a repository"
m "$R/work/WO-0001-b/WO-0001-SPEC.md"; m "$R/app/WO-0002-c/notes.md"; m "$R/app/old/Docs/WorkOrders/README.md"; m "$R/docs/KB/source-index.tsv"
m "$R/vendor/acp/bin/wo"; m "$R/vendor/acp/core/hooks/check.py"; m "$R/vendor/plug/bin/wo"; m "$R/vendor/plug/hooks/scripts/check.py"
m "$R/HANDOFF-1.md"; m "$R/.nvmrc"; m "$R/handoff/notes.txt"; m "$R/audit/report.md"; m "$R/app/HANDOFF.md"; m "$R/tests/WO-0001-suite.sh"; m "$R/app/pipeline.config.sh"
git -C "$R" add -A && git -C "$R" commit -q -m start || die "the eval could not commit"
git -C "$R" init -q nested && m "$R/nested/y"
before="$(fp "$R")"
doc "$R"
has "layout: work-outside work/WO-0001-b: a work order or bug outside the workspace acp/Workspace/" \
  || die "FAIL L1: acp doctor did not name a work order outside the workspace" "exit $rc" "$out"
has "layout: in-code app/WO-0002-c: a work order or bug inside the code folder app/" || die "FAIL L1: a work order in the code folder was not named" "$out"
has "layout: in-code app/old: a workspace inside the code folder app/" || die "FAIL L1: a workspace in the code folder was not named" "$out"
! has "layout: in-code app/src" || die "FAIL L1: a code folder named Workspace was taken for the workspace" "$out"
has "layout: in-code app/pipeline.config.sh: pipeline material inside the code folder app/" || die "FAIL L1: a config in the code folder was not named" "$out"
has "layout: in-code app/HANDOFF.md: a plan, handoff or audit file in the code folder app/" || die "FAIL L1: a handoff file in the code folder was not named" "$out"
has "layout: duplicate work/WO-0001-b: WO-0001 is in 2 places" || die "FAIL L1: one order in two places was not named by its stray copy" "$out"
has "layout: second-kb docs/KB: a second knowledge base" || die "FAIL L1: a second knowledge base was not named" "$out"
has "layout: second-copy vendor/acp: a second copy of the pipeline" || die "FAIL L1: a second pipeline copy was not named" "$out"
has "layout: second-copy vendor/plug: a second copy of the pipeline" || die "FAIL L1: a built plugin copy was not named" "$out"
has "layout: top-level HANDOFF-1.md: a plan, handoff or audit file at the root" || die "FAIL L1: a handoff file at the root was not named" "$out"
{ has "layout: top-level handoff: a plan, handoff or audit file at the root" && has "layout: top-level audit: a plan, handoff or audit file at the root"; } \
  || die "FAIL L1: a plan or handoff folder at the root was not named" "$out"
has "layout: top-level vendor: not part of the layout at the root; move it into app/ (the code) or acp/ (the work)" \
  && has "layout: top-level docs: not part of the layout at the root" && has "layout: top-level .nvmrc: not part of the layout at the root" \
  || die "FAIL L1: a folder or file the layout does not name at the root was not named" "$out"
has "layout: not-looked-into nested: a submodule or nested repository; not looked into" || die "FAIL L1: a nested repository was not named" "$out"
# L2: what the layout names at the root is never reported
for x in README.md LICENSE .github .gitattributes CLAUDE.md AGENTS.md .claude .gitignore pipeline.config.sh app acp \
  .mcp.json .editorconfig CODEOWNERS CHANGELOG.md CONTRIBUTING.md SECURITY.md .acp-migration .gitlab-ci.yml .gitlab \
  .pre-commit-config.yaml .vscode .devcontainer .tool-versions .idea netlify.toml; do
  ! has "layout: top-level $x:" || die "FAIL L2: the root entry $x, which the layout allows, was reported" "$out"
done
# N1: acp doctor writes nothing: the repository, its .git folder included, is byte-identical
[ "$(fp "$R")" = "$before" ] || die "FAIL N1: acp doctor changed the repository"
# L3: a submodule is named and not looked into
S="$EVAL_TMP/s"; clean_acp "$S" && git -C "$S" add -A && git -C "$S" commit -q -m start \
  && git -C "$S" update-index --add --cacheinfo "160000,$(git -C "$S" rev-parse HEAD),app/lib" || die "the eval could not make a submodule entry"
doc "$S"
has "layout: not-looked-into app/lib: a submodule or nested repository" || die "FAIL L3: a submodule was not named" "$out"
# L4: a clean acp/ layout passes
C="$EVAL_TMP/c"; clean_acp "$C" && git -C "$C" add -A && git -C "$C" commit -q -m start || die "the eval could not build a clean repository"
doc "$C"
{ has "layout: nothing out of place" && [ "$(printf '%s\n' "$out" | grep -c 'layout:')" = 1 ]; } || die "FAIL L4: a clean acp/ layout was reported" "$out"
# L7: a pipeline built as a plugin (its engine in hooks/scripts/) checks the layout too
PL="$EVAL_TMP/plugin"; mkdir -p "$PL/hooks" && cp -R "$PIPELINE_ROOT/bin" "$PL/" && cp -R "$PIPELINE_ROOT/core/hooks" "$PL/hooks/scripts" \
  || die "the eval could not build a plugin-shaped pipeline"
rc=0; out="$("$PL/bin/acp" doctor "$C" 2>&1)" || rc=$?
has "layout: nothing out of place" || die "FAIL L7: acp doctor from a plugin did not check the layout" "$out"
# G2: the caller's git environment is not used: GIT_DIR naming another repository changes nothing
rc=0; out="$(GIT_DIR="$R/.git" "$PIPELINE_ROOT/core/hooks/layout.py" --root "$C" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || die "FAIL G2: the layout check read the repository GIT_DIR named, not the one it was given" "exit $rc" "$out"
# L9: PLAYBOOKS_DIR in the forms the drivers accept: under $PROJECT_ROOT it is still exempt; outside the project
# it is ignored (the default stands) rather than switching the layout check off
cp "$C/pipeline.config.sh" "$EVAL_TMP/cfg.keep"
for v in '$PROJECT_ROOT/acp/playbooks' '${PROJECT_ROOT}/acp/playbooks'; do
  V="$v" perl -pi -e 's{^export PLAYBOOKS_DIR=.*}{export PLAYBOOKS_DIR="$ENV{V}"}' "$C/pipeline.config.sh"
  rc=0; out="$("$PIPELINE_ROOT/core/hooks/layout.py" --root "$C" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || die "FAIL L9: PLAYBOOKS_DIR=$v was not read as the playbooks folder" "exit $rc" "$out"
done
perl -pi -e 's{^export PLAYBOOKS_DIR=.*}{export PLAYBOOKS_DIR="/nonexistent/playbooks"}' "$C/pipeline.config.sh"
rc=0; out="$("$PIPELINE_ROOT/core/hooks/layout.py" --root "$C" 2>&1)" || rc=$?
{ [ "$rc" -eq 1 ] && has "duplicate"; } || die "FAIL L9: a PLAYBOOKS_DIR outside the project switched the layout check off" "exit $rc" "$out"
perl -pi -e 's{^export PLAYBOOKS_DIR=.*}{export PLAYBOOKS_DIR="../books"}' "$C/pipeline.config.sh"
rc=0; out="$("$PIPELINE_ROOT/core/hooks/layout.py" --root "$C" 2>&1)" || rc=$?
{ [ "$rc" -eq 1 ] && has "duplicate"; } || die "FAIL L9: a PLAYBOOKS_DIR above the project switched the layout check off" "exit $rc" "$out"
cp "$EVAL_TMP/cfg.keep" "$C/pipeline.config.sh"
# L5: in a single-folder project (CODE_DIR ".") the root is not judged, but a handoff file and stray work still are
F="$EVAL_TMP/f"; mkdir -p "$F" && git -C "$F" init -q && printf 'export WORKSPACE_DIR="Workspace"\n' > "$F/pipeline.config.sh" \
  && m "$F/src/a.js" && m "$F/Workspace/Docs/WorkOrders/WO-0001-a/WO-0001-SPEC.md" && m "$F/notes/WO-0009-x.md" && m "$F/WORK-PLAN.md" \
  && m "$F/SESSION-HANDOFF.md" && m "$F/next-session--2.md" && m "$F/plan.py" && m "$F/audit.go" && m "$F/plan/a.go" && m "$F/handoffs/a.md" \
  && m "$F/.claude/agents/a.md" && m "$F/.claude/skills/s/SKILL.md" \
  && git -C "$F" add -A && git -C "$F" commit -q -m start || die "the eval could not build a single-folder repository"
doc "$F"
{ has "layout: work-outside notes/WO-0009-x.md:" && has "layout: top-level WORK-PLAN.md: a plan, handoff or audit file" && ! has "layout: top-level src:"; } \
  || die "FAIL L5: a single-folder project was judged on its root, or its stray work was missed" "$out"
{ has "layout: top-level SESSION-HANDOFF.md:" && has "layout: top-level next-session--2.md:" && has "layout: top-level handoffs:"; } \
  || die "FAIL L5: a handoff document or folder at the root was missed" "$out"
{ ! has "top-level plan.py" && ! has "top-level audit.go" && ! has "top-level plan:"; } || die "FAIL L5: source named plan or audit was taken for a plan document" "$out"
# L6: with no pipeline.config.sh the layout is not declared, so nothing is judged, and it says so (exit 4)
N="$EVAL_TMP/n"; mkdir -p "$N" && git -C "$N" init -q && m "$N/vendor/acp/bin/wo" && m "$N/vendor/acp/core/hooks/check.py" && m "$N/HANDOFF.md"
rc=0; out="$("$PIPELINE_ROOT/core/hooks/layout.py" --root "$N" 2>&1)" || rc=$?
{ [ "$rc" -eq 4 ] && [ "$out" = "note: no pipeline.config.sh, so the layout is not declared; not checked" ]; } \
  || die "FAIL L6: a repository with no declared layout was judged" "exit $rc" "$out"
# L8: a layout folder that only the shell could work out is not guessed at: nothing is judged (exit 4)
printf 'export WORKSPACE_DIR="$HOME/ws"\n' > "$N/pipeline.config.sh"
rc=0; out="$("$PIPELINE_ROOT/core/hooks/layout.py" --root "$N" 2>&1)" || rc=$?
{ [ "$rc" -eq 4 ] && [ "$out" = 'note: pipeline.config.sh sets WORKSPACE_DIR to $HOME/ws, not a plain repository-relative path; not checked' ]; } \
  || die "FAIL L8: a layout folder set from a shell variable was guessed at" "exit $rc" "$out"
for v in 'WORKSPACE_DIR="../ws"' 'PIPELINE_ROOT="."' 'WORKORDERS_DIR="ws/../x"' 'LAYOUT_ROOT_EXTRA="a/b"' 'LAYOUT_ROOT_EXTRA="$X"'; do
  printf 'export %s\n' "$v" > "$N/pipeline.config.sh"
  rc=0; out="$("$PIPELINE_ROOT/core/hooks/layout.py" --root "$N" 2>&1)" || rc=$?
  { [ "$rc" -eq 4 ] && has "not checked"; } || die "FAIL L8: $v was not refused" "exit $rc" "$out"
done
printf 'export LAYOUT_ROOT_EXTRA="a\001b"\n' > "$N/pipeline.config.sh"
rc=0; out="$("$PIPELINE_ROOT/core/hooks/layout.py" --root "$N" 2>&1)" || rc=$?
{ [ "$rc" -eq 4 ] && has 'a\x01b'; } || die "FAIL L8: a control character in LAYOUT_ROOT_EXTRA was not refused" "exit $rc" "$out"
# C1: at commit, a staged file out of place is advisory under standard and blocks under strict
m "$C/work/WO-0003-x/WO-0003-SPEC.md"; git -C "$C" add work; before="$(fp "$C")"
chk "$C" --staged
{ [ "$rc" -eq 0 ] && has "layout: work-outside work/WO-0003-x"; } || die "FAIL C1: under standard a staged work order outside the workspace was not advisory" "exit $rc" "$out"
rc=0; out="$(cd "$C" && ACP_HOOK_PROFILE=strict "$A" check --staged 2>&1)" || rc=$?
{ [ "$rc" -eq 2 ] && has "blocking under strict:" && has "layout: work-outside work/WO-0003-x"; } \
  || die "FAIL C1: under strict a staged work order outside the workspace did not block" "exit $rc" "$out"
[ "$(fp "$C")" = "$before" ] || die "FAIL N1: acp check changed the repository"
git -C "$C" reset -q
# C3: an order duplicated inside the workspace is judged at commit too, though the workspace is not code
m "$C/acp/Workspace/Docs/WorkOrders/WO-0001-z/notes.md"; git -C "$C" add acp/Workspace
chk "$C" --staged
has "layout: duplicate acp/Workspace/Docs/WorkOrders/WO-0001-a: WO-0001 is in 2 places" || die "FAIL C3: a duplicate inside the workspace was not judged at commit" "exit $rc" "$out"
git -C "$C" reset -q
# C4: under strict, a commit that removes a misplaced file, or adds to migrate's own folder, is not blocked
m "$C/work/WO-0004-y/notes.md"; { git -C "$C" add work/WO-0004-y && git -C "$C" commit -q -m stray; } || die "the eval could not commit a stray order"
git -C "$C" rm -q --cached work/WO-0004-y/notes.md
rc=0; out="$(cd "$C" && ACP_HOOK_PROFILE=strict "$A" check --staged 2>&1)" || rc=$?
{ [ "$rc" -eq 0 ] && ! has "layout:"; } || die "FAIL C4: under strict, a commit removing a misplaced file was blocked" "exit $rc" "$out"
git -C "$C" reset -q
m "$C/.acp-migration/answers.json"; git -C "$C" add .acp-migration
rc=0; out="$(cd "$C" && ACP_HOOK_PROFILE=strict "$A" check --staged 2>&1)" || rc=$?
{ [ "$rc" -eq 0 ] && ! has "layout:"; } || die "FAIL C4: under strict, adding to acp migrate's own folder was blocked" "exit $rc" "$out"
git -C "$C" reset -q
# G3: inside a commit, the index git names in GIT_INDEX_FILE is the one read (here, one that no longer holds the stray order)
rm -f "$C/work/WO-0004-y/notes.md"; cp "$C/.git/index" "$EVAL_TMP/idx" && GIT_INDEX_FILE="$EVAL_TMP/idx" git -C "$C" rm -q --cached work/WO-0004-y/notes.md \
  || die "the eval could not make a commit's index"
rc=0; out="$(GIT_INDEX_FILE="$EVAL_TMP/idx" "$PIPELINE_ROOT/core/hooks/layout.py" --root "$C" 2>&1)" || rc=$?
! has "WO-0004" || die "FAIL G3: the layout check read the repository's index, not the one GIT_INDEX_FILE names" "exit $rc" "$out"
git -C "$C" rm -q --cached work/WO-0004-y/notes.md && git -C "$C" commit -q -m gone || die "the eval could not remove the stray order"
# G4: a part of the check that breaks stops it (exit 3, saying what broke) rather than passing it
mkdir -p "$EVAL_TMP/h4" && cp "$PIPELINE_ROOT/core/hooks/layout.py" "$EVAL_TMP/h4/" \
  && perl -0pi -e 's/\nif __name__/\ndef under(path, folder):\n    raise ValueError("planted")\n\nif __name__/' "$EVAL_TMP/h4/layout.py" || die "the eval could not plant a break"
rc=0; out="$(python3 "$EVAL_TMP/h4/layout.py" --root "$C" 2>&1)" || rc=$?
{ [ "$rc" -eq 3 ] && has "layout: ValueError: planted"; } || die "FAIL G4: a check that broke part-way did not stop with exit 3" "exit $rc" "$out"
# L10: the root name allowed for acp migrate's own folder is the one migrate.py writes (both read as text, nothing run)
pd() { python3 -I -c 'import ast, sys
v = [n.value.value for n in ast.parse(open(sys.argv[1]).read()).body if isinstance(n, ast.Assign)
     and [getattr(t, "id", None) for t in n.targets] == ["PLAN_DIR"] and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str)]
print(v[0] if len(v) == 1 else "")' "$1"; }
a="$(pd "$PIPELINE_ROOT/core/hooks/migrate.py")"; b="$(pd "$PIPELINE_ROOT/core/hooks/layout.py")"
{ [ -n "$a" ] && [ "$a" = "$b" ]; } || die "FAIL L10: layout.py allows '$b' at the root, but acp migrate writes '$a'"
# G5: paths as git holds them: bytes that are not UTF-8 are kept and shown escaped, and one folder in two
# Unicode spellings is one place, not two (index entries only, as no filesystem keeps both spellings)
U="$EVAL_TMP/u"; mkdir -p "$U" && git -C "$U" init -q && acpcfg "$U" && b="$(git -C "$U" hash-object -w --stdin </dev/null)" \
  && for q in "work/WO-0011-$(printf '\377')/x.md" "acp/Workspace/Docs/WorkOrders/WO-0012-$(printf 'caf\303\251')/a.md" \
       "acp/Workspace/Docs/WorkOrders/WO-0012-$(printf 'cafe\314\201')/b.md"; do
       git -C "$U" -c core.precomposeunicode=false update-index --add --cacheinfo "100644,$b,$q" || exit 9; done || die "the eval could not write index entries"
rc=0; out="$("$PIPELINE_ROOT/core/hooks/layout.py" --root "$U" 2>&1)" || rc=$?
{ [ "$rc" -eq 1 ] && has 'work-outside work/WO-0011-\udcff:'; } || die "FAIL G5: a path that is not UTF-8 was not kept as git holds it" "exit $rc" "$out"
! has "WO-0012 is in" || die "FAIL G5: one folder in two Unicode spellings was counted as two places" "$out"
# C2: a commit is judged on the files it touches: an unrelated change in a messy repository is not blocked
m "$R/app/src/components/Workspace/New.tsx"; git -C "$R" add app/src/components/Workspace/New.tsx
rc=0; out="$(cd "$R" && ACP_HOOK_PROFILE=strict "$A" check --staged 2>&1)" || rc=$?
{ [ "$rc" -eq 0 ] && ! has "layout:"; } || die "FAIL C2: an unrelated commit was judged on layout findings it does not touch" "exit $rc" "$out"
git -C "$R" reset -q; rm -f "$R/app/src/components/Workspace/New.tsx"
# G1: the repository's own fsmonitor and hooks are not run
EV="$EVAL_TMP/evil.sh"; printf '#!/bin/sh\necho "$0 $*" >> "%s/ran.txt"\nexit 1\n' "$EVAL_TMP" > "$EV"; chmod +x "$EV"
git -C "$C" config core.fsmonitor "$EV"; rm -f "$EVAL_TMP/ran.txt"
"$PIPELINE_ROOT/core/hooks/layout.py" --root "$C" >/dev/null 2>&1
[ ! -e "$EVAL_TMP/ran.txt" ] || die "FAIL G1: the layout check ran the repository's fsmonitor" "$(cat "$EVAL_TMP/ran.txt")"
echo "layout: all checks passed"
exit 0
