#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install.sh — render the pipeline into a target project
#
#   bin/install.sh /path/to/project [--dry-run] [--profile minimal|standard|full] [--pipeline-dir P --code-dir C]
#
#   minimal   rules, agents, commands, the six lifecycle skills; no hooks
#   standard  everything above plus all skills and hooks           (default)
#   full      standard plus every agent set and skill set
#
# Reads <project>/pipeline.config.sh, copies core/ and harness/ into
# <project>/$PIPELINE_ROOT with every {{VAR}} resolved, wires the agents and
# slash commands into <project>/.claude/, and creates the workspace folders.
#
# Writes ONLY inside the target project. The pipeline repo is never modified.
# Re-runnable: existing rendered files are overwritten, authored work is not.
# ---------------------------------------------------------------------------
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in -h|--help|"") sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:+0}";; esac
TARGET="${1:-}"; DRY=""; PROFILE="${ACP_PROFILE:-standard}"; LAYOUT_P=""; LAYOUT_C=""
_args=("${@:2}"); i=0
while [ $i -lt ${#_args[@]} ]; do a="${_args[$i]}"
  case "$a" in --dry-run) DRY="--dry-run";; --profile=*) PROFILE="${a#--profile=}";; --profile) i=$((i+1)); PROFILE="${_args[$i]:-}";; --pipeline-dir|--code-dir) v="${_args[$((i+1))]:-}"; case "$v" in ''|-*) echo "usage: bin/install.sh /path/to/project [--pipeline-dir P --code-dir C] (each flag takes a folder name)" >&2; exit 1;; esac; if [ "$a" = --pipeline-dir ]; then LAYOUT_P="$v"; else LAYOUT_C="$v"; fi; i=$((i+1));; minimal|standard|full) PROFILE="$a";; *) echo "install: unknown argument '$a'" >&2; exit 1;; esac
  i=$((i+1)); done
case "$PROFILE" in minimal|standard|full) ;; *) echo "install: --profile must be minimal, standard, or full" >&2; exit 1;; esac
[ -n "$TARGET" ] || { echo "usage: bin/install.sh /path/to/project [--dry-run]" >&2; exit 1; }
TARGET="$(cd "$TARGET" && pwd)" || { echo "install: $1 is not a directory" >&2; exit 1; }
[ "$TARGET" = "$SRC" ] && { echo "install: refusing to install the pipeline into itself" >&2; exit 1; }

CONFIG="$TARGET/pipeline.config.sh"
[ -f "$CONFIG" ] || {
  echo "install: $CONFIG not found." >&2
  echo "         cp $SRC/pipeline.config.example.sh $CONFIG   # then edit it" >&2
  exit 1
}
# shellcheck disable=SC1090
. "$CONFIG"

