#!/usr/bin/env bash
# acp migrate plan reads a messy project (a repository inside the project folder, work beside it,
# second ACP copies, loose documents, private files, stale branches) and writes .acp-migration/ only: every entry
# with where it goes, every decision as a numbered question, and what blocks apply. Nothing else changes, nothing
# is lost by being called identical, and nothing in the project runs.
set -uo pipefail
ACP="$PIPELINE_ROOT/bin/acp"; PY="$(command -v python3)"
G() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
plan() { perl -e 'alarm 60; exec @ARGV' "$ACP" migrate plan "$@"; }   # a hang ends at 60 s, as a failure
P="$EVAL_TMP/proj"; R="$P/eng"; W=Workspace/Docs/WorkOrders; B=Workspace/Docs/Bugs
PASS='**Overall status:** EXECUTED — PASS (last run 1)'
order() { mkdir -p "$1" && printf '# closeout\n' > "$1/$2-CLOSEOUT.md" && printf '# V\n\n%s\n' "$3" > "$1/$2-VERIFICATION.md"; }
cleanup() { chmod -R u+rwx "$EVAL_TMP" 2>/dev/null || true; }; trap cleanup EXIT
# --- the synthetic mess, built here, nothing taken from any real project ---
mkdir -p "$R" && G -C "$R" init -q || { echo "FAIL setup: git init"; exit 1; }
printf 'export WORKORDERS_DIR="Workspace/Docs/WorkOrders"\nexport BUGS_DIR="Workspace/Docs/Bugs"   # bugs\nexport PIPELINE_ROOT=".aicodepipeline"\nexport LAYOUT_ROOT_EXTRA="Makefile"\n' > "$R/pipeline.config.sh"
mkdir -p "$R/.aicodepipeline/bin" "$R/src" "$R/tests" "$R/docs" "$R/.claude" "$R/spec"
printf 'tool\n' > "$R/.aicodepipeline/bin/wo"; printf 'print(1)\n' > "$R/src/main.py"; printf 't\n' > "$R/tests/t.py"; printf 'd\n' > "$R/docs/d.md"; printf 'r\n' > "$R/spec/a_spec.rb"
printf 'm\n' > "$R/Makefile"; mkdir -p "$EVAL_TMP/elsewhere-cfg" && ln -s "$EVAL_TMP/elsewhere-cfg" "$R/.devcontainer"; printf 'r\n' > "$R/README.md"; printf 'c\n' > "$R/CLAUDE.md"; printf '{}\n' > "$R/.claude/settings.json"; printf '*.log\n' > "$R/.gitignore"; printf 'h\n' > "$R/HANDOFF-2026-01-01.md"
for n in 0001-alpha 0002-beta 0004-delta 0005-eps 0006-zeta 0007-eta 0010-theta 0011-iota 0013-kappa 0014-lambda 0016-pi 0017-rho; do order "$R/$W/WO-$n" "WO-${n%%-*}" "$PASS"; done
order "$R/$B/BUG-0001-gamma" BUG-0001 "$PASS"; printf 'aaaa\n' > "$R/$W/WO-0007-eta/u.md"
mkdir -p "$R/docs/old/WO-0050-stray" && printf 's\n' > "$R/docs/old/WO-0050-stray/WO-0050-SPEC.md"
G -C "$R" add -A && G -C "$R" commit -qm base && G -C "$R" branch merged-one && G -C "$R" checkout -q -b ahead-one && printf 'x\n' > "$R/src/x.py" \
  && G -C "$R" add -A && G -C "$R" commit -qm ahead && G -C "$R" checkout -q main || { echo "FAIL setup: repository"; exit 1; }
acpcopy() { # <folder>: a second ACP source clone, clean and fully pushed
  mkdir -p "$1/bin" "$1/core/hooks" && printf 'w\n' > "$1/bin/wo" && printf 'i\n' > "$1/bin/install.sh" && printf 'h\n' > "$1/core/hooks/x.py" && printf '1.4.1\n' > "$1/VERSION" && printf 'dist/\n' > "$1/.gitignore" \
    && G -C "$1" init -q && G -C "$1" add -A && G -C "$1" commit -qm s && G init -q --bare "$1-remote.git" && G -C "$1" remote add origin "$1-remote.git" && G -C "$1" push -q -u origin main 2>/dev/null; }
acpcopy "$P/acpclone" || { echo "FAIL setup: second ACP clone"; exit 1; }
# a third: a local-only branch, a stash, an ignored file
acpcopy "$P/acp2" && G -C "$P/acp2" checkout -q -b local-only && printf 'l\n' > "$P/acp2/l.txt" && G -C "$P/acp2" add -A && G -C "$P/acp2" commit -qm l && G -C "$P/acp2" checkout -q main \
  && printf 'w2\n' > "$P/acp2/bin/wo" && G -C "$P/acp2" stash -q && mkdir -p "$P/acp2/dist" && printf 'b\n' > "$P/acp2/dist/build.txt" \
  && printf 'u\n' > "$P/acp2/untracked.txt" || { echo "FAIL setup: acp2"; exit 1; }   # and an untracked file
