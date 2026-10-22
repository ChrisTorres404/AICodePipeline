#!/usr/bin/env bash
# title-shape: a title is one line of text short enough for a folder name, and an adopted record's
# number is digits, in wo new, wo adopt, bug new and bug adopt.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug; WD=Workspace/Docs/WorkOrders; BD=Workspace/Docs/Bugs
folders() { ls -d "$WD"/WO-* "$BD"/BUG-* 2>/dev/null | grep -c . || true; }
refused() { # <id> <what> <command...>: the command fails, says why, and makes no folder
  local id="$1" what="$2"; shift 2; local before; before="$(folders)"
  out="$("$@" 2>&1)" && { echo "FAIL $id: $what was accepted"; exit 1; }
  [ "$(folders)" = "$before" ] || { echo "FAIL $id: $what was refused but left a folder"; exit 1; }; }
# T1: wo new refuses a title holding a newline
refused T1 "a wo title holding a newline" $W new $'two\nlines'
printf '%s\n' "$out" | grep -qF "control character" || { echo "FAIL T1: wo new accepted a title holding a newline"; exit 1; }
# T2: bug new refuses it too, and a tab
refused T2 "a bug title holding a newline" $B new $'two\nlines' --category database
printf '%s\n' "$out" | grep -qF "control character" || { echo "FAIL T2: bug new refused without naming the control character"; exit 1; }
refused T2 "a wo title holding a tab" $W new $'a\ttab'
refused T2 "a bug title holding a tab" $B new $'a\ttab' --category database
# T3: a trailing carriage return is dropped, not kept in the title or the folder
n="$($W new $'crlf title\r' 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"
[ -n "$n" ] && grep -qx 'title=crlf title' "$(ls -d "$WD/$n"-*/.wo-meta | head -1)" || { echo "FAIL T3: a trailing carriage return was kept, or the title refused"; exit 1; }
ls -d "$WD/$n"-crlf-title >/dev/null 2>&1 || { echo "FAIL T3: the folder name is not $n-crlf-title"; exit 1; }
n="$($B new $'crlf bug\r' --category database 2>/dev/null | grep -o 'BUG-[0-9][0-9]*' | head -1)"
[ -n "$n" ] && ls -d "$BD/$n"-crlf-bug >/dev/null 2>&1 || { echo "FAIL T3: bug new kept a trailing carriage return, or refused the title"; exit 1; }
# T4: a title longer than 200 characters is refused; 200 is accepted
long="$(printf 'x%.0s' $(seq 1 201))"
refused T4 "a 201-character title" $W new "$long"
printf '%s\n' "$out" | grep -qF "the most is 200" || { echo "FAIL T4: a 201-character title was refused without saying why"; exit 1; }
$W new "${long%x}" >/dev/null 2>&1 || { echo "FAIL T4: a 200-character title was refused"; exit 1; }
refused T4 "a 201-character bug title" $B new "$long" --category database
printf '%s\n' "$out" | grep -qF "the most is 200" || { echo "FAIL T4: bug new refused a 201-character title without saying why"; exit 1; }
e101="$(printf 'é%.0s' $(seq 1 101))"
refused T4 "a 202-byte title of 101 characters" env LC_ALL=C.UTF-8 $W new "$e101"
refused T4 "a 202-byte bug title of 101 characters" env LC_ALL=C.UTF-8 $B new "$e101" --category database
# T5: wo adopt and bug adopt drop a carriage return from the record's heading and refuse a newline in --title
printf '# Adopted record\r\n\nbody\r\n' > old.md
$W adopt old.md --number 30 >/dev/null 2>&1 && grep -qx 'title=Adopted record' "$(ls -d "$WD"/WO-0030-*/.wo-meta | head -1)" \
  || { echo "FAIL T5: wo adopt kept the heading's carriage return, or failed"; exit 1; }
$B adopt old.md --number 34 --category database >/dev/null 2>&1 && grep -qx 'title=Adopted record' "$(ls -d "$BD"/BUG-0034-*/.bug-meta | head -1)" \
  || { echo "FAIL T5: bug adopt kept the heading's carriage return, or failed"; exit 1; }
refused T5 "a wo adopt --title of 201 characters" $W adopt old.md --number 35 --title "$long"
refused T5 "a bug adopt --title of 201 characters" $B adopt old.md --number 36 --category database --title "$long"
refused T5 "a wo adopt --title holding a tab" $W adopt old.md --number 37 --title $'a\tb'
refused T5 "a bug adopt --title holding a tab" $B adopt old.md --number 38 --category database --title $'a\tb'
refused T5 "a wo adopt --title of 202 bytes" env LC_ALL=C.UTF-8 $W adopt old.md --number 39 --title "$e101"
refused T5 "a bug adopt --title of 202 bytes" env LC_ALL=C.UTF-8 $B adopt old.md --number 40 --category database --title "$e101"
printf '# \r\n' > crhead.md
$W adopt crhead.md --number 41 >/dev/null 2>&1 && grep -qx 'title=crhead' "$(ls -d "$WD"/WO-0041-*/.wo-meta | head -1)" \
  || { echo "FAIL T5: wo adopt did not take the file's name for a heading of only a carriage return"; exit 1; }