: "${PROJECT_NAME:?set PROJECT_NAME in pipeline.config.sh}"
: "${PROJECT_SLUG:?set PROJECT_SLUG in pipeline.config.sh}"
: "${PIPELINE_ROOT:?set PIPELINE_ROOT in pipeline.config.sh}"
: "${WORKORDERS_DIR:?set WORKORDERS_DIR in pipeline.config.sh}"
: "${BUGS_DIR:?set BUGS_DIR in pipeline.config.sh}"
: "${TESTING_DIR:?set TESTING_DIR in pipeline.config.sh}"
: "${SESSIONS_DIR:?set SESSIONS_DIR in pipeline.config.sh}"
export API_BASE_URL="${API_BASE_URL:-http://localhost:3001/api/v1}" WEB_ORIGIN="${WEB_ORIGIN:-http://localhost:3000}"
# Every path below is the config's, under PROJECT_ROOT: it must be this project, or install would scan and write elsewhere.
case "${PROJECT_ROOT:-}" in /*) [ "$PROJECT_ROOT" -ef "$TARGET" ];; *) false;; esac \
  || { printf 'install: pipeline.config.sh sets PROJECT_ROOT to %q, not this project (%s); it should be the file'"'"'s own folder:  export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; nothing was written\n' "${PROJECT_ROOT:-}" "$TARGET" >&2; exit 1; }
# The two-folder layout (acp layout writes it): with --pipeline-dir and --code-dir, the repository must hold that
# layout and the config must state it exactly, or nothing is written. The repository is checked first, so a
# project still laid out the old way is told to move, not to rewrite its config. Anything unusual is refused.
if [ -n "$LAYOUT_P$LAYOUT_C" ]; then
  lay_bad() { echo "install: $*; nothing was written" >&2; exit 1; }
  lay_lc() { printf '%s' "$1" | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'; }
  for v in "$LAYOUT_P" "$LAYOUT_C"; do
    case "$v" in *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*|.*|-*|'') lay_bad "--pipeline-dir and --code-dir are given together, each one folder name (letters, digits, '.', '_', '-'; not starting with '.' or '-')";; esac
    case "$(lay_lc "$v")" in workspace|pipeline.config.sh|agents.md|claude.md) lay_bad "$v is a name the layout or the tools use at the top of the repository (in any case)";; esac
  done
  [ "$(lay_lc "$LAYOUT_P")" != "$(lay_lc "$LAYOUT_C")" ] || lay_bad "the pipeline folder and the code folder must differ, also ignoring case"
  for x in .aicodepipeline Workspace; do
    { [ ! -e "$TARGET/$x" ] && [ ! -L "$TARGET/$x" ]; } || lay_bad "$x at the top of the repository belongs to the single-folder layout; move the project with  acp migrate  (plan, backup, then apply) first"
  done
  { [ -d "$TARGET/$LAYOUT_C" ] && [ ! -L "$TARGET/$LAYOUT_C" ]; } || lay_bad "$LAYOUT_C/ must be a folder in the repository, not missing, a file or a link"
  { [ ! -L "$TARGET/$LAYOUT_P" ] && { [ ! -e "$TARGET/$LAYOUT_P" ] || [ -d "$TARGET/$LAYOUT_P" ]; }; } || lay_bad "$LAYOUT_P must be a folder or absent, not a file or a link"
  for x in .aicodepipeline Workspace pipeline.config.sh; do
    { [ ! -e "$TARGET/$LAYOUT_C/$x" ] && [ ! -L "$TARGET/$LAYOUT_C/$x" ]; } || lay_bad "$LAYOUT_C/$x: pipeline files do not belong in the code folder"
  done
  { [ ! -e "$TARGET/$LAYOUT_P/pipeline.config.sh" ] && [ ! -L "$TARGET/$LAYOUT_P/pipeline.config.sh" ]; } || lay_bad "$LAYOUT_P/pipeline.config.sh: the config lives at the top of the repository, not in $LAYOUT_P/"
  for gl in '*.log' '.acp-migration/'; do   # logs and the migration's records never enter git
    grep -qxF -- "$gl" "$TARGET/.gitignore" 2>/dev/null || lay_bad ".gitignore must hold the line  $gl  (new-project writes it; install does not edit project files)"
  done
  lay_miss=""
  for kv in "PIPELINE_ROOT=$LAYOUT_P/.aicodepipeline" "WORKSPACE_DIR=$LAYOUT_P/Workspace" "DOCS_DIR=$LAYOUT_P/Workspace/Docs" \
            "WORKORDERS_DIR=$LAYOUT_P/Workspace/Docs/WorkOrders" "BUGS_DIR=$LAYOUT_P/Workspace/Docs/Bugs" "TESTING_DIR=$LAYOUT_P/Workspace/Testing" \
            "KNOWLEDGE_DIR=$LAYOUT_P/Workspace/Docs/KnowledgeBase" "SESSIONS_DIR=$LAYOUT_P/Workspace/Sessions" "CODE_DIR=$LAYOUT_C" \
            "PLAYBOOKS_DIR=$LAYOUT_P/playbooks"; do
    k="${kv%%=*}"; [ "${!k-}" = "${kv#*=}" ] || lay_miss="$lay_miss $k"
  done
  [ -z "$lay_miss" ] || lay_bad "pipeline.config.sh does not state the $LAYOUT_P/ + $LAYOUT_C/ layout (differs:$lay_miss); run  acp layout --pipeline-dir $LAYOUT_P --code-dir $LAYOUT_C  first"
fi
# Something at the old place that is not the configured pipeline: an install here would be taken for a first install
# and write beside it. A pipeline copy (it holds bin/acp or core/) is moved, or reinstalled in place; anything else is in the way.
if { [ -e "$TARGET/.aicodepipeline" ] || [ -L "$TARGET/.aicodepipeline" ]; } && [ ! "$TARGET/.aicodepipeline" -ef "$TARGET/$PIPELINE_ROOT" ]; then
  if [ -f "$TARGET/.aicodepipeline/bin/acp" ] || [ -d "$TARGET/.aicodepipeline/core" ]; then
    echo "install: .aicodepipeline at the top of the project is a pipeline copy, but pipeline.config.sh names $PIPELINE_ROOT; set PIPELINE_ROOT back to .aicodepipeline to reinstall in place, or move the project with  acp migrate  (plan, backup, then apply) first; nothing was written" >&2
  else
    echo "install: .aicodepipeline at the top of the project is in the way (it is not the pipeline pipeline.config.sh names, $PIPELINE_ROOT); move it aside; nothing was written" >&2
  fi
  exit 1
fi
# The playbooks folder, as playbook decides it for the drivers, checked before anything is written.
PBD="$TARGET/$PIPELINE_ROOT/playbooks"
if [ -n "${PLAYBOOKS_DIR:-}" ]; then
  PBD="$("$SRC/bin/playbook" where --project "$TARGET")" || { echo "install: the playbooks folder is refused (above); nothing was written" >&2; exit 1; }
fi

VARS=(PROJECT_NAME PROJECT_SLUG PROJECT_DOMAIN GITHUB_REPO PROJECT_ROOT PIPELINE_ROOT
      WORKSPACE_DIR DOCS_DIR WORKORDERS_DIR BUGS_DIR TESTING_DIR SESSIONS_DIR KNOWLEDGE_DIR CODE_DIR LAYOUT_ROOT_EXTRA
      API_APP ADMIN_APP PORTAL_APP DEV_APP WEB_APP SDK_PKG DB_NAME CLI_NAME API_BASE_URL WEB_ORIGIN
      PROJECT_DOMAIN_RE DEV_SUBDOMAINS PROD_IP WORKTREE_DISPOSABLE)

DEST="$TARGET/$PIPELINE_ROOT"
if [ -e "$DEST" ] && [ "$(cd "$DEST" && pwd -P)" = "$(cd "$SRC" && pwd -P)" ]; then
  if [ -f "$DEST/.source" ] && [ -x "$(cat "$DEST/.source")/bin/install.sh" ] && [ "$(cd "$(cat "$DEST/.source")" && pwd -P)" != "$(cd "$SRC" && pwd -P)" ]; then
    echo "install: re-running from the pipeline source recorded at $(cat "$DEST/.source")"
    exec "$(cat "$DEST/.source")/bin/install.sh" "$@"
  fi
  echo "install: refusing to install the installed copy over itself ($DEST)." >&2
  echo "         Run install.sh from the pipeline repository (the clone of AICodePipeline), not from $PIPELINE_ROOT/bin." >&2
  exit 1
fi
say() { echo "  $*"; }
# The work-order and bug folders are the pipeline's own. A .gitignore in each keeps every order's artifacts/ out of
# git (in a clone and an order's worktree too); it is checked before anything is written, and kept current below.
OI="$SRC/core/hooks/order-ignore.py"
oi_plan="$(python3 "$OI" "$TARGET/$WORKORDERS_DIR" "$TARGET/$BUGS_DIR" --dry-run)" || { echo "install: nothing was written" >&2; exit 1; }

echo "Installing AICodePipeline ($PROFILE profile)"
echo "  from : $SRC"
echo "  into : $DEST"
echo "  as   : $PROJECT_NAME ($PROJECT_SLUG)"
echo

if [ "$DRY" = "--dry-run" ]; then
  echo "DRY RUN — nothing will be written."
  echo "Would render:"
  find "$SRC/core" "$SRC/harness" -type f | sed "s|$SRC/|    |"
  echo "Would create: $TARGET/{$WORKORDERS_DIR,$BUGS_DIR,$TESTING_DIR/suites,$SESSIONS_DIR/{active,archive}}"
  echo "Would link:   $TARGET/.claude/{agents,commands}"
  [ -z "$oi_plan" ] || printf '%s\n' "$oi_plan" | sed 's/^would write /Would write: /'
  exit 0
fi

# --- 1. Copy core/ and harness/ verbatim, then render ---------------------
mkdir -p "$DEST"
# Overlays and the harness configuration are the project's own work, not the
# pipeline's, and they survive every reinstall. Holding them in an anonymous
# temporary directory meant a failed install left them stranded: the project had
# already lost them, and the retry had nothing left to preserve. They are kept
# with the project instead, and only discarded once the install has committed.
# An upgrade leaves the project's own files alone (D-3): a pipeline already installed here, or a knowledge base
# already written, means this is not a first install, and the knowledge base is not written below.
ACP_UPGRADE=0
{ [ -d "$DEST/core" ] || [ -e "$TARGET/${KNOWLEDGE_DIR:-Workspace/Docs/KnowledgeBase}" ]; } && ACP_UPGRADE=1
RECOVERY="$DEST/.acp-install-recovery"

if [ -d "$RECOVERY" ]; then
  say "recovering authored files left by an interrupted install"
  if [ -d "$RECOVERY/overlays" ]; then mkdir -p "$DEST/core/agents/overlays"; cp -R "$RECOVERY/overlays/." "$DEST/core/agents/overlays/" 2>/dev/null || true; fi
  if [ -d "$RECOVERY/harness-config" ]; then mkdir -p "$DEST/harness/config"; cp -R "$RECOVERY/harness-config/." "$DEST/harness/config/" 2>/dev/null || true; fi
fi

rm -rf "$RECOVERY"; mkdir -p "$RECOVERY/overlays" "$RECOVERY/harness-config"
[ -d "$DEST/core/agents/overlays" ] && cp -R "$DEST/core/agents/overlays/." "$RECOVERY/overlays/" 2>/dev/null || true
[ -d "$DEST/harness/config" ] && cp -R "$DEST/harness/config/." "$RECOVERY/harness-config/" 2>/dev/null || true
printf 'started=%s\nsource=%s\nnote=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SRC" \
  "Authored files held while the pipeline was replaced. Re-run install to restore them; it is removed once an install finishes." > "$RECOVERY/MANIFEST"

# Build the new trees beside the old ones and swap at the end. Removing first and
# copying afterwards left a window in which a failed copy destroyed the install.
rm -rf "$DEST/.core.incoming" "$DEST/.harness.incoming"
cp -R "$SRC/core" "$DEST/.core.incoming" || { echo "install: copying core/ from $SRC failed; the existing installation and $RECOVERY are untouched" >&2; rm -rf "$DEST/.core.incoming"; exit 1; }
cp -R "$SRC/harness" "$DEST/.harness.incoming" || { echo "install: copying harness/ from $SRC failed; the existing installation and $RECOVERY are untouched" >&2; rm -rf "$DEST/.core.incoming" "$DEST/.harness.incoming"; exit 1; }
rm -rf "$DEST/core" "$DEST/harness"
mv "$DEST/.core.incoming" "$DEST/core" && mv "$DEST/.harness.incoming" "$DEST/harness" \
  || { echo "install: could not put the new core/ and harness/ in place; authored files are in $RECOVERY" >&2; exit 1; }
find "$DEST/core" "$DEST/harness" -name .DS_Store -delete 2>/dev/null || true
printf '%s\n' "$(cd "$SRC" && pwd -P)" > "$DEST/.source"
mkdir -p "$DEST/core/agents/overlays"; cp -R "$RECOVERY/overlays/." "$DEST/core/agents/overlays/" 2>/dev/null || true
[ -n "$(ls -A "$RECOVERY/harness-config" 2>/dev/null)" ] && { cp -R "$RECOVERY/harness-config/." "$DEST/harness/config/"; say "harness/config kept from the previous install"; }
echo "$PROFILE" > "$DEST/.profile"
sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$SRC/bin/acp" | head -1 > "$DEST/VERSION"   # the ACP version this copy is, read where the build reads it
mkdir -p "$DEST/bin"
cp -p "$SRC/bin/acp" "$SRC/bin/wo" "$SRC/bin/bug" "$SRC/bin/playbook" "$SRC/bin/pack" "$SRC/bin/sanitize" "$SRC/bin/detect-stack" "$SRC/bin/stack-specialist" "$SRC/bin/new-project" "$SRC/bin/install.sh" "$SRC/bin/build-plugin" "$SRC/bin/eval" "$SRC/bin/lint" "$DEST/bin/"
mkdir -p "$DEST/bin/dev"
cp -p "$SRC"/bin/dev/*.sh "$DEST/bin/dev/"
chmod +x "$DEST"/bin/acp "$DEST"/bin/wo "$DEST"/bin/bug "$DEST"/bin/playbook "$DEST"/bin/pack "$DEST"/bin/sanitize "$DEST"/bin/detect-stack "$DEST"/bin/stack-specialist "$DEST"/bin/new-project "$DEST"/bin/install.sh "$DEST"/bin/build-plugin "$DEST"/bin/eval "$DEST"/bin/lint "$DEST"/bin/dev/*.sh
# packs/ was the name before 1.4.0. An install that still has content there is
# moved once, so promoted work keeps working under the new name.
if [ -d "$DEST/packs" ] && [ -n "$(ls -A "$DEST/packs" 2>/dev/null)" ] && [ ! -d "$DEST/playbooks" ]; then
  mv "$DEST/packs" "$DEST/playbooks"
  say "moved packs/ to playbooks/ (packs/ was the old name)"
fi
mkdir -p "$PBD"
[ -f "$PBD/README.md" ] || cp "$SRC/playbooks/README.md" "$PBD/README.md"
[ -f "$PBD/INDEX.md" ] || cp "$SRC/playbooks/INDEX.md" "$PBD/INDEX.md"
say "copied core/ harness/ bin/ and an empty playbooks/"

export "${VARS[@]}"
# One process renders every file: the per-file, per-variable loop this replaces
# spawned thousands of interpreters and took forty seconds on a full install.
rendered="$(RENDER_VARS="${VARS[*]}" python3 - "$DEST/core" "$DEST/harness" "$DEST/bin/dev" <<'PYEOF'
import os, re, sys
names = os.environ["RENDER_VARS"].split()
values = {n: os.environ.get(n, "") for n in names}
rx = re.compile(r"\{\{(" + "|".join(map(re.escape, names)) + r")\}\}")
exts = {".md", ".sh", ".env", ".js", ".json", ".sql", ".py", ".yaml", ".yml", ".txt"}
n = 0
for root in sys.argv[1:]:
    for d, _, files in os.walk(root):
        if "/core/templates/project" in d: continue
        for f in files:
            if os.path.splitext(f)[1] not in exts: continue
            fp = os.path.join(d, f)
            try: t = open(fp, encoding="utf-8").read()
            except (UnicodeDecodeError, OSError): continue
            u = rx.sub(lambda m: values[m.group(1)], t)
            if u != t: open(fp, "w", encoding="utf-8").write(u)
            n += 1
print(n)
PYEOF
)"
say "rendered $rendered files"

# Only the pipeline's own variables count as unresolved; skills may carry their own {{TEMPLATE}} syntax.
VAR_RE="$(printf '%s|' "${VARS[@]}")STACK_SECTION"
unresolved="$(grep -rhoE "\{\{(${VAR_RE})\}\}" "$DEST/core" "$DEST/harness" "$DEST/bin/dev" --exclude-dir=project 2>/dev/null | sort -u || true)"
[ -n "$unresolved" ] && { echo; echo "  WARNING — unresolved variables remain:"; echo "$unresolved" | sed 's/^/    /'; echo; }

# --- 2. Workspace folders -------------------------------------------------
# The resolved layout is recorded so that a later install with a different one
# can say so. Nothing is deleted: the old folders may hold work, and a stale
# rendered manifest left in an abandoned path is exactly what someone later
# mistakes for live configuration, so they are named instead.
STATE="$DEST/.install-state"
if [ -f "$STATE" ]; then
  for k in WORKORDERS_DIR BUGS_DIR TESTING_DIR SESSIONS_DIR; do
    prev="$(sed -n "s/^$k=//p" "$STATE" | head -1)"; cur="$(eval "printf '%s' \"\$$k\"")"
    if [ -n "$prev" ] && [ "$prev" != "$cur" ]; then
      say "workspace moved: $k was $prev, now $cur"
      [ -d "$TARGET/$prev" ] && say "                 the previous folder $prev/ still exists and is no longer read; move or remove it yourself"
    fi
  done
fi
printf 'WORKORDERS_DIR=%s\nBUGS_DIR=%s\nTESTING_DIR=%s\nSESSIONS_DIR=%s\ninstalled=%s\n' "$WORKORDERS_DIR" "$BUGS_DIR" "$TESTING_DIR" "$SESSIONS_DIR" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE"
mkdir -p "$TARGET/$WORKORDERS_DIR" "$TARGET/$BUGS_DIR" \
         "$TARGET/$TESTING_DIR/suites" "$TARGET/$TESTING_DIR/results" \
         "$TARGET/$SESSIONS_DIR/active" "$TARGET/$SESSIONS_DIR/archive"
[ -f "$TARGET/$TESTING_DIR/suites.manifest" ] || cp "$DEST/harness/config/suites.manifest" "$TARGET/$TESTING_DIR/suites.manifest"
say "created workspace folders (suite manifest: $TESTING_DIR/suites.manifest)"
oi_done="$(python3 "$OI" "$TARGET/$WORKORDERS_DIR" "$TARGET/$BUGS_DIR")" || { echo "install: the work-order and bug folders' .gitignore could not be kept (above)" >&2; exit 1; }
[ -z "$oi_done" ] || printf '%s\n' "$oi_done" | while IFS= read -r l; do say "order working files stay out of git: ${l#"$TARGET"/}"; done

# --- 3. Wire agents and slash commands into .claude/ ---------------------
mkdir -p "$TARGET/.claude/agents" "$TARGET/.claude/commands"
cp -p "$DEST"/core/agents/base/*.md  "$TARGET/.claude/agents/"
cp -p "$DEST"/core/agents/roles/*.md "$TARGET/.claude/agents/"
if [ -d "$DEST/core/agents/overlays" ]; then
  for f in "$DEST"/core/agents/overlays/*.md; do
    [ -f "$f" ] && [ "$(basename "$f")" != "README.md" ] && cp -p "$f" "$TARGET/.claude/agents/"
  done
fi
rm -f "$TARGET/.claude/agents/README.md"
# AGENT_PACKS and SKILL_PACKS were the names before 1.4.0 and are read when the
# new ones are unset, so an existing pipeline.config.sh keeps working.
AGENT_SETS="${AGENT_SETS:-${AGENT_PACKS:-}}"
SKILL_SETS="${SKILL_SETS:-${SKILL_PACKS:-}}"
[ "$PROFILE" = "full" ] && AGENT_SETS="$(ls "$DEST/core/agents/sets" | grep -v README | tr '\n' ' ')"
[ "$PROFILE" = "full" ] && SKILL_SETS="$(ls -d "$DEST"/core/skill-sets/*/ 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
for sp in ${SKILL_SETS:-}; do
  [ -d "$DEST/core/skill-sets/$sp" ] || { echo "  WARNING — skill set '$sp' not found"; continue; }
  mkdir -p "$TARGET/.claude/skills"
  for d in "$DEST/core/skill-sets/$sp"/*/; do
    [ -f "$d/SKILL.md" ] || continue
    rm -rf "$TARGET/.claude/skills/$(basename "$d")"; cp -R "$d" "$TARGET/.claude/skills/$(basename "$d")"
  done
  say "skill set '$sp' installed"
done
python3 - "$TARGET/.claude/agents" "$DEST/core/agents/sets" "${AGENT_SETS:-}" <<'PYEOF'
import os, sys
installed, sets_dir, selected = sys.argv[1:4]
sel = set(selected.split()); removed = 0
if os.path.isdir(sets_dir) and os.path.isdir(installed):
    for pk in os.listdir(sets_dir):
        d = os.path.join(sets_dir, pk)
        if not os.path.isdir(d) or pk in sel: continue
        for f in os.listdir(d):
            if f.endswith(".md") and f != "README.md" and os.path.exists(os.path.join(installed, f)):
                os.remove(os.path.join(installed, f)); removed += 1
if removed: print(f"  reconciled: {removed} agent(s) from sets not selected removed")
PYEOF
for ap in ${AGENT_SETS:-}; do
  if [ -d "$DEST/core/agents/sets/$ap" ]; then cp -p "$DEST"/core/agents/sets/"$ap"/*.md "$TARGET/.claude/agents/"; say "agent set installed: $ap"
  else echo "  WARNING: no agent set named '$ap' (available: $(ls "$DEST/core/agents/sets" | grep -v README | tr '\n' ' '))" >&2; fi
done

# Workflows — executable review pipeline, discoverable by name
if ls "$DEST"/core/workflows/*.js >/dev/null 2>&1; then
  mkdir -p "$TARGET/.claude/workflows"
  cp -p "$DEST"/core/workflows/*.js "$TARGET/.claude/workflows/"
fi
cp -p "$DEST"/core/commands/*.md "$TARGET/.claude/commands/"

# Skills — the methodology, loaded on demand rather than hoped-for
mkdir -p "$TARGET/.claude/skills"
LIFECYCLE="work-order bug-triage behavioral-testing session-handoff playbook-search project-onboarding"
for d in "$DEST"/core/skills/*/; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"
  if [ "$PROFILE" = "minimal" ]; then case " $LIFECYCLE " in *" $n "*) ;; *) continue;; esac; fi
  rm -rf "$TARGET/.claude/skills/$n"
  cp -R "$d" "$TARGET/.claude/skills/$n"