# work beside the repository
order "$P/work/WO-0003-only" WO-0003 "$PASS"; order "$P/WO-0008-top" WO-0008 "$PASS"
cp -R "$R/$W/WO-0001-alpha" "$P/work/"; printf 'changed\n' >> "$P/work/WO-0001-alpha/WO-0001-VERIFICATION.md"
cp -R "$R/$W/WO-0002-beta" "$P/work/"; cp -R "$R/$W/WO-0004-delta" "$P/work/" && printf 'only here\n' > "$P/work/WO-0004-delta/notes.md"
cp -R "$R/$W/WO-0005-eps" "$P/work/" && printf '# V\n\n%s\n' "$PASS" | tr 'P' 'Q' > "$P/work/WO-0005-eps/WO-0005-VERIFICATION.md"   # same size, other bytes
cp -R "$R/$W/WO-0006-zeta" "$P/work/" && mkdir -p "$P/work/WO-0006-zeta/locked" && printf 'hidden\n' > "$P/work/WO-0006-zeta/locked/only.md"   # unreadable below
cp -R "$R/$W/WO-0007-eta" "$P/work/" && printf 'bbbb\n' > "$P/work/WO-0007-eta/u.md"   # unreadable on both sides below, same size, other bytes
cp -R "$R/$W/WO-0010-theta" "$P/work/" && mkfifo "$P/work/WO-0010-theta/pipe" || { echo "FAIL setup: mkfifo"; exit 1; }
cp -R "$R/$W/WO-0011-iota" "$P/work/" && G -C "$P/work/WO-0011-iota" init -q && G -C "$P/work/WO-0011-iota" add -A && G -C "$P/work/WO-0011-iota" commit -qm own || { echo "FAIL setup: order repo"; exit 1; }
cp -R "$R/$W/WO-0013-kappa" "$P/work/" && mkdir -p "$P/work/WO-0013-kappa/tool" && G -C "$P/work/WO-0013-kappa/tool" init -q && printf 't\n' > "$P/work/WO-0013-kappa/tool/t.txt" \
  && G -C "$P/work/WO-0013-kappa/tool" add -A && G -C "$P/work/WO-0013-kappa/tool" commit -qm only-here || { echo "FAIL setup: nested repo in a copy"; exit 1; }
cp -R "$R/$W/WO-0014-lambda" "$P/work/" && mkdir -p "$P/work/WO-0014-lambda/.git" && printf 'x\n' > "$P/work/WO-0014-lambda/.git/kept.md"   # a .git with no HEAD
cp -R "$R/$W/WO-0016-pi" "$P/work/" && chmod +x "$P/work/WO-0016-pi/WO-0016-CLOSEOUT.md"   # only the exec bit differs
cp -R "$R/$W/WO-0017-rho" "$P/work/" && mkdir -p "$P/work/WO-0017-rho/extra"   # an empty folder only here
D8="$P/work/a/b/c/d/e/f/g"; order "$D8/WO-0015-deep" WO-0015 "$PASS" && mkdir -p "$D8/h/deeprepo" && G -C "$D8/h/deeprepo" init -q || { echo "FAIL setup: deep"; exit 1; }
mkdir -p "$P/work/close15" && cp -R "$R/$B/BUG-0001-gamma" "$P/work/close15/" && rm -f "$P/work/close15/BUG-0001-gamma/BUG-0001-VERIFICATION.md"
mkdir -p "$P/work/tools/inner" && G -C "$P/work/tools/inner" init -q && printf 'i\n' > "$P/work/tools/inner/i.txt" && G -C "$P/work/tools/inner" add -A && G -C "$P/work/tools/inner" commit -qm i || { echo "FAIL setup: inner repo"; exit 1; }
mkdir -p "$P/work/run1-logs" && printf 'log\n' > "$P/work/run1-logs/a.log" && printf 'p\n' > "$P/work/fix.patch" && printf 'n\n' > "$P/work/close15/notes.txt"
printf 'x\n' > "$P/work/odd
name.txt"; ln -s nowhere "$P/work/dangling"; ln -s .. "$P/work/run1-logs/up"
mkdir -p "$P/specs" "$P/handoff" "$P/kb-before-1/profiles" "$P/kb-restore/profiles" "$P/profiles" "$P/thing-share"
printf 's\n' > "$P/specs/s.md"; printf 'h\n' > "$P/handoff/h.md"; printf 'a\n' > "$P/AUDIT-2026-01-02.md"; printf 'w\n' > "$P/WORK-PLAN-2026-01-03.md"; printf 'f\n' > "$P/FOLLOW-UPS.md"
printf 'k\n' > "$P/kb-before-1/profiles/p.md"; printf 'k\n' > "$P/kb-notes.md"; printf 'k\n' > "$P/kb-restore/profiles/p.md"
# snapshots not read whole: a folder that cannot be listed, and a .git with no HEAD
mkdir -p "$P/kb-locked/profiles" "$P/kb-locked/sealed" "$P/kb-gitted/profiles" "$P/kb-gitted/.git" && printf 'k\n' > "$P/kb-locked/sealed/s.md" && printf 'g\n' > "$P/kb-gitted/.git/g.md"
printf 'p: 1\n' > "$P/profiles/client.setup.yaml"; printf 'z' > "$P/thing-share/pkg.zip"; printf 'm\n' > "$P/mystery.bin"
# a tracked file newer than the index (a refreshing status would rewrite .git/index), and an fsmonitor hook that
# must never run
"$PY" -c 'import os, sys, time; t = time.time() + 5; os.utime(sys.argv[1], (t, t))' "$R/src/main.py"
printf '#!/bin/sh\ntouch "%s/fsmonitor-ran"\n' "$EVAL_TMP" > "$EVAL_TMP/fsm.sh" && chmod +x "$EVAL_TMP/fsm.sh" && G -C "$R" config core.fsmonitor "$EVAL_TMP/fsm.sh" || { echo "FAIL setup: fsmonitor"; exit 1; }
chmod 000 "$P/work/WO-0006-zeta/locked" "$R/$W/WO-0007-eta/u.md" "$P/work/WO-0007-eta/u.md" "$P/kb-locked/sealed"
# every entry, folders too, with its type, mode, size, time and content (links and special files never opened)
snap() { "$PY" - "$P" <<'PYEOF'
import hashlib, os, stat, sys
top = sys.argv[1]; rows = []
for dp, dns, fns in os.walk(top, followlinks=False, onerror=lambda e: rows.append("UNREADABLE %r" % e.filename)):
    if dp == top and ".acp-migration" in dns: dns.remove(".acp-migration")
    for n in sorted(dns) + sorted(fns):
        p = os.path.join(dp, n); st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode): info = "link " + os.readlink(p)
        elif stat.S_ISREG(st.st_mode):
            try:
                with open(p, "rb") as f: info = hashlib.sha256(f.read()).hexdigest()
            except OSError: info = "unreadable"
        else: info = "dir" if stat.S_ISDIR(st.st_mode) else "special"
        rows.append("%r %o %d %d %s" % (os.path.relpath(p, top), st.st_mode, st.st_size, st.st_mtime_ns, info))
