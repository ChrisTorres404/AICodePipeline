#!/usr/bin/env bash
# eval-isolation: bin/eval runs each evaluation with its own HOME, git configuration and TMPDIR, all inside the
# evaluation's scratch folder, so no evaluation reads or writes the person's own.
set -uo pipefail
C="$EVAL_TMP/copy"; mkdir -p "$C" && (cd "$PIPELINE_ROOT" && tar -cf - --exclude ./harness/evals/results --exclude ./.git --exclude ./dist .) | (cd "$C" && tar -xf -) \
  || { echo "FAIL setup: could not copy the pipeline"; exit 1; }
# a probe evaluation that reports where it runs and changes its global git configuration
mkdir -p "$C/harness/evals/zz-probe" && cat > "$C/harness/evals/zz-probe/eval.sh" <<'PROBE'
#!/usr/bin/env bash
mkdir -p "$EVAL_TMP/r" && cd "$EVAL_TMP/r" || exit 1; git init -q 2>/dev/null
{ echo "home=$HOME"; echo "tmp=${TMPDIR:-}"; echo "et=$EVAL_TMP"; echo "xdg=${XDG_CONFIG_HOME:-}"; echo "email=$(git config --global user.email 2>/dev/null)"
  echo "glob=$(git config --get acp.glob 2>/dev/null)"; echo "sys=$(git config --get acp.sys 2>/dev/null)"
  echo "envv=$(git config --get acp.env 2>/dev/null)"; echo "par=$(git config --get acp.par 2>/dev/null)"
  echo "aid=$(git var GIT_AUTHOR_IDENT 2>/dev/null)"; echo "cid=$(git var GIT_COMMITTER_IDENT 2>/dev/null)"
  echo "gd=$(git rev-parse --git-dir 2>/dev/null)"; echo "xd=${XDG_DATA_HOME:-}"
  echo "ok=$([ -d "${TMPDIR:-/nonexistent}" ] && [ -d "$HOME" ] && echo y)"; echo "hook=$([ -e .git/hooks/post-checkout ] && echo y)"
  echo "xs=${XDG_STATE_HOME:-}"; echo "xc=${XDG_CACHE_HOME:-}"; } > "$PROBE_OUT"
git config --system acp.write probe 2>/dev/null
git config --global acp.probe touched 2>/dev/null; exit 0
PROBE
# the person: a global file named by GIT_CONFIG_GLOBAL, a system file named by GIT_CONFIG_SYSTEM, an XDG folder,
# settings injected through the environment, an identity, a repository location and an XDG data folder
H="$EVAL_TMP/person"; mkdir -p "$H/.config"; printf '[user]\n\tname = Person\n\temail = person@example.com\n[acp]\n\tglob = person\n' > "$H/.gitconfig"
printf '[acp]\n\tsys = person\n' > "$H/system"; sysbefore="$(cat "$H/system")"
mkdir -p "$H/tpl/hooks"; printf '#!/bin/sh\nexit 0\n' > "$H/tpl/hooks/post-checkout"; chmod +x "$H/tpl/hooks/post-checkout"
before="$(cat "$H/.gitconfig")"
HOME="$H" XDG_CONFIG_HOME="$H/.config" GIT_CONFIG_GLOBAL="$H/.gitconfig" GIT_CONFIG_SYSTEM="$H/system" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=acp.env GIT_CONFIG_VALUE_0=person GIT_CONFIG_PARAMETERS="'acp.par=person'" \
  GIT_AUTHOR_EMAIL=person@example.com GIT_COMMITTER_EMAIL=person@example.com GIT_DIR="$H/nogit" XDG_DATA_HOME="$H/data" \
  XDG_STATE_HOME="$H/state" XDG_CACHE_HOME="$H/cache" GIT_TEMPLATE_DIR="$H/tpl" GIT_TRACE="$H/trace.log" \
  PROBE_OUT="$EVAL_TMP/probe.txt" bash "$C/bin/eval" run zz-probe >/dev/null 2>&1 || { echo "FAIL setup: the probe evaluation did not run"; exit 1; }
