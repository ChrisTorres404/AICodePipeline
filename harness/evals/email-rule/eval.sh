#!/usr/bin/env bash
# email-rule: an address at a personal mail provider stays a CRITICAL pii.email finding in every mode;
# any other real address is an email.address WARNING; reserved documentation names, noreply senders,
# URL user parts, git@ remotes, package pins and image density names are not addresses to report.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
S="$PIPELINE_ROOT/bin/sanitize"
# every address is built at run time, so this file holds none
at="@"; work="jane.doe${at}bigcorp-holdings.com"; ops="ops${at}bigcorp-holdings.com"; personal="bob.smith${at}gmail.com"; shouted="BOB${at}GMAIL.COM"
mkdir -p p1 p2 p3 p4 p5 logs w r n x m
printf 'owner %s\n' "$personal" > p1/notes.md
printf 'owner %s\n' "$shouted" > p3/notes.md
printf 'owner j\303\274rgen%sgmail.com_x\n' "$at" > p4/notes.md
printf 'owner %s.au\n' "$personal" > p5/notes.md
printf 'nothing to see\n' > p2/notes.md
printf 'run started\nmailed %s\n' "$personal" > logs/run.log
{ printf 'contact %s for access\nwrite to mailto:%s\n' "$work" "$ops"
  printf 'see https://bigcorp-holdings.com and write to %s\n' "$ops"
  printf 'see https://bigcorp-holdings.com/team?owner=%s\n' "$ops"
  printf 'odd =://%s\n' "$ops"
  printf 'see https://bigcorp-holdings.com\302\240%s\n' "$ops"
  printf 'see https://bigcorp-holdings.com\343\200\200%s\n' "$ops"
  printf 'site https://bigcorp-holdings.com %s\n' "$ops"
  printf '{"homepage":"https://bigcorp-holdings.com","author":"%s"}\n' "$ops"; } > w/notes.md
{ for d in example.com example.net example.org mail.example.com; do printf 'a%s%s\n' "$at" "$d"; done
  for t in test example invalid localhost; do printf 'b%sapp.%s\n' "$at" "$t"; done; } > r/notes.md
{ printf 'noreply%sbigcorp-holdings.com\n' "$at"; printf 'no-reply%sbigcorp-holdings.com\n' "$at"
  printf 'NoReply%sbigcorp-holdings.com\n' "$at"; printf '12345+bot%susers.noreply.github.com\n' "$at"; } > n/notes.md
{ printf 'clone https://deploy:hunter%sgit.bigcorp-holdings.com/team/app\n' "$at"
  printf 'browse https://deploy%sgit.bigcorp-holdings.com/team/app\n' "$at"
  printf 'pull https://deploy:p%sss%sgit.bigcorp-holdings.com/team/app\n' "$at" "$at"
  printf 'remote git%sgithub.com:org/repo.git and git%sgitlab.bigcorp-holdings.com:team/app.git\n' "$at" "$at"
  printf 'pins left-pad%s1.2.3 and @scope/pkg%s4.17.21\n' "$at" "$at"
  printf 'icons icon%s2x.png and icon%s3x.png\n' "$at" "$at"; } > x/notes.md
printf 'from noreply%sbigcorp-holdings.com then %s\n' "$at" "$work" > m/notes.md
scan() { out="$("$S" "$@" 2>&1)"; rc=$?; }
has() { printf '%s\n' "$out" | grep -cF "**[$1]** \`$2\`" || true; }
# E1: a personal address is a CRITICAL pii.email finding in a default scan, and not also an email.address warning:
# the domain in any case, a user part after a non-ASCII letter, an underscore after the domain, a country suffix
for d in p1 p3 p4 p5; do
  scan "$d"
  { [ "$rc" -eq 2 ] && [ "$(has pii.email notes.md:1)" = 1 ] && [ "$(has email.address notes.md:1)" = 0 ]; } \
    || { echo "FAIL E1: a personal address was not a CRITICAL pii.email finding"; echo "  $d: exit $rc"; exit 1; }
done
# E2: it stays CRITICAL in every mode: --quiet, --report, several folders, and a .log file with --include-logs
scan p1 --quiet; r1=$rc
scan p1 --report rep.md; r2=$rc; grep -qF '**Verdict:** FAIL' rep.md || r2=x
scan p2 p1; r3=$rc; [ "$(has pii.email p1/notes.md:1)" = 1 ] || r3=x
scan logs --include-logs; r4=$rc; [ "$(has pii.email run.log:2)" = 1 ] || r4=x
{ [ "$r1" = 2 ] && [ "$r2" = 2 ] && [ "$r3" = 2 ] && [ "$r4" = 2 ]; } \
  || { echo "FAIL E2: a personal address was not CRITICAL in every mode"; echo "  exits $r1 $r2 $r3 $r4"; exit 1; }