$B adopt crhead.md --number 42 --category database >/dev/null 2>&1 && grep -qx 'title=crhead' "$(ls -d "$BD"/BUG-0042-*/.bug-meta | head -1)" \
  || { echo "FAIL T5: bug adopt did not take the file's name for a heading of only a carriage return"; exit 1; }
cp crhead.md $'two\nlines.md'
refused T5 "a wo adopt whose file-name title holds a newline" $W adopt $'two\nlines.md' --number 43
refused T5 "a bug adopt whose file-name title holds a newline" $B adopt $'two\nlines.md' --number 44 --category database
refused T5 "a wo adopt --title holding a newline" $W adopt old.md --number 32 --title $'a\nb'
printf '%s\n' "$out" | grep -qF "control character" || { echo "FAIL T5: wo adopt accepted a title holding a newline"; exit 1; }
refused T5 "a bug adopt --title holding a newline" $B adopt old.md --number 31 --category database --title $'a\nb'
printf '%s\n' "$out" | grep -qF "control character" || { echo "FAIL T5: bug adopt accepted a title holding a newline"; exit 1; }
# T8: other control characters (escape, delete, a carriage return inside) are refused in all four commands,
# and in an adopt in place; a 201-byte title is refused and a 200-byte one accepted in both adopts
for ch in $'\033' $'\177' $'\r'; do
  refused T8 "a wo title holding a control character" $W new "a${ch}b"
  refused T8 "a bug title holding a control character" $B new "a${ch}b" --category database
  refused T8 "a wo adopt --title holding a control character" $W adopt old.md --number 45 --title "a${ch}b"
  refused T8 "a bug adopt --title holding a control character" $B adopt old.md --number 46 --category database --title "a${ch}b"
done
mkdir -p "$WD/WO-0047-legacy"; printf '# Legacy\n' > "$WD/WO-0047-legacy/WO-0047-legacy.md"
refused T8 "a wo adopt in place with a newline --title" $W adopt "$WD/WO-0047-legacy/WO-0047-legacy.md" --number 47 --title $'a\nb'
[ ! -e "$WD/WO-0047-legacy/.wo-meta" ] || { echo "FAIL T8: a refused adopt in place wrote its metadata"; exit 1; }
b200="$(printf 'y%.0s' $(seq 1 200))"
$W adopt old.md --number 48 --title "$b200" >/dev/null 2>&1 || { echo "FAIL T8: wo adopt refused a 200-byte title"; exit 1; }
$B adopt old.md --number 49 --category database --title "$b200" >/dev/null 2>&1 || { echo "FAIL T8: bug adopt refused a 200-byte title"; exit 1; }
refused T8 "a wo adopt --title of 201 bytes" $W adopt old.md --number 50 --title "${b200}y"
# T9: a record's long heading is trimmed to 200 bytes on a character boundary, not refused (90 three-byte letters)
printf '# %s\n' "$(printf '日%.0s' $(seq 1 90))" > cjk.md
for drv in wo bug; do
  case "$drv" in wo) LC_ALL=C.UTF-8 $W adopt cjk.md --number 51 >/dev/null 2>&1; m="$(ls -d "$WD"/WO-0051-*/.wo-meta 2>/dev/null | head -1)";;
                 bug) LC_ALL=C.UTF-8 $B adopt cjk.md --number 52 --category database >/dev/null 2>&1; m="$(ls -d "$BD"/BUG-0052-*/.bug-meta 2>/dev/null | head -1)";; esac
  [ -n "$m" ] || { echo "FAIL T9: $drv adopt refused a record whose heading is longer than 200 bytes"; exit 1; }
  t="$(sed -n 's/^title=//p' "$m")"
  [ "$(printf '%s' "$t" | LC_ALL=C wc -c | tr -d ' ')" -le 200 ] && [ "$(printf '%s' "$t" | iconv -f UTF-8 -t UTF-8 2>/dev/null)" = "$t" ] \
    || { echo "FAIL T9: $drv adopt did not trim the heading to 200 bytes on a character boundary"; exit 1; }
done
# T6: --number must be digits: anything else is refused before it is used, and never runs
# (at the base, $((10#$num)) runs the command substitution inside an array subscript)
for drv in wo bug; do
  case "$drv" in wo) cmd=("$W" adopt old.md --number '1+PATH[$(touch PWNED)]');; bug) cmd=("$B" adopt old.md --category database --number '1+PATH[$(touch PWNED)]');; esac
  refused T6 "$drv adopt --number holding code" "${cmd[@]}"
  [ ! -e PWNED ] || { echo "FAIL T6: $drv adopt ran its --number as code"; exit 1; }
  printf '%s\n' "$out" | grep -qF "must be digits" || { echo "FAIL T6: $drv adopt refused --number without saying it must be digits"; exit 1; }
done
refused T6 "wo adopt --number 1a" $W adopt old.md --number 1a
printf '%s\n' "$out" | grep -qF "must be digits" || { echo "FAIL T6: wo adopt took --number 1a"; exit 1; }
refused T6 "bug adopt --number 1a" $B adopt old.md --category database --number 1a
printf '%s\n' "$out" | grep -qF "must be digits" || { echo "FAIL T6: bug adopt took --number 1a"; exit 1; }
# T7: ordinary titles, including / and non-ASCII letters, still open
$W new "café / déjà vu" >/dev/null 2>&1 && $B new "café / déjà vu" --category database >/dev/null 2>&1 || { echo "FAIL T7: an ordinary title was refused"; exit 1; }
exit 0