home="$(sed -n 's/^home=//p' "$EVAL_TMP/probe.txt")"; tmp="$(sed -n 's/^tmp=//p' "$EVAL_TMP/probe.txt")"; et="$(sed -n 's/^et=//p' "$EVAL_TMP/probe.txt")"; email="$(sed -n 's/^email=//p' "$EVAL_TMP/probe.txt")"
xdg="$(sed -n 's/^xdg=//p' "$EVAL_TMP/probe.txt")"; glob="$(sed -n 's/^glob=//p' "$EVAL_TMP/probe.txt")"; sys="$(sed -n 's/^sys=//p' "$EVAL_TMP/probe.txt")"
v() { sed -n "s/^$1=//p" "$EVAL_TMP/probe.txt"; }; envv="$(v envv)"; par="$(v par)"; aid="$(v aid)"; cid="$(v cid)"; gd="$(v gd)"; xd="$(v xd)"; ok="$(v ok)"; hook="$(v hook)"; xs="$(v xs)"; xc="$(v xc)"
# I1: the evaluation's HOME is not the person's, and sits inside its own scratch folder
{ [ -n "$home" ] && [ "$home" != "$H" ] && case "$home" in "$et"/*) true;; *) false;; esac; } || { echo "FAIL I1: an evaluation ran with the person's HOME"; echo "  HOME was: $home"; exit 1; }
# I2: its TMPDIR sits inside its own scratch folder too
case "$tmp" in "$et"/*) ;; *) echo "FAIL I2: an evaluation's TMPDIR is not its own"; echo "  TMPDIR=$tmp"; exit 1;; esac
[ "$ok" = y ] || { echo "FAIL I2: an evaluation's TMPDIR or HOME does not exist"; exit 1; }
# I3: its git configuration is its own: a test identity, never the person's, and a change to it leaves the person's file alone
{ [ -n "$email" ] && [ "$email" != "person@example.com" ]; } || { echo "FAIL I3: an evaluation read the person's git identity"; echo "  email=$email"; exit 1; }
[ -z "$glob" ] || { echo "FAIL I3: an evaluation read the person's git configuration"; exit 1; }
[ "$(cat "$H/.gitconfig")" = "$before" ] || { echo "FAIL I3: an evaluation changed the person's git configuration"; exit 1; }
# I4: it reads no system git configuration
[ -z "$sys" ] || { echo "FAIL I4: an evaluation read the system git configuration"; exit 1; }
[ "$(cat "$H/system")" = "$sysbefore" ] || { echo "FAIL I4: an evaluation wrote the person's system git configuration"; exit 1; }
# I5: its XDG_CONFIG_HOME (read by git and by tools such as gh) sits inside its own scratch folder
case "$xdg" in "$et"/*) ;; *) echo "FAIL I5: an evaluation's XDG_CONFIG_HOME is not its own"; echo "  XDG_CONFIG_HOME=$xdg"; exit 1;; esac
# I6: none of the person's git identity, settings injected through the environment, repository location or XDG data
case "$aid$cid" in *person@*) echo "FAIL I6: an evaluation's commits carry the person's identity"; exit 1;; esac
[ -z "$envv$par" ] || { echo "FAIL I6: an evaluation read git settings the person injected through the environment"; exit 1; }
[ "$gd" = .git ] || { echo "FAIL I6: an evaluation's git used the person's repository location"; echo "  git dir: $gd"; exit 1; }
case "$xd" in ""|"$et"/*) ;; *) echo "FAIL I6: an evaluation's XDG_DATA_HOME is the person's"; echo "  XDG_DATA_HOME=$xd"; exit 1;; esac
for x in "$xs" "$xc"; do case "$x" in ""|"$et"/*) ;; *) echo "FAIL I6: an evaluation's XDG state or cache folder is the person's"; echo "  $x"; exit 1;; esac; done
[ -z "$hook" ] || { echo "FAIL I6: an evaluation's git init copied the person's template hooks"; exit 1; }
[ ! -s "$H/trace.log" ] || { echo "FAIL I6: an evaluation's git wrote to the person's trace file"; exit 1; }
exit 0