st = os.lstat(top); rows.append("TOP %o" % st.st_mode)   # its time moves when .acp-migration/ is made in it, the one write allowed
print("\n".join(sorted(rows)))
PYEOF
}
before="$(snap)"
# M1: plan writes the plan and the moves file, and says so
out="$(cd "$P" && plan 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$P/.acp-migration/MIGRATION-PLAN.md" ] && [ -f "$P/.acp-migration/moves.json" ]; } || { echo "FAIL M1: acp migrate plan did not write a plan"; exit 1; }
printf '%s\n' "$out" | grep -qF "Nothing moved." || { echo "FAIL M1: plan did not say nothing moved: $out"; exit 1; }
# M2: nothing in the project changed (every entry: type, mode, size, time, content; .git included); only the two
# plan files are new; the fsmonitor hook never ran
[ "$before" = "$(snap)" ] || { echo "FAIL M2: plan changed the project outside .acp-migration/"; exit 1; }
[ "$(ls -A "$P/.acp-migration" | LC_ALL=C sort | tr '\n' ' ')" = "MIGRATION-PLAN.md moves.json " ] || { echo "FAIL M2: .acp-migration holds more than the plan and the moves file"; exit 1; }
[ ! -e "$EVAL_TMP/fsmonitor-ran" ] || { echo "FAIL M2: plan ran the repository's fsmonitor hook"; exit 1; }
J="$P/.acp-migration/moves.json"
ent() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); e=[x for x in d['entries'] if x['path']==sys.argv[2]]; print((e[0]['kind'] + ' -> ' + e[0]['to']) if e else 'MISSING')" "$J" "$1"; }
field() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); e=[x for x in d['entries'] if x['path']==sys.argv[2]]; print(e[0].get(sys.argv[3], '') if e else 'MISSING')" "$J" "$1" "$2"; }
expect() { # <case> <path> <kind -> to>
  local got; got="$(ent "$2")"; [ "$got" = "$3" ] || { echo "FAIL $1: $2 is classified '$got', expected '$3'"; exit 1; }; }
# M3: the repository's root: what tools read at the root stays there unasked (layout.py's names and prefixes, and the
# project's LAYOUT_ROOT_EXTRA), unless it is a link leading out; pipeline to acp/, product to app/ (a root spec/
# included), either-side asked
expect M3 eng/pipeline.config.sh "tool-bound -> root"
expect M3 eng/Makefile "tool-bound -> root"
expect M3 eng/.devcontainer "tool-bound -> root (asked: a link leading out)"
expect M3 eng/.aicodepipeline "pipeline -> acp/.aicodepipeline"
expect M3 eng/Workspace "pipeline -> acp/Workspace"
expect M3 eng/src "product -> app/src"
expect M3 eng/tests "product -> app/tests"
expect M3 eng/spec "product -> app/spec"
expect M3 eng/CLAUDE.md "tool-bound -> root"
expect M3 eng/.claude "tool-bound -> root"
expect M3 eng/.gitignore "tool-bound -> root"
expect M3 eng/docs "either -> app/docs (suggested)"
expect M3 eng/README.md "tool-bound -> root"
expect M3 eng/HANDOFF-2026-01-01.md "loose -> acp/Workspace/Sessions/archive/"
# an order-shaped folder inside the product is suggested import (left in app/, acp doctor fails it)
expect M3 eng/docs/old/WO-0050-stray "stray-order -> the work-order or bug folder (suggested)"
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); t={x['path']: x.get('tracked') for x in d['entries']}; sys.exit(0 if t['eng/src']==1 and t['eng/.aicodepipeline']==1 and t['eng/Workspace']==27 else 1)" "$J" \
  || { echo "FAIL M3: the root entries do not record how many of their files git tracks"; exit 1; }