done
# Reconcile: anything pipeline-owned that this profile does not select is removed;
# the user's own skills and agents (names the pipeline does not ship) are never touched.
python3 - "$TARGET/.claude/skills" "$DEST/core/skills" "$DEST/core/skill-sets" "$PROFILE" "${SKILL_SETS:-}" "$LIFECYCLE" <<'PYEOF'
import os, shutil, sys
installed, core, sets_dir, profile, selected_sets, lifecycle = sys.argv[1:7]
owned = set(os.listdir(core)) if os.path.isdir(core) else set()
set_skills = {}
if os.path.isdir(sets_dir):
    for pk in os.listdir(sets_dir):
        d = os.path.join(sets_dir, pk)
        if os.path.isdir(d): set_skills[pk] = set(x for x in os.listdir(d) if os.path.isdir(os.path.join(d, x)))
for ss in set_skills.values(): owned |= ss
if profile == "minimal": selected = set(lifecycle.split())
else: selected = set(x for x in owned if x in os.listdir(core)) if os.path.isdir(core) else set()
for pk in selected_sets.split(): selected |= set_skills.get(pk, set())
removed = 0
if os.path.isdir(installed):
    for name in os.listdir(installed):
        if name in owned and name not in selected:
            shutil.rmtree(os.path.join(installed, name), ignore_errors=True); removed += 1