# E3: an address at any other domain is an email.address WARNING, a mailto: one too, one after a URL earlier
# on the line (the address after an ASCII space, a no-break space U+00A0 or an ideographic space U+3000 that
# follows the URL), one in a URL's path or query, one after a :// with no scheme before it, and one in minified
# JSON after a URL with no path; nothing is critical
scan w
warned_on() { for l in "$@"; do [ "$(has email.address "notes.md:$l")" = 1 ] || return 1; done; }
{ [ "$rc" -eq 1 ] && warned_on 1 2 3 4 5 6 7 8 9 \
  && printf '%s\n' "$out" | grep -qxF '## Critical findings (0)'; } \
  || { echo "FAIL E3: an address at a work domain was not reported as an email.address warning"; echo "  exit $rc"; exit 1; }
# E4: the report shows four characters of the address, never the whole of it
printf '%s\n' "$out" | grep -qF "$work" && { echo "FAIL E4: the report printed a whole address"; exit 1; }
# E5: reserved documentation names are not reported: example.com/.net/.org and their subdomains, .test, .example, .invalid, .localhost
scan r
[ "$rc" -eq 0 ] || { echo "FAIL E5: an address at a reserved documentation name was reported"; echo "  exit $rc"; printf '%s\n' "$out" | grep -F '**['; exit 1; }
# E6: noreply senders are not reported: noreply and no-reply in any case, and the GitHub noreply domain
scan n
[ "$rc" -eq 0 ] || { echo "FAIL E6: a noreply address was reported"; echo "  exit $rc"; printf '%s\n' "$out" | grep -F '**['; exit 1; }
# E7: shapes that only look like an address are not reported: URL user parts, git@ remotes, package pins, image names
scan x
[ "$rc" -eq 0 ] || { echo "FAIL E7: something that is not an address was reported as one"; echo "  exit $rc"; printf '%s\n' "$out" | grep -F '**['; exit 1; }
# E8: a noreply address earlier on a line does not hide a real address later on it
scan m
{ [ "$rc" -eq 1 ] && [ "$(has email.address notes.md:1)" = 1 ]; } \
  || { echo "FAIL E8: a real address after a noreply one on the same line was not reported"; echo "  exit $rc"; exit 1; }
# E9: the rule's work per match is bounded: a 20,000-character token then 100 image names on one line
# (the shape of a minified bundle) scans in under 30 seconds (about 1 s alone, most of it an existing key-file
# pattern that is already quadratic at the base; slower under parallel suites and CI runners; an unbounded
# look-back took ~57 s)
mkdir -p t; { printf '%*s' 20000 '' | tr ' ' a; i=0; while [ "$i" -lt 100 ]; do printf ' icon%s2x.png' "$at"; i=$((i + 1)); done; echo; } > t/bundle.js
SECONDS=0; scan t; took=$SECONDS
{ [ "$rc" -eq 0 ] && [ "$took" -lt 30 ]; } \
  || { echo "FAIL E9: a long line with many image names took ${took}s or was reported"; echo "  exit $rc"; exit 1; }
# E10: the two email patterns alone grow linearly with the line, timed without the rest of the scan: a
# 100,000-character user part, a 100,000-character dotted run, image names and URLs (well under 1 s now; a
# personal test that re-searches the user part takes ~29 s, a pii regex starting at every word boundary ~15 s)
took="$(python3 -I - "$S" <<'PY'
import runpy, sys, time
g = runpy.run_path(sys.argv[1]); at = chr(64)
rx, ok, pii = g["EMAIL_RE"], g["email_is_reportable"], g["PERSONAL_EMAIL_RE"]
lines = ["a%" * 50000 + at + "b.cc", "a." * 50000 + at, "a" * 100000 + (" icon" + at + "2x.png") * 2000,
         ("https://u:p" + at + "bigcorp-holdings.com,") * 10000, ("u" + at + "b.cc,") * 20000]
worst = 0.0
for line in lines:
    t = time.time(); sum(1 for m in rx.finditer(line) if ok(m, line)); pii.search(line); worst = max(worst, time.time() - t)
print(int(worst))
PY
)"
[ -n "$took" ] && [ "$took" -lt 5 ] \
  || { echo "FAIL E10: the email patterns took ${took:-?}s on one long line"; exit 1; }
exit 0