# M4: orders beside the repository. Only there; differing (the file named); identical; contained (an older draft);
# an extra file only outside; the same size with other bytes; a folder that could not be read; two unreadable files
# of the same size; a named pipe; an order copy that is itself a repository. Only identical and contained are dropped.
expect M4 WO-0008-top "outside-order-only -> acp/Workspace/Docs/WorkOrders/WO-0008-top"
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(1 if any(x['path'].startswith('WO-0008-top/') for x in d['entries']) else 0)" "$J" || { echo "FAIL M4: an order folder at the project top has its own files listed as residue"; exit 1; }
expect M4 work/WO-0003-only "outside-order-only -> acp/Workspace/Docs/WorkOrders/WO-0003-only"
expect M4 work/WO-0001-alpha "outside-order-differs -> merged into eng/Workspace/Docs/WorkOrders/WO-0001-alpha"
expect M4 work/WO-0004-delta "outside-order-differs -> merged into eng/Workspace/Docs/WorkOrders/WO-0004-delta"
expect M4 work/WO-0005-eps "outside-order-differs -> merged into eng/Workspace/Docs/WorkOrders/WO-0005-eps"
expect M4 work/WO-0006-zeta "outside-order-differs -> merged into eng/Workspace/Docs/WorkOrders/WO-0006-zeta"
expect M4 work/WO-0007-eta "outside-order-differs -> merged into eng/Workspace/Docs/WorkOrders/WO-0007-eta"
expect M4 work/WO-0010-theta "outside-order-differs -> merged into eng/Workspace/Docs/WorkOrders/WO-0010-theta"
expect M4 work/WO-0011-iota "other-repo -> (owner)"
expect M4 work/WO-0013-kappa "outside-order-differs -> merged into eng/Workspace/Docs/WorkOrders/WO-0013-kappa"
expect M4 work/WO-0014-lambda "outside-order-differs -> merged into eng/Workspace/Docs/WorkOrders/WO-0014-lambda"
expect M4 work/WO-0016-pi "outside-order-differs -> merged into eng/Workspace/Docs/WorkOrders/WO-0016-pi"
expect M4 work/WO-0017-rho "outside-order-differs -> merged into eng/Workspace/Docs/WorkOrders/WO-0017-rho"
expect M4 work/a/b/c/d/e/f/g/WO-0015-deep "outside-order-only -> acp/Workspace/Docs/WorkOrders/WO-0015-deep"
expect M4 work/a/b/c/d/e/f/g/h/deeprepo "other-repo -> (owner)"
expect M4 work/WO-0002-beta "outside-order-identical -> dropped (the repository's copy is byte-identical)"
expect M4 work/close15/BUG-0001-gamma "outside-order-contained -> dropped (the repository's copy holds every file of it, byte-identical)"
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); e={x['path']: x for x in d['entries']}
f=lambda p: [x['file'] for x in e[p]['differences']]
ok = f('work/WO-0001-alpha')==['WO-0001-VERIFICATION.md'] and f('work/WO-0005-eps')==['WO-0005-VERIFICATION.md'] and f('work/WO-0007-eta')==['u.md'] \
  and f('work/WO-0010-theta')==['pipe'] and e['work/WO-0010-theta']['differences'][0]['outside']['what']=='special:fifo' \
  and e['work/WO-0006-zeta'].get('unread')==['outside: locked'] \
  and e['work/WO-0013-kappa'].get('unread')==['outside: tool/.git'] and e['work/WO-0014-lambda'].get('unread')==['outside: .git'] \
  and f('work/WO-0016-pi')==['WO-0016-CLOSEOUT.md'] and e['work/WO-0016-pi']['differences'][0]['outside']['exec'] is True and f('work/WO-0017-rho')==['extra'] \
  and not any(x['path'].startswith('work/a/') and x['kind']=='residue' for x in d['entries'])
# a dropped copy carries the digest of both sides, for apply to re-check before deleting anything
b=e['work/WO-0002-beta'].get('digest', {}); c=e['work/close15/BUG-0001-gamma'].get('digest', {}); k=e['kb-before-1'].get('digest', {})
ok = ok and len(b.get('outside',''))==64 and b.get('outside')==b.get('repository') and len(c.get('outside',''))==64 and len(c.get('repository',''))==64 and c['outside']!=c['repository'] and len(k.get('self',''))==64
sys.exit(0 if ok else 1)" "$J" || { echo "FAIL M4: the differing orders do not name exactly their differing files, the special file, or the folder not read"; exit 1; }
# M5: the rest beside it: residue (logs, patch, notes, a dangling link, a link loop counted as a link, a name with a
# newline); loose documents; a snapshot only when it looks like a knowledge base; a private name before a snapshot
# name; private items; the second ACP copies (one clean, one holding unique work); a repository nested in work/;
# an unknown asked, never guessed
expect M5 work/run1-logs "residue -> acp/Workspace/Testing/logs/work/run1-logs"
[ "$(field work/run1-logs bytes)" = 6 ] || { echo "FAIL M5: work/run1-logs is not counted as its own 4-byte log and 2-byte link: a link was followed"; exit 1; }
expect M5 work/fix.patch "residue -> acp/Workspace/Testing/logs/work/fix.patch"
expect M5 work/close15/notes.txt "residue -> acp/Workspace/Testing/logs/work/close15/notes.txt"
expect M5 work/dangling "residue -> acp/Workspace/Testing/logs/work/dangling"
expect M5 "work/odd
name.txt" "residue -> acp/Workspace/Testing/logs/work/odd
name.txt"
expect M5 work/tools/inner "other-repo -> (owner)"
expect M5 specs "loose -> each order's SPEC (by hand)"
expect M5 handoff "loose -> acp/Workspace/Sessions/archive/"
expect M5 AUDIT-2026-01-02.md "loose -> acp/Workspace/Docs/Audit/"
expect M5 WORK-PLAN-2026-01-03.md "loose -> regenerated (dropped)"
expect M5 FOLLOW-UPS.md "loose -> bugs or orders (by hand)"
expect M5 kb-before-1 "kb-snapshot -> (owner)"   # its file is in no commit, so it is asked about, not dropped
expect M5 kb-notes.md "unknown -> (owner)"
expect M5 kb-locked "unknown -> (owner)"
expect M5 kb-gitted "unknown -> (owner)"
case "$(field kb-locked note) / $(field kb-gitted note)" in "not read to the end: sealed / not read to the end: .git") ;; *) echo "FAIL M5: a snapshot not read whole does not say what was not read"; exit 1;; esac
expect M5 kb-restore "private -> (private folder)"
expect M5 profiles "private -> (private folder)"
expect M5 thing-share "private -> (private folder)"
expect M5 acpclone "second-acp -> removed (suggested)"
expect M5 acp2 "second-acp -> kept beside the project (suggested)"
expect M5 mystery.bin "unknown -> (owner)"
case "$(field acpclone note)" in *"version 1.4.1; nothing unique"*) ;; *) echo "FAIL M5: the clean ACP copy's note does not say nothing is unique, with its version"; exit 1;; esac
n2="$(field acp2 note)"; for want in "1 commit(s) on no remote" "1 stash(es)" "1 ignored file(s)" "1 untracked file(s)"; do
  case "$n2" in *"$want"*) ;; *) echo "FAIL M5: the ACP copy holding unique work does not report: $want ($n2)"; exit 1;; esac; done