if removed: print(f"  reconciled: {removed} pipeline skill(s) not in the {profile} profile removed (user skills untouched)")
PYEOF

say "installed $(ls "$TARGET/.claude/agents" | wc -l | tr -d ' ') agents, $(ls "$TARGET/.claude/commands" | wc -l | tr -d ' ') commands, $(ls "$TARGET/.claude/skills" | wc -l | tr -d ' ') skills, $(ls "$TARGET/.claude/workflows" 2>/dev/null | wc -l | tr -d ' ') workflows"

# --- 3b. Rules: common always, language sets by detected stack -----------
mkdir -p "$TARGET/.claude/rules"
STACK_JSON="$("$SRC/bin/detect-stack" "$TARGET" --json 2>/dev/null || echo '{}')"
RULE_SETS="$(printf '%s' "$STACK_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(d.get("rule_sets") or ["common"]))' 2>/dev/null || echo common)"
[ -n "${EXTRA_RULE_SETS:-}" ] && RULE_SETS="$RULE_SETS $EXTRA_RULE_SETS"
installed_rules=""
for rs in $RULE_SETS; do
  if [ -d "$DEST/core/rules/$rs" ]; then
    rm -rf "$TARGET/.claude/rules/$rs"; cp -R "$DEST/core/rules/$rs" "$TARGET/.claude/rules/$rs"
    installed_rules="$installed_rules $rs"
  fi
