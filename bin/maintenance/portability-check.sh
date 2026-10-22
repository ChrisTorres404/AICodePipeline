#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# portability-check.sh — refuse shell that only runs on one of the two targets
#
#   bin/maintenance/portability-check.sh [<root>] [--list]
#
# The drivers, hooks, and harness must behave identically under bash 3.2 with a
# BSD userland (macOS) and bash 5 with GNU coreutils (Linux). Nothing here runs
# the scripts; it greps every shell script in the tree for constructs that exist
# on only one side, or that mean different things on each, and fails if any is
# present. --list prints the rules without scanning.
#
# Scanned: every *.sh and every extension-less file whose shebang names a shell,
# under the repository root, excluding .git, node_modules, dist, __pycache__,
# playbooks, and Examples_for_claude.
#
# bin/dev/dev-toggle.sh is exempt from the macOS-command rule alone: it is
# documented at the top of the file as macOS-only and cannot be written twice.
#
# Exit 0 clean, 1 if any construct was found, 2 on a usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=""
LIST_ONLY=0
for a in "$@"; do
  case "$a" in
    --list) LIST_ONLY=1;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) echo "portability-check: unknown flag $a" >&2; exit 2;;
    *) ROOT="$a";;
  esac
done
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -d "$ROOT" ] || { echo "portability-check: $ROOT is not a directory" >&2; exit 2; }
ROOT="$(cd "$ROOT" && pwd)"

SELF_REL="bin/maintenance/portability-check.sh"
MACOS_EXEMPT="bin/dev/dev-toggle.sh"

FOUND=0
LIST_FILE=""

# --- the file list ---------------------------------------------------------
collect() {
  tmpbase="${TMPDIR:-/tmp}"; LIST_FILE="$(mktemp "${tmpbase%/}/acp-portability.XXXXXX")"
  find "$ROOT" \
      \( -name .git -o -name node_modules -o -name dist -o -name __pycache__ \
         -o -name playbooks -o -name Examples_for_claude -o -name results \) -prune \
      -o -type f -print 2>/dev/null |
  while IFS= read -r f; do
    case "${f#$ROOT/}" in "$SELF_REL") continue;; esac
    case "$f" in
      *.sh|*.bash) echo "$f"; continue;;
      *.md|*.json|*.py|*.js|*.mjs|*.cjs|*.ts|*.sql|*.env|*.txt|*.yml|*.yaml|*.lock) continue;;
    esac
    # extension-less drivers: read the shebang with the builtin, so a shell
    # named after `env` (`#!/usr/bin/env bash`) is recognised too.
    line=""
    IFS= read -r line < "$f" 2>/dev/null || true
    case "$line" in '#!'*sh*) echo "$f";; esac
  done > "$LIST_FILE"
}

# --- one rule: id, ERE, why ------------------------------------------------
# A line carrying the comment `portability-ok: <rule-id>` is not reported: that
# marks a construct that is already paired with a fallback for the other side,
# and the comment says which rule it answers. Optional 4th argument is an ERE
# for lines this rule accepts without a pragma.
rule() {
  local id="$1" re="$2" why="$3" allow="${4:-}" hits
  if [ "$LIST_ONLY" -eq 1 ]; then printf '  %-22s %s\n' "$id" "$why"; return 0; fi
  # NUL-separated, so a path holding a space or a quote reaches grep whole; /dev/null makes grep name
  # the file even when xargs hands it one alone.
  hits="$(tr '\n' '\0' < "$LIST_FILE" | xargs -0 grep -nE -- "$re" /dev/null 2>/dev/null || true)"
  hits="$(printf '%s\n' "$hits" | grep -vE "portability-ok:[[:space:]]*$id" || true)"
  [ -n "$allow" ] && hits="$(printf '%s\n' "$hits" | grep -vE -- "$allow" || true)"
  case "$id" in
    macos-only) hits="$(printf '%s\n' "$hits" | grep -v "$MACOS_EXEMPT" || true)";;
  esac
  hits="$(printf '%s' "$hits" | grep -v '^$' || true)"
  [ -z "$hits" ] && return 0
  FOUND=1
  printf '\n  %s — %s\n' "$id" "$why"
  local h; printf '%s\n' "$hits" | while IFS= read -r h; do printf '    %s\n' "${h#"$ROOT"/}"; done   # the root as data
}