# M5b: every entry that needs a decision points to a question that exists; the ones that need none have none
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); n=len(d['questions'])
ask={'either','loose','stray-order','second-acp','other-repo','unknown','outside-order-only','outside-order-differs','residue','private','submodules'}
bad=[e['path'] for e in d['entries'] if (e['kind'] in ask or 'a link leading out' in e['to'] or (e['kind'] == 'kb-snapshot' and e['to'] == '(owner)')) != (isinstance(e.get('question'), int) and 1 <= e['question'] <= n)]
sys.exit(1 if bad else 0)" "$J" || { echo "FAIL M5b: an entry that needs a decision has no question, or one that needs none has one"; exit 1; }
# M6: decisions and blockers
qs="$("$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print('\n'.join(q['question'] for q in d['questions']))" "$J")"
for want in "The repository is \`eng\` inside the project folder." "\`.aicodepipeline/\` is committed (1 files)." "Branch \`merged-one\` is merged into \`main\`. Delete it?" "Branch \`ahead-one\` has 1 commit(s) not in \`main\`."; do
  printf '%s\n' "$qs" | grep -qF -- "$want" || { echo "FAIL M6: the plan does not ask: $want"; exit 1; }
done
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); qs=d['questions']; sys.exit(0 if [q['n'] for q in qs]==list(range(1,len(qs)+1)) and all(q['answer'] is None for q in qs) else 1)" "$J" || { echo "FAIL M6: the questions are not numbered from 1 with no answer"; exit 1; }
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any('no remote' in x for x in d['apply_blockers']) else 1)" "$J" || { echo "FAIL M6: a repository with no remote is not an apply blocker"; exit 1; }
grep -qF "## Questions for the owner" "$P/.acp-migration/MIGRATION-PLAN.md" && grep -qF "the repository has no remote" "$P/.acp-migration/MIGRATION-PLAN.md" || { echo "FAIL M6: MIGRATION-PLAN.md does not show the questions and the blocker"; exit 1; }
# M6b: the plan files have the mode any new file gets here, not a private temporary file's 0600
want="$("$PY" -c 'import os; m = os.umask(0); os.umask(m); print(oct(0o666 & ~m))')"
for f in MIGRATION-PLAN.md moves.json; do got="$("$PY" -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode)))' "$P/.acp-migration/$f")"
  [ "$got" = "$want" ] || { echo "FAIL M6b: $f has mode $got, not $want"; exit 1; }; done
# M7: a second run refuses (its answers would be lost); --replace replaces, removing a temporary file a killed run left
#; still nothing else changes
out="$(cd "$P" && plan 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qF "acp migrate plan: a plan is already in"; } || { echo "FAIL M7: a second plan overwrote the first, or did not say why it refused (exit $rc): $out"; exit 1; }
printf '{"half' > "$P/.acp-migration/.acp-plan-tmp.moves.json.killed01"
printf 'mine\n' > "$P/.acp-migration/.moves.json.bak"; printf 'mine\n' > "$P/.acp-migration/.MIGRATION-PLAN.md.orig"   # a person's files
(cd "$P" && plan --replace >/dev/null 2>&1) || { echo "FAIL M7: --replace did not replace the plan"; exit 1; }
[ ! -e "$P/.acp-migration/.acp-plan-tmp.moves.json.killed01" ] || { echo "FAIL M7: a temporary file a killed run left was not removed"; exit 1; }
{ [ -f "$P/.acp-migration/.moves.json.bak" ] && [ -f "$P/.acp-migration/.MIGRATION-PLAN.md.orig" ] && [ "$(cat "$P/.acp-migration/.moves.json.bak") $(cat "$P/.acp-migration/.MIGRATION-PLAN.md.orig")" = "mine mine" ]; } || { echo "FAIL M7: a person's file in .acp-migration was removed"; exit 1; }
[ "$before" = "$(snap)" ] || { echo "FAIL M7: a second plan changed the project"; exit 1; }
chmod -R u+rwx "$P/work/WO-0006-zeta"; chmod u+r "$R/$W/WO-0007-eta/u.md" "$P/work/WO-0007-eta/u.md"
# M8: a project that is itself the repository, pushed and clean: no inner-repository question, no blocker; the plan's
# own folder is not an uncommitted change on a second run
Q="$EVAL_TMP/solo"; mkdir -p "$Q" && G -C "$Q" init -q && printf 'export WORKORDERS_DIR="Workspace/Docs/WorkOrders"\n' > "$Q/pipeline.config.sh" && mkdir -p "$Q/src" && printf 'a\n' > "$Q/src/a.py" \
  && G -C "$Q" add -A && G -C "$Q" commit -qm s && G init -q --bare "$EVAL_TMP/solo.git" && G -C "$Q" remote add origin "$EVAL_TMP/solo.git" && G -C "$Q" push -q -u origin main 2>/dev/null || { echo "FAIL setup: solo"; exit 1; }
(cd "$Q" && plan >/dev/null 2>&1) && (cd "$Q" && plan --replace >/dev/null 2>&1) || { echo "FAIL M8: plan failed in a project that is its own repository"; exit 1; }
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if not d['apply_blockers'] and not any('inside the project folder' in q['question'] for q in d['questions']) else 1)" "$Q/.acp-migration/moves.json" \
  || { echo "FAIL M8: a clean, pushed project that is its own repository still has blockers or the inner-repository question"; exit 1; }