done
say "installed rules:$installed_rules"

# --- 4. Hooks and permission baseline -------------------------------------
chmod +x "$DEST"/core/hooks/* 2>/dev/null || true
SETTINGS="$TARGET/.claude/settings.json"
ACP_PROFILE_MINIMAL="$([ "$PROFILE" = minimal ] && echo 1 || echo 0)" python3 - "$SETTINGS" "$DEST/core/config/settings.hooks.json" "$DEST/core/config/settings.baseline.json" <<'PYEOF'
import json, os, sys
target, hooks_f, base_f = sys.argv[1:4]
cur = {}
if os.path.exists(target):
    try: cur = json.load(open(target))
    except Exception: cur = {}
hooks = json.load(open(hooks_f))
base  = json.load(open(base_f))
# Hooks are merged by identity: every command carrying an "acp:" id is pipeline-owned and is
# replaced by the shipped version (upgrades); everything else in the user's settings is kept.
def is_acp(h): return "acp:" in (h.get("command") or "")
existing = cur.get("hooks") or {}
kept = {}
removed = 0
for ev, groups in existing.items():
    out = []
    for g in groups:
        hs = [h for h in (g.get("hooks") or []) if not is_acp(h)]
        removed += len(g.get("hooks") or []) - len(hs)
        if hs: out.append({**g, "hooks": hs})
    if out: kept[ev] = out
if os.environ.get("ACP_PROFILE_MINIMAL") == "1":
    note = f"hooks: none installed (minimal profile); {removed} pipeline hook(s) removed, user hooks kept"
    if kept: cur["hooks"] = kept
    else: cur.pop("hooks", None)
else:
    merged = dict(kept)
    for ev, groups in hooks["hooks"].items():
        merged.setdefault(ev, []).extend(groups)
    cur["hooks"] = merged
    n = sum(len(g.get("hooks") or []) for gs in hooks["hooks"].values() for g in gs)
    note = f"hooks: {n} pipeline hooks installed ({removed} replaced), user hooks kept"
perms = cur.setdefault("permissions", {})
allow = perms.setdefault("allow", [])
added = [r for r in base["permissions"]["allow"] if r not in allow]
allow.extend(added)
perms["allow"] = sorted(set(allow))
deny = perms.setdefault("deny", [])
added_deny = [r for r in base["permissions"].get("deny", []) if r not in deny]
deny.extend(added_deny); perms["deny"] = sorted(set(deny)); perms.setdefault("ask", [])
os.makedirs(os.path.dirname(target), exist_ok=True)
json.dump(cur, open(target, "w"), indent=2)
print(f"  {note}; {len(added)} allow and {len(added_deny)} deny rules added")
PYEOF

# --- 4b. git commit-msg hook ---------------------------------------------
# The tool hook sees the command a session is about to run; it cannot see a message
# that arrives by file or editor. Git can. This is the only place the traceability
# check is complete, so it is wired into the repository itself.
REL_DEST="${DEST#"$TARGET"/}"
if (cd "$TARGET" && git rev-parse --git-dir >/dev/null 2>&1); then
  # Ask git where the hook goes rather than inferring it. In a linked worktree the
  # per-worktree git directory is not where git looks for hooks, and core.hooksPath
  # moves them somewhere else again; guessing writes a file nothing ever runs.
  CMSG="$(cd "$TARGET" && git rev-parse --git-path hooks/commit-msg 2>/dev/null)"
  case "$CMSG" in /*) ;; *) CMSG="$TARGET/$CMSG";; esac
  SHARED=0
  if [ "$(cd "$TARGET" && git rev-parse --git-dir 2>/dev/null)" != "$(cd "$TARGET" && git rev-parse --git-common-dir 2>/dev/null)" ]; then SHARED=1; fi
  PREC="$(dirname "$CMSG")/pre-commit"
  PPUSH="$(dirname "$CMSG")/pre-push"
  if [ "$PROFILE" = minimal ]; then
    # minimal means no hooks, and that has to include these. Only ours are removed.
    if [ -f "$CMSG" ] && grep -q 'acp:commit-msg:wo-reference' "$CMSG" 2>/dev/null; then
      rm -f "$CMSG"; say "commit-msg: pipeline hook removed (minimal profile installs no hooks)"
    else say "commit-msg: none installed (minimal profile)"; fi
    if [ -f "$PREC" ] && grep -q 'acp:pre-commit:check' "$PREC" 2>/dev/null; then rm -f "$PREC"; say "pre-commit: pipeline hook removed (minimal profile)"; fi
    if [ -f "$PPUSH" ] && grep -q 'acp:pre-push:protect' "$PPUSH" 2>/dev/null; then rm -f "$PPUSH"; say "pre-push: pipeline hook removed (minimal profile)"; fi
  elif [ -f "$CMSG" ] && ! grep -q 'acp:commit-msg:wo-reference' "$CMSG" 2>/dev/null; then
    say "commit-msg: left your existing hook alone; to add the traceability check, call"
    say "            \"\$(git rev-parse --show-toplevel)/$REL_DEST/core/hooks/wo-reference.py\" \"\$@\" from it"
  else
    mkdir -p "$(dirname "$CMSG")"
    cat > "$CMSG" <<CMSGEOF
#!/usr/bin/env sh
# acp:commit-msg:wo-reference — installed by AICodePipeline, safe to delete
hook="\$(git rev-parse --show-toplevel 2>/dev/null)/$REL_DEST/core/hooks/wo-reference.py"
[ -f "\$hook" ] || exit 0
exec python3 "\$hook" "\$@"
CMSGEOF
    chmod +x "$CMSG"
    say "commit-msg: traceability hook wired into ${CMSG#"$TARGET"/}"
    if [ "$SHARED" -eq 1 ]; then say "            (this is a linked worktree; git shares that hook with every worktree of this repository)"; fi
  fi
  # The rules at commit time, under any agent. This is the local backstop for a
  # closeout written by hand or a work order never opened: the driver cannot see
  # those, git can.
  if [ "$PROFILE" != minimal ]; then
    if [ -f "$PREC" ] && ! grep -q 'acp:pre-commit:check' "$PREC" 2>/dev/null; then
      say "pre-commit: left your existing hook alone; to add the pipeline's checks, call"
      say "            \"\$(git rev-parse --show-toplevel)/$REL_DEST/bin/acp\" check --staged from it"
    else
      cat > "$PREC" <<PRECEOF
#!/usr/bin/env sh
# acp:pre-commit:check — installed by AICodePipeline, safe to delete
acp="\$(git rev-parse --show-toplevel 2>/dev/null)/$REL_DEST/bin/acp"
[ -x "\$acp" ] || exit 0
exec "\$acp" check --staged
PRECEOF
      chmod +x "$PREC"
      say "pre-commit: the rules run on every commit (${PREC#"$TARGET"/})"
    fi
    # Shared history at push time, under any agent. The markdown hook rule that
    # blocks `git push --force` reads the text of a tool call, so it only fires
    # inside Claude Code; git runs this whoever is pushing.
    if [ -f "$PPUSH" ] && ! grep -q 'acp:pre-push:protect' "$PPUSH" 2>/dev/null; then
      say "pre-push: left your existing hook alone; to add the shared-branch protection, call"
      say "          \"\$(git rev-parse --show-toplevel)/$REL_DEST/core/hooks/pre-push.sh\" \"\$@\" from it"
      say "          (it reads the ref lines git puts on stdin, so pass those through too)"
    else
      cat > "$PPUSH" <<PPUSHEOF
#!/usr/bin/env sh
# acp:pre-push:protect — installed by AICodePipeline, safe to delete
hook="\$(git rev-parse --show-toplevel 2>/dev/null)/$REL_DEST/core/hooks/pre-push.sh"
[ -x "\$hook" ] || exit 0
exec "\$hook" "\$@"
PPUSHEOF
      chmod +x "$PPUSH"
      say "pre-push: a force push or deletion of a shared branch is refused (${PPUSH#"$TARGET"/})"
    fi
  fi
else
  say "git: none here. The work-order gates still hold, but nothing can catch a closeout written by"
  say "     hand or a commit that skips the driver. A local repository costs nothing and turns that on:"
  say "         (cd \"$TARGET\" && git init) && $DEST/bin/acp install \"$TARGET\""
fi

# --- 5. Project instructions, only where the project has none --------------
# AGENTS.md is the file most agents read (Codex, Cursor, and others); CLAUDE.md is
# what Claude Code reads, and it can import. So the methodology lives once, in
# AGENTS.md, and CLAUDE.md points at it. Neither is ever overwritten.
if [ ! -f "$TARGET/AGENTS.md" ]; then
  STACK_SECTION="$(printf '%s' "$STACK_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if d.get("empty"):
    print("- **Stack:** _(empty project — fill in once code exists)_"); print("- **Run locally:** _(the command)_"); print("- **Run tests:** _(the command)_")
else:
    print("- **Stack:** " + ", ".join(d["languages"] + d["frameworks"]) + (" (" + d["package_manager"] + ")" if d["package_manager"] else ""))
    c=d.get("commands",{})
    print("- **Run locally:** `" + c.get("run","_(the command)_") + "`"); print("- **Run tests:** `" + c.get("test","_(the command)_") + "`")
    if c.get("build"): print("- **Build:** `" + c["build"] + "`")
    print("- **Rule sets installed:** " + ", ".join(d["rule_sets"]))
' 2>/dev/null || echo "- **Stack:** _(fill in)_")"
  cp "$SRC/core/templates/project/CLAUDE.md" "$TARGET/AGENTS.md"
  for v in "${VARS[@]}"; do VAR="$v" VAL="${!v-}" perl -pi -e 's/\{\{\Q$ENV{VAR}\E\}\}/$ENV{VAL}/g' "$TARGET/AGENTS.md"; done
  STACK_JSON="$STACK_JSON" STACKS_DIR="$SRC/core/templates/project/stacks" python3 - "$TARGET/AGENTS.md" "$STACK_SECTION" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text().replace("{{STACK_SECTION}}", sys.argv[2])
import json, os
stacks = []
try:
    d = json.loads(os.environ.get("STACK_JSON") or "{}")
    fw, langs = d.get("frameworks", []), d.get("languages", [])
    for key, cond in (("nextjs", "nextjs" in fw), ("nestjs", "nestjs" in fw), ("golang", "golang" in langs), ("python", "python" in langs),
                      ("rust", "rust" in langs), ("php", "php" in langs), ("ruby", "ruby" in langs), ("flutter", "flutter" in fw or "dart" in langs),
                      ("java", "java" in langs and "kotlin" not in langs), ("kotlin", "kotlin" in langs), ("swift", "swift" in langs), ("csharp", "csharp" in langs),
                      ("angular", "angular" in fw), ("vue", "vue" in fw), ("svelte", "svelte" in fw), ("remix", "remix" in fw)):
        if cond: stacks.append(key)
except Exception: pass
frag = ""
for k in stacks:
    fp = os.path.join(os.environ.get("STACKS_DIR", ""), k + ".md")
    if os.path.exists(fp): frag += "\n" + open(fp).read().strip() + "\n"
if frag: s = s.replace("\n---\n\n## Where Things Live", "\n---\n" + frag + "\n---\n\n## Where Things Live", 1)
p.write_text(s)
PYEOF
  say "wrote AGENTS.md from the project template (none existed)"
else
  say "AGENTS.md exists — left alone"
fi
if [ ! -f "$TARGET/CLAUDE.md" ]; then
  cat > "$TARGET/CLAUDE.md" <<'CLEOF'
# Project instructions for Claude Code

@AGENTS.md

The instructions above are the same ones every other agent reads. What is specific to Claude Code:

- The pipeline's session hooks are registered in `.claude/settings.json` and run automatically:
  they are the early warning for the rules that `wo close`, the git hooks and CI enforce later.
- Work orders name specialist roles. Delegate each role to the subagent of that name; the
  definitions are in `.claude/agents/`.
CLEOF
  say "wrote CLAUDE.md (imports AGENTS.md, plus what is specific to Claude Code)"
elif ! grep -q '@AGENTS.md' "$TARGET/CLAUDE.md" 2>/dev/null; then
  say "CLAUDE.md is yours and was left alone; add the line  @AGENTS.md  to it so Claude Code reads the same instructions"
fi

echo
# The install has committed; the authored files are back in place.
rm -rf "$RECOVERY"

# A count of files installed says nothing about whether they load. Lint says.
if [ -x "$DEST/bin/lint" ]; then
  lrc=0; lout="$("$DEST/bin/lint" "$DEST" 2>/dev/null | tail -1)" || lrc=$?
  case "$lout" in
    "0 error(s)"*) say "lint: $lout";;
    *) say "lint: $lout — see:  $DEST/bin/lint $DEST"; say "      a skill or agent whose frontmatter does not parse is installed and never fires";;
  esac
fi

# Installation is not done when the files are in place; it is done when the
# project has been measured and described. Those are work orders, opened here.
if [ -d "$DEST/core/templates/intake" ] && [ -x "$DEST/bin/acp" ]; then
  echo; echo "Intake — the work orders this project completes before it is operational:"
  (cd "$TARGET" && ACP_INSTALL_UPGRADE="$ACP_UPGRADE" "$DEST/bin/acp" intake 2>&1 | sed 's/^/  /') || true
fi

echo
echo "Done. Next:"
echo "  export PATH=\"$DEST/bin:\$PATH\""
echo "  cd $TARGET && acp intake status     # what is left before the project is operational"
echo "  acp baseline && acp intake inventory   # measure it, and catalogue what it already has"
echo
echo "Project-specific agent rules belong in $PIPELINE_ROOT/core/agents/overlays/,"
echo "not in base/ — base agents are replaced wholesale on the next install."