rules() {
  # in-place editing: BSD needs `-i ''`, GNU rejects it. Use perl -pi -e.
  rule "sed-in-place"   'sed[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*-i|sed[[:space:]]+-i' \
       "sed -i differs between BSD and GNU; use perl -pi -e or write to a temp file"

  # stat(1) flags are disjoint between the two userlands.
  rule "stat-flags"     'stat[[:space:]]+-[a-zA-Z]*[fc][[:space:]]' \
       "stat -f (BSD) and stat -c (GNU) are not interchangeable; use python3, or try GNU first and fall back" \
       'stat -c.*\|\|.*stat -f'

  # date(1): -j/-f is BSD only, -d/--date is GNU only, %N is not on old BSD.
  rule "date-flags"     'date[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-(j|d)([[:space:]]|$)|date[[:space:]]+--date|date[[:space:]]+\+[^ ]*%N' \
       "date -j/-f is BSD only, -d/--date is GNU only, %N is absent on older BSD; use python3 for date arithmetic"

  # bash 4 only; macOS ships bash 3.2.
  rule "bash4-assoc"    '(declare|local|typeset)[[:space:]]+-[a-zA-Z]*A([[:space:]]|$)' \
       "associative arrays need bash 4; macOS ships bash 3.2"
  rule "bash4-mapfile"  '(^|[^[:alnum:]_])(mapfile|readarray)([[:space:]]|$)' \
       "mapfile/readarray need bash 4; read in a while loop instead"
  rule "bash4-case"     '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^|,|\^)\}' \
       "\${var,,} and \${var^^} need bash 4; use tr '[:upper:]' '[:lower:]'"
  rule "bash4-misc"     ';;&|shopt[[:space:]]+-s[[:space:]]+globstar|wait[[:space:]]+-n([[:space:]]|$)' \
       ";;& , globstar and wait -n need bash 4"

  # GNU-only utilities and flags.
  rule "readlink-f"     'readlink[[:space:]]+-[a-zA-Z]*f' \
       "readlink -f is absent on older macOS; use cd+pwd or python3 os.path.realpath"
  rule "realpath"       '(^|[^[:alnum:]_/-])realpath([[:space:]]|$)' \
       "realpath(1) is not installed on macOS; use cd+pwd or python3"
  rule "mktemp-t"       'mktemp[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*-t([[:space:]]|$)' \
       "mktemp -t means a prefix on BSD and a template on GNU; pass an explicit XXXXXX template"
  # a mktemp -d with no template: macOS ignores TMPDIR then and uses its own folder
  rule "mktemp-bare"    'mktemp([[:space:]]+-[a-zA-Z]+)*[[:space:]]+-[a-zA-Z]*d[a-zA-Z]*([[:space:]]+-[a-zA-Z]+)*[[:space:]]*($|[);|&`<>]|[0-9][<>])' \
       "mktemp -d with no template ignores TMPDIR on macOS; pass one, as mktemp -d \"\${TMPDIR:-/tmp}/name.XXXXXX\""
  rule "xargs-r"        'xargs[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*r([[:space:]]|$)|--no-run-if-empty' \
       "xargs -r is GNU only; guard the pipeline instead"
  rule "grep-perl"      '(^|[^[:alnum:]_.-])(z|bz|xz|lz|zstd)?grep[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*P([[:space:]]|$)|--perl-regexp' \
       "grep -P is GNU only; use -E with POSIX classes"
  rule "find-printf"    'find[[:space:]].*-printf' \
       "find -printf is GNU only; use -exec or a read loop"
  rule "gnu-long-opts"  'ls[[:space:]]+--(color|format|time-style|group-directories|quoting-style)|cp[[:space:]]+--parents|du[[:space:]]+-[a-zA-Z]*b([[:space:]]|$)|base64[[:space:]]+-[a-zA-Z]*w|sort[[:space:]]+-[a-zA-Z]*V([[:space:]]|$)|install[[:space:]]+-[a-zA-Z]*D|ln[[:space:]]+--relative' \
       "these long options and flags exist only in GNU coreutils"
  rule "gnu-digests"    '(^|[^[:alnum:]_-])(sha[0-9]+sum|md5sum)([[:space:]]|$)' \
       "sha256sum/md5sum are GNU names; macOS has shasum and md5"
  rule "head-tail-neg"  '(head|tail)[[:space:]]+-c[[:space:]]*-[0-9]' \
       "negative byte counts for head/tail are GNU only"
  rule "timeout"        '(^|[^[:alnum:]_./-])timeout[[:space:]]+[0-9]' \
       "timeout(1) is not installed on macOS; use a background process and kill, or curl --max-time"
  rule "gnu-getopt"     '(^|[^[:alnum:]_./-])getopt([[:space:]]|$)' \
       "enhanced getopt(1) is GNU only; parse with a case loop or use getopts"
  rule "proc-nproc"     '\$\(nproc|`nproc|(^|[;&|(][[:space:]]*)nproc([[:space:]]|$)|free[[:space:]]+-[bkmghw]|(^|[^[:alnum:]_.-])/proc/[a-z]' \
       "nproc, free and /proc are Linux only; use sysctl/uname guards or a fixed default"

  # BSD sed understands none of these escapes; GNU sed does, so the same
  # expression silently means two different things.
  rule "sed-gnu-regex"  'sed[^|]*\\[+?sSwWbdD<>|]' \
       'BSD sed has no \s \b \+ \? \| escapes; use POSIX classes such as [[:space:]] and [x][x]*'

  # macOS-only commands. bin/dev/dev-toggle.sh is exempt and says so at its top.
  rule "macos-only"     '(^|[^[:alnum:]_./-])(dscacheutil|sw_vers|pbcopy|pbpaste|osascript|launchctl|sysctl[[:space:]]+-n[[:space:]]+hw\.)' \
       "these commands exist only on macOS; guard them or keep them in a script documented as macOS-only"
}

if [ "$LIST_ONLY" -eq 1 ]; then
  echo "portability-check rules:"
  rules
  exit 0
fi

collect
n="$(wc -l < "$LIST_FILE" | tr -d ' ')"
echo "portability-check — $n shell scripts under $ROOT"
rules
rm -f "$LIST_FILE"

echo
if [ "$FOUND" -eq 0 ]; then
  echo "  clean — nothing found that runs on only one of macOS and Linux"
  exit 0
fi
echo "  FAIL — the constructs above run on only one of the two targets"
exit 1