# M8b: a configured folder that is not a plain path (a variable) refuses the plan with the setting named
V="$EVAL_TMP/varcfg"; mkdir -p "$V/eng" && G -C "$V/eng" init -q && printf 'export WORKORDERS_DIR="$DOCS/WO"\n' > "$V/eng/pipeline.config.sh" && G -C "$V/eng" add -A && G -C "$V/eng" commit -qm v || { echo "FAIL setup: varcfg"; exit 1; }
out="$(cd "$V" && plan 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qxF "acp migrate plan: WORKORDERS_DIR in pipeline.config.sh is not a plain folder inside the repository (a variable, a command, .. or an absolute path); the plan cannot place it" && [ ! -e "$V/.acp-migration" ]; } \
  || { echo "FAIL M8b: a configured folder that is not a plain path did not refuse with its line (exit $rc): $out"; exit 1; }
# M9: refusals, each exit 1 with its line, writing nothing: two candidates; no pipeline; a repository deeper than
# directly inside; an unknown argument; --project with no folder; a project that is not a folder
refused() { # <case> <folder to run in> <expected line> <args...>
  local c="$1" d="$2" want="$3"; shift 3; out="$(cd "$d" && plan "$@" 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qxF -- "$want"; } || { echo "FAIL $c: expected exit 1 and '$want' (exit $rc): $out"; exit 1; }; }
M="$EVAL_TMP/two"; mkdir -p "$M/a" "$M/b"; for x in a b; do G -C "$M/$x" init -q; : > "$M/$x/pipeline.config.sh"; done
RM="$(cd "$M" && pwd -P)"; refused M9 "$M" "acp migrate plan: 2 repositories holding pipeline.config.sh in $RM; name the one to migrate with --repo"
[ ! -e "$M/.acp-migration" ] || { echo "FAIL M9: a refused plan wrote .acp-migration"; exit 1; }
N="$EVAL_TMP/nocfg"; mkdir -p "$N" && G -C "$N" init -q; RN="$(cd "$N" && pwd -P)"
refused M9 "$N" "acp migrate plan: $RN has no pipeline.config.sh (a regular file): there is no pipeline to migrate"
mkdir -p "$M/deep/x" && G -C "$M/deep/x" init -q && : > "$M/deep/x/pipeline.config.sh"
refused M9 "$M" "acp migrate plan: $RM/deep/x is not a repository that is the project folder or directly inside it" --repo "$M/deep/x"
refused M9 "$M" "acp migrate plan: unknown argument --bogus" --bogus
refused M9 "$M" "acp migrate plan: --project needs a folder" --project
refused M9 "$M" "acp migrate plan: $RM/nothing-here is not a folder" --project "$M/nothing-here"
# M10: no plan file is ever written through a link: a linked .acp-migration, or a linked plan file with --replace
L="$EVAL_TMP/linked"; mkdir -p "$L" "$EVAL_TMP/elsewhere" && G -C "$L" init -q && : > "$L/pipeline.config.sh" && ln -s "$EVAL_TMP/elsewhere" "$L/.acp-migration" || { echo "FAIL setup: linked"; exit 1; }
RL="$(cd "$L" && pwd -P)"; refused M10 "$L" "acp migrate plan: $RL/.acp-migration is a link or not a folder; remove it first"
[ -z "$(ls -A "$EVAL_TMP/elsewhere")" ] || { echo "FAIL M10: a linked .acp-migration was written through"; exit 1; }
rm -f "${L:?}/.acp-migration" && (cd "$L" && plan >/dev/null 2>&1) && printf 'keep\n' > "$EVAL_TMP/outside.md" \
  && rm -f "${L:?}/.acp-migration/MIGRATION-PLAN.md" && ln -s "$EVAL_TMP/outside.md" "$L/.acp-migration/MIGRATION-PLAN.md" || { echo "FAIL setup: linked plan file"; exit 1; }
refused M10 "$L" "acp migrate plan: $RL/.acp-migration/MIGRATION-PLAN.md is a link or not a regular file; remove it first" --replace
[ "$(cat "$EVAL_TMP/outside.md")" = keep ] || { echo "FAIL M10: a linked plan file was written through"; exit 1; }
# M11: the plan refuses a Workspace reached through a link, and an orders folder named through .., so an order beside
# the repository is never compared with itself
small() { mkdir -p "$1/eng/src" && G -C "$1/eng" init -q && printf 'x\n' > "$1/eng/src/a.py" && printf '%s\n' "${2:-export WORKORDERS_DIR=\"Workspace/Docs/WorkOrders\"}" > "$1/eng/pipeline.config.sh"; }
commit() { G -C "$1" add -A && G -C "$1" commit -qm "${2:-c}"; }
L1="$EVAL_TMP/linkws"; small "$L1" && order "$L1/shared/Docs/WorkOrders/WO-0001-a" WO-0001 "$PASS" && ln -s ../shared "$L1/eng/Workspace" && commit "$L1/eng" || { echo "FAIL setup: linkws"; exit 1; }
out="$(cd "$L1" && plan 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qxF "acp migrate plan: WORKSPACE_DIR (Workspace) is reached through a link at eng/Workspace or lies outside the repository; the plan cannot tell its orders from copies elsewhere"; } \
  || { echo "FAIL M11: a Workspace reached through a link did not refuse with its line (exit $rc): $out"; exit 1; }
L2="$EVAL_TMP/dotdot"; small "$L2" 'export WORKORDERS_DIR="Workspace/../../orders"' && order "$L2/orders/WO-0001-a" WO-0001 "$PASS" && commit "$L2/eng" || { echo "FAIL setup: dotdot"; exit 1; }
out="$(cd "$L2" && plan 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qF "acp migrate plan: WORKORDERS_DIR in pipeline.config.sh is not a plain folder inside the repository"; } \
  || { echo "FAIL M11: an orders folder named through .. did not refuse (exit $rc): $out"; exit 1; }
# M12: no filter driver runs, in the product repository or a nested one (git status runs a driver's clean or process
# on a file it must look at again)
F1="$EVAL_TMP/filters"; small "$F1" && printf '*.txt filter=v\n' > "$F1/eng/.gitattributes" && printf 'a\n' > "$F1/eng/a.txt" && commit "$F1/eng" \
  && mkdir -p "$F1/work/inner" && G -C "$F1/work/inner" init -q && printf '*.txt filter=w\n' > "$F1/work/inner/.gitattributes" && printf 'b\n' > "$F1/work/inner/b.txt" && commit "$F1/work/inner" || { echo "FAIL setup: filters"; exit 1; }
# a driver whose name holds a dot, and a submodule whose own configuration names a driver (configured below, after
# every commit: git add would run them)
printf '*.md filter=x.y\n' >> "$F1/eng/.gitattributes" && printf 'm\n' > "$F1/eng/m.md" && commit "$F1/eng" dotted || { echo "FAIL setup: dotted"; exit 1; }
SS="$EVAL_TMP/subsrc"; mkdir -p "$SS" && G -C "$SS" init -q && printf '*.txt filter=s\n' > "$SS/.gitattributes" && printf 's\n' > "$SS/s.txt" && commit "$SS" \
  && G -C "$F1/eng" -c protocol.file.allow=always submodule -q add "$SS" sub >/dev/null 2>&1 && commit "$F1/eng" sub \
  && G -C "$F1/work/inner" -c protocol.file.allow=always submodule -q add "$SS" isub >/dev/null 2>&1 && commit "$F1/work/inner" isub || { echo "FAIL setup: submodule"; exit 1; }
G -C "$F1/eng" config filter.v.clean "touch $EVAL_TMP/CLEAN-RAN; cat" && G -C "$F1/eng" config filter.v.process "touch $EVAL_TMP/PROCESS-RAN; false" \
  && G -C "$F1/work/inner" config filter.w.clean "touch $EVAL_TMP/INNER-CLEAN-RAN; cat" || { echo "FAIL setup: filter config"; exit 1; }
"$PY" -c 'import os, sys, time; t = time.time() + 5; [os.utime(p, (t, t)) for p in sys.argv[1:]]' "$F1/eng/a.txt" "$F1/work/inner/b.txt"
G -C "$F1/eng" config filter.x.y.clean "touch $EVAL_TMP/DOTTED-RAN; cat" && G -C "$F1/eng/sub" config filter.s.clean "touch $EVAL_TMP/SUB-CLEAN-RAN; cat" \
  && G -C "$F1/work/inner/isub" config filter.s.clean "touch $EVAL_TMP/INNER-SUB-CLEAN-RAN; cat" || { echo "FAIL setup: filter config 2"; exit 1; }
"$PY" -c 'import os, sys, time; t = time.time() + 5; [os.utime(p, (t, t)) for p in sys.argv[1:]]' "$F1/eng/a.txt" "$F1/eng/m.md" "$F1/eng/sub/s.txt" "$F1/work/inner/b.txt" "$F1/work/inner/isub/s.txt"
(cd "$F1" && plan >/dev/null 2>&1) || { echo "FAIL M12: plan failed with filter drivers configured"; exit 1; }
[ -z "$(ls "$EVAL_TMP" | grep -F RAN)" ] || { echo "FAIL M12: plan ran a filter driver: $(ls "$EVAL_TMP" | grep -F RAN | tr '\n' ' ')"; exit 1; }
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); e={x['path']: x for x in d['entries']}; sys.exit(0 if e.get('eng', {}).get('kind')=='submodules' and 'question' in e['eng'] else 1)" "$F1/.acp-migration/moves.json" \
  || { echo "FAIL M12: a repository with submodules is not asked about (check them by hand)"; exit 1; }
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); e={x['path']: x for x in d['entries']}; sys.exit(0 if 'has submodules: check them by hand' in e['work/inner']['note'] else 1)" "$F1/.acp-migration/moves.json" \
  || { echo "FAIL M12: a nested repository with submodules does not say so"; exit 1; }
# M13: unique work a second copy holds: a commit only a detached HEAD reaches; a merge in progress; a bare repository
# with a branch only there. And the caller's GIT_DIR or GIT_WORK_TREE change nothing.
U="$EVAL_TMP/unique"; small "$U" && commit "$U/eng" || { echo "FAIL setup: unique"; exit 1; }
mkdir -p "$U/work/det" && G -C "$U/work/det" init -q && printf 'a\n' > "$U/work/det/a" && commit "$U/work/det" && G init -q --bare "$EVAL_TMP/det-remote.git" && G -C "$U/work/det" remote add origin "$EVAL_TMP/det-remote.git" \
  && G -C "$U/work/det" push -q -u origin main 2>/dev/null && G -C "$U/work/det" checkout -q --detach && printf 'b\n' > "$U/work/det/b" && commit "$U/work/det" d || { echo "FAIL setup: detached"; exit 1; }   # left detached
mkdir -p "$U/work/mrg" && G -C "$U/work/mrg" init -q && printf 'a\n' > "$U/work/mrg/f" && commit "$U/work/mrg" && G -C "$U/work/mrg" checkout -q -b side && printf 'b\n' > "$U/work/mrg/f" && commit "$U/work/mrg" s \
  && G -C "$U/work/mrg" checkout -q main && printf 'c\n' > "$U/work/mrg/f" && commit "$U/work/mrg" m && { G -C "$U/work/mrg" merge -q side >/dev/null 2>&1; [ -f "$U/work/mrg/.git/MERGE_HEAD" ]; } || { echo "FAIL setup: merge"; exit 1; }
G clone -q --bare "$U/work/det" "$U/work/backup.git" 2>/dev/null && G -C "$U/work/backup.git" branch only-here main && [ -d "$U/work/backup.git/objects" ] || { echo "FAIL setup: bare"; exit 1; }
(cd "$U" && plan >/dev/null 2>&1) || { echo "FAIL M13: plan failed on the unique-work project"; exit 1; }
cp "$U/.acp-migration/moves.json" "$EVAL_TMP/unique-first.json"
"$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); e={x['path']: x for x in d['entries']}
ok = '1 commit(s) on no remote' in e['work/det']['note'] and 'a merge in progress' in e['work/mrg']['note'] and e['work/backup.git']['kind']=='other-repo' and 'a bare repository' in e['work/backup.git']['note']
sys.exit(0 if ok else 1)" "$U/.acp-migration/moves.json" || { echo "FAIL M13: a detached-HEAD commit, a merge in progress or a bare repository is not reported"; exit 1; }
(cd "$U" && GIT_DIR="$U/work/det/.git" GIT_WORK_TREE="$U/work/det" plan --replace >/dev/null 2>&1) || { echo "FAIL M13: plan failed with GIT_DIR set"; exit 1; }
"$PY" -c "import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); sys.exit(0 if a['entries']==b['entries'] and a['questions']==b['questions'] and a['apply_blockers']==b['apply_blockers'] else 1)" "$EVAL_TMP/unique-first.json" "$U/.acp-migration/moves.json" \
  || { echo "FAIL M13: the caller's GIT_DIR and GIT_WORK_TREE changed the plan"; exit 1; }
# M14: what cannot be read or written refuses with its line, never a traceback
C="$EVAL_TMP/perm"; small "$C" && order "$C/eng/Workspace/Docs/WorkOrders/WO-0001-a" WO-0001 "$PASS" && commit "$C/eng" || { echo "FAIL setup: perm"; exit 1; }
RC="$(cd "$C" && pwd -P)"
chmod 311 "$C"; refused M14 "$EVAL_TMP" "acp migrate plan: $RC cannot be read (Permission denied)" --project "$C"; chmod 755 "$C"
chmod 555 "$C"; refused M14 "$EVAL_TMP" "acp migrate plan: $RC/.acp-migration cannot be written (Permission denied)" --project "$C"; chmod 755 "$C"
chmod 311 "$C/eng"; refused M14 "$EVAL_TMP" "acp migrate plan: $RC/eng cannot be read (Permission denied)" --project "$C" --repo "$C/eng"; chmod 755 "$C/eng"
chmod 000 "$C/eng/Workspace/Docs/WorkOrders/WO-0001-a"; refused M14 "$EVAL_TMP" "acp migrate plan: eng/Workspace/Docs/WorkOrders/WO-0001-a cannot be read whole; it could not be compared with copies elsewhere" --project "$C"; chmod 755 "$C/eng/Workspace/Docs/WorkOrders/WO-0001-a"
# M15: names in any locale and any bytes: a Japanese name and a name that is not UTF-8 (made from bytes), under a
# Latin-1 locale where the machine has one (many Linux runners have only C and C.UTF-8), else under C
N="$EVAL_TMP/names"; small "$N" && commit "$N/eng" && order "$N/work/WO-0001-a" WO-0001 "$PASS" && printf 'j\n' > "$N/work/日本.txt" || { echo "FAIL setup: names"; exit 1; }
# a name that is not UTF-8, where the file system allows one (APFS refuses it; ext4 does not)
bad=0; "$PY" -c 'import os, sys; open(os.path.join(os.fsencode(sys.argv[1]), b"bad\xff.txt"), "wb").write(b"x")' "$N/work" 2>/dev/null && bad=1
LAT="$(locale -a 2>/dev/null | grep -iE '\.iso-?8859-?1$' | head -1)"; LAT="${LAT:-C}"
out="$(cd "$N" && LC_ALL="$LAT" LANG="$LAT" plan 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL M15: plan failed on names that are not ASCII, under the locale $LAT (exit $rc): $out"; exit 1; }
{ { [ "$bad" = 0 ] || grep -qF 'work/bad\\xff.txt' "$N/.acp-migration/MIGRATION-PLAN.md"; } && grep -qF 'work/日本.txt' "$N/.acp-migration/MIGRATION-PLAN.md"; } || { echo "FAIL M15: MIGRATION-PLAN.md does not show the non-UTF-8 and Japanese names"; exit 1; }
# M16: git missing, or too old, refuses with its line
mkdir -p "$EVAL_TMP/nogit" "$EVAL_TMP/oldgit"; for t in python3 perl bash env dirname basename readlink sed cat head tr uname; do c="$(command -v $t)" && ln -sf "$c" "$EVAL_TMP/nogit/$t" && ln -sf "$c" "$EVAL_TMP/oldgit/$t"; done
printf '#!/bin/sh\necho "git version 2.10.0"\n' > "$EVAL_TMP/oldgit/git" && chmod +x "$EVAL_TMP/oldgit/git"
out="$(cd "$Q" && PATH="$EVAL_TMP/nogit" "$ACP" migrate plan --replace 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qxF "acp migrate plan: git not found: the plan reads the repository with git"; } || { echo "FAIL M16: no git did not refuse with its line (exit $rc): $out"; exit 1; }
out="$(cd "$Q" && PATH="$EVAL_TMP/oldgit" "$ACP" migrate plan --replace 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qxF "acp migrate plan: git 2.15 or newer is required (found 2.10)"; } || { echo "FAIL M16: an old git did not refuse with its line (exit $rc): $out"; exit 1; }
exit 0
