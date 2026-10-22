#!/usr/bin/env python3
"""
evidence-gate — Stop hook. Deterministic checks only, no inference.

1. Any work order or bug folder touched in this working tree that has a
   CLOSEOUT must also have a VERIFICATION document containing an EXECUTED
   status line. A closeout resting on "NOT EXECUTED — PLAN ONLY" is a claim
   without evidence.
2. Modified source files must not contain debug logging.

Advisory in the standard profile. Blocking (exit 2) in strict, or when
ACP_EVIDENCE_GATE=block.
"""
import os, re, subprocess, sys

SRC_EXT = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".py", ".go", ".rb", ".java", ".kt", ".rs", ".php", ".cs", ".swift"}
DEBUG = re.compile(r"\bconsole\.log\s*\(|\bdebugger\b|\bprint\s*\(.*\bDEBUG\b")

def latest_status(path):
    """PASS | FAIL | RUNNING | PLAN | none, read exactly the way the drivers read it.

    The '**Overall status:**' line is the authoritative answer; the run records
    below it are history. A document whose latest run failed still contains the
    word PASS further up, which is why this cannot be a search of the whole text.
    """
    try:
        raw = open(path, "rb").read()
    except OSError:
        return "none"
    # As grep reads it in the drivers: a file holding a NUL is binary and has no status line, an
    # invalid byte is kept as a character rather than dropped, and only "\n" ends a line.
    if b"\0" in raw: return "none"
    text = raw.decode("utf-8", errors="replace")
    m = re.search(r"^\*\*Overall status:\*\*(.*)$", text, re.M)
    if not m: return "none"
    # The status word sits right after the marker. What follows it (the suite path, a note) is never
    # read: a suite named "EXECUTED — PASS.sh" must not make a failing run read as passed.
    # One space after the marker and a spaced dash, exactly as the drivers read it.
    line = m.group(1)
    line = line[1:] if line.startswith(" ") else line
    if line.startswith("RUNNING"): return "RUNNING"
    if re.match(r"EXECUTED [—–-] PASS", line): return "PASS"
    if re.match(r"EXECUTED [—–-] FAIL", line): return "FAIL"
    if re.match(r"NOT EXECUTED [—–-] PRECONDITION", line): return "PRECOND"
    if line.startswith("NOT EXECUTED"): return "PLAN"
    return "none"


def main():
    import hashlib, time; t0 = time.monotonic()   # the Stop hook is killed at 10 s; every git call below fits before 9
    problems, warnings, notes = [], [], []
    # Outside a repository there is nothing to check. Inside one, a git that cannot run, or a status
    # that cannot be read, is a problem with its reason, never a silent pass. git runs in the C locale,
    # so its messages can be read, and inside the Stop hook's 10-second limit.
    genv = dict(os.environ, LC_ALL="C", LANGUAGE="")
    def is_repo(d):   # a .git folder holding HEAD (or one that cannot be read), or a .git file pointing at one
        g = os.path.join(d, ".git")
        if os.path.isdir(g):
            try: return "HEAD" in os.listdir(g)
            except OSError: return True   # there, but closed to the gate: a repository it cannot look into
        try:
            with open(g, "rb") as f: return f.read(8) == b"gitdir: "
        except OSError: return False
    try:
        rp = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=3, env=genv)
        root = rp.stdout.strip() if rp.returncode == 0 else ""
        why = "" if root else ((rp.stderr.strip().splitlines() or ["git rev-parse failed"])[0])
    except Exception as e:
        root, why = "", f"git could not run ({e.__class__.__name__})"
    if not root:   # git found none, or could not say: is this a repository it could not look into?
        try: here = os.getcwd()
        except OSError: return 0   # the folder is gone; there is nothing here to check
        while not is_repo(here) and os.path.dirname(here) != here:
            here = os.path.dirname(here)
        if not is_repo(here): return 0
        problems.append(f"{why}: the closeouts in this repository were not checked")
        root = here
    # -z: each path as it is, NUL-separated (without it git quotes a path holding a space, a non-ASCII
    # letter or a double quote, and that folder was skipped); read as bytes and decoded as file names,
    # so a byte that is not UTF-8 cannot blank the whole list; a rename's or copy's entry is followed
    # by its old path, which is not a change to check.
    z = b""
    if not problems:
        try:
            sp = subprocess.run(["git", "-C", root, "status", "--porcelain", "-z", "-uall"], capture_output=True, timeout=5, env=genv)
            z = sp.stdout
            if sp.returncode != 0:
                problems.append("git status could not be read (" + ((os.fsdecode(sp.stderr).strip().splitlines() or ["exit %d" % sp.returncode])[0]) + "): the closeouts were not checked")
            for w in os.fsdecode(sp.stderr).splitlines():   # a folder git could not open was never listed
                m = re.search(r"could not open directory '(.*)': (.*)", w)
                if m: problems.append(f"git could not open {m.group(1)} ({m.group(2)}): its closeouts were not checked")
        except Exception as e:
            problems.append(f"git status could not be read ({e.__class__.__name__}): the closeouts were not checked")
    changed, skip = [], False
    for e in os.fsdecode(z).split("\0"):
        if skip: skip = False; changed.append(e); continue   # the old path too: its folder may remain
        if len(e) < 4: continue
        if "R" in e[:2] or "C" in e[:2]: skip = True
        changed.append(e[3:])
    changed = [c for c in changed if "/playbooks/" not in f"/{c}"]   # promoted copies are archives, not work in progress
    # a separate repository inside this one (nested, or a submodule) is not seen into from here
    for c in changed:
        if os.path.isdir(os.path.join(root, c)) and is_repo(os.path.join(root, c)):
            notes.append(f"{c}: a separate repository; its work orders outside the configured folders are not checked from here")

    # 1. closeout without executed evidence
    folders = set()
    for c in changed:
        m = re.search(r"(^|/)((WO|BUG)-\d{3,}-[^/]+)(/|$)", c)
        if m:
            folders.add(os.path.join(root, c[: m.end(2)]))
    # The gate also finds the closed orders itself, in the configured folders, as the drivers do (each
    # WO-NNNN-/BUG-NNNN- folder directly inside them): git status does not list an order in an ignored
    # folder, in a nested repository, behind a skip-worktree or assume-unchanged mark or a clean filter, and
    # such an order is checked. An order whose repository last committed exactly the bytes on disk is an old
    # record (D-4, D-10) and is left as it is.
    if not problems:
        rroot = os.path.realpath(root)
        try: here = os.path.realpath(os.getcwd())
        except OSError: here = rroot
        proj = rroot   # the folder holding pipeline.config.sh, found up from here as the drivers find it, never above the repository
        d = here if here == rroot or here.startswith(rroot + os.sep) else rroot
        while True:
            if os.path.isfile(os.path.join(d, "pipeline.config.sh")): proj = d; break
            if d == rroot or os.path.dirname(d) == d: break
            d = os.path.dirname(d)
        cfg = ""
        if os.path.isfile(os.path.join(proj, "pipeline.config.sh")):
            try:
                with open(os.path.join(proj, "pipeline.config.sh"), "rb") as f: cfg = f.read().decode("utf-8", errors="replace")
            except OSError as e:
                problems.append(f"pipeline.config.sh cannot be read ({e.strerror}): the closeouts in its folders were not checked")
        def setting(name, default):   # read as data, never run (D-2): the config's last assignment, else the environment, else the default
            val = None
            for line in cfg.splitlines():
                m = re.match(r"\s*(?:export\s+)?" + name + r"=(.*)$", line)
                if m: val = m.group(1).rstrip("\r")
            if val is None: return os.environ.get(name) or default
            m = re.fullmatch(r"""(?:'([^']*)'|"([^"$`\\]*)"|([^\s"'$`\\;&|<>()]*))(?:\s+#.*|\s*;.*)?\s*""", val)
            if not m: return None   # not a plain path: a variable, a command, an unclosed quote
            return next((g for g in m.groups() if g is not None), "") or None
        bases = []
        for name, default, kind in (("WORKORDERS_DIR", "Workspace/Docs/WorkOrders", "WO"), ("BUGS_DIR", "Workspace/Docs/Bugs", "BUG")):
            v = setting(name, default)
            if v is None:
                notes.append(f"{name} in pipeline.config.sh is not a plain path: the orders in it were checked only as git status lists them"); continue
            base = os.path.normpath(proj + "/" + v)   # as the drivers join it: $PROJECT_ROOT/$WORKORDERS_DIR
            if not os.path.isdir(base): continue
            try: names = sorted(os.listdir(base))
            except OSError as e:
                problems.append(f"{os.path.relpath(base, rroot)}: the folder cannot be read ({e.strerror}); its closeouts were not checked"); continue
            # a linked order folder is followed: its target is what the check reads (S264-2)
            bases += [os.path.join(base, n) for n in names if re.match(kind + r"-\d{3,}-", n) and os.path.isdir(os.path.join(base, n))]
        closed = []
        for d in bases:
            key = os.path.join(root, os.path.relpath(os.path.realpath(d), rroot))
            if key in folders: continue
            try: names = os.listdir(d)
            except OSError: folders.add(key); continue   # the check below reports it cannot be read
            if any("CLOSEOUT" in n.upper() for n in names): closed.append((d, key, names))
        # Which of them git vouches for, each by the repository that holds its folder (this one, or a nested one
        # or a submodule, whose own git knows its old records: S264-3): every entry the check reads is in that
        # repository's last commit with exactly the bytes on disk, hashed here as git hashes a blob, so no index
        # mark, clean filter or fsmonitor answer stands in for the bytes (S264-1). An order no git vouches for
        # (an ignored folder, a folder outside every repository, an entry changed since the commit) is checked.
        class OutOfTime(Exception): pass
        byrepo, unvouched = {}, []
        for d, key, names in closed:
            r = rd = os.path.realpath(d); repo = None
            while r.startswith(rroot + os.sep):
                if is_repo(r): repo = r; break
                r = os.path.dirname(r)
            if repo is None and (rd == rroot or rd.startswith(rroot + os.sep)): repo = rroot
            byrepo.setdefault(repo, []).append((d, key, names))
        for repo, items in sorted(byrepo.items(), key=lambda kv: kv[0] or ""):
            tree, tdirs, ok = {}, set(), repo is not None
            if ok:
                where = "" if repo == rroot else " in " + os.path.relpath(repo, rroot)
                specs = sorted({os.path.relpath(os.path.dirname(os.path.realpath(d)), repo) for d, _, _ in items})
                left = 8.5 - (time.monotonic() - t0)
                try:
                    if left < 0.2: raise subprocess.TimeoutExpired("git", 0)
                    sp = subprocess.run(["git", "--literal-pathspecs", "-C", repo, "ls-tree", "-r", "-z", "-l", "HEAD", "--"] + specs, capture_output=True, timeout=min(1, left), env=genv)
                    err = os.fsdecode(sp.stderr).strip()
                    if sp.returncode != 0 and "Not a valid object name" not in err:   # no commit yet: nothing to vouch with
                        problems.append(f"git ls-tree could not be read{where} (" + ((err.splitlines() or ["exit %d" % sp.returncode])[0]) + "): its closeouts were not checked"); continue
                    for e in os.fsdecode(sp.stdout).split("\0"):
                        meta, tab, p = e.partition("\t")
                        if not tab: continue
                        tree[p] = meta.split()   # mode, type, object id, size (-l pads the size with spaces)
                        while "/" in p: p = p.rsplit("/", 1)[0]; tdirs.add(p)
                except Exception as e:
                    problems.append(f"git ls-tree could not be read{where} ({e.__class__.__name__}): its closeouts were not checked"); continue
            try:
                for d, key, names in items:
                    if time.monotonic() - t0 > 8.5: raise OutOfTime
                    # only the entries the check below reads decide it (a CLOSEOUT, the VERIFICATION document): an
                    # ignored .DS_Store beside them changes nothing the gate would say
                    rd, idm = os.path.realpath(d), re.match(r"(WO|BUG)-\d{3,}", os.path.basename(d))
                    def vouched(n):
                        p = os.path.join(rd, n); rel = os.path.relpath(p, repo)
                        if os.path.isdir(p) and not os.path.islink(p): return rel in tdirs
                        ent = tree.get(rel)
                        if not ent or len(ent) != 4 or ent[1] != "blob": return False
                        try:
                            data = os.fsencode(os.readlink(p)) if os.path.islink(p) else None
                            if data is None and not os.path.isfile(p): return False   # never opened: a pipe or device could hang the hook
                            size = len(data) if data is not None else os.lstat(p).st_size
                            if str(size) != ent[3]: return False   # not the committed blob, decided without reading it (S264-6)
                            h = hashlib.sha1() if len(ent[2]) == 40 else hashlib.sha256()
                            h.update(b"blob %d\0" % size)
                            if data is not None: h.update(data)
                            else:
                                with open(p, "rb") as f:   # in pieces, inside the time limit: a huge file cannot outlast the hook
                                    for chunk in iter(lambda: f.read(1 << 20), b""):
                                        h.update(chunk)
                                        if time.monotonic() - t0 > 8.5: raise OutOfTime
                        except OSError: return False
                        return h.hexdigest() == ent[2]
                    read = [n for n in names if "CLOSEOUT" in n.upper() or n == idm.group(0) + "-VERIFICATION.md"]
                    if not (ok and all(vouched(n) for n in read)): unvouched.append((rd, key, idm.group(0)))
            except OutOfTime:   # fail closed: what was not reached is not passed (S264-6)
                problems.append("the closed orders could not all be checked inside the Stop hook's time limit: the rest were not checked"); break
        # A folder git never listed reaches the check below only from this walk, and that check reads the whole
        # VERIFICATION document: a pipe would wait for ever and a huge file outlast the hook, so neither is read (S264-8)
        for rd, key, oid in unvouched:
            v = os.path.join(rd, oid + "-VERIFICATION.md")
            try: plain = not os.path.lexists(v) or (os.path.isfile(v) and os.path.getsize(v) <= 64 << 20)
            except OSError: plain = False
            if not plain:
                problems.append(f"{os.path.relpath(key, root)}: the VERIFICATION document is not a regular file of at most 64 MB; its closeout was not checked")
            else: folders.add(key)
    for d in sorted(folders):
        if not os.path.isdir(d): continue
        try: names = os.listdir(d)
        except OSError as e:   # a folder the gate cannot read is not one it may pass
            problems.append(f"{os.path.relpath(d, root)}: the folder cannot be read ({e.strerror}); its closeout was not checked"); continue
        has_close = any("CLOSEOUT" in n.upper() for n in names)
        if not has_close: continue
        # Only the document itself, <ID>-VERIFICATION.md, as wo close reads it: a suite's raw
        # *-VERIFICATION-*.log, or any other *VERIFICATION*.md copy, must not count.
        idm = re.match(r"(WO|BUG)-\d{3,}", os.path.basename(d))
        ver = [n for n in names if idm and n == idm.group(0) + "-VERIFICATION.md"]
        if not ver:
            problems.append(f"{os.path.relpath(d, root)}: CLOSEOUT present, no VERIFICATION document"); continue
        # The drivers read one authoritative line and so does this. Searching the
        # whole document for any PASS-or-FAIL accepted a closeout whose latest run
        # had failed, because an older passing run was still in the history.
        rel = os.path.relpath(d, root)
        statuses = [latest_status(os.path.join(d, v)) for v in sorted(ver)]
        st = next((x for x in statuses if x != "none"), "none")
        if st == "PASS":
            pass
        elif st == "FAIL":
            problems.append(f"{rel}: the latest verification run is EXECUTED — FAIL")
        elif st == "RUNNING":
            problems.append(f"{rel}: the last verification never finished; an interrupted run is not a result")
        elif st == "PRECOND":
            problems.append(f"{rel}: the last verification could not run (a precondition failed); nothing was asserted")
        elif st == "PLAN":
            problems.append(f"{rel}: VERIFICATION is NOT EXECUTED — PLAN ONLY")
        else:
            problems.append(f"{rel}: VERIFICATION has no authoritative '**Overall status:**' line")

    # 2. debug logging in modified source
    for c in changed:
        p = os.path.join(root, c)
        if os.path.splitext(c)[1] not in SRC_EXT or not os.path.isfile(p): continue
        if re.search(r"(^|/)(test|tests|__tests__|spec|scripts)/|\.(test|spec)\.", c): continue
        try:
            for n, line in enumerate(open(p, errors="ignore"), 1):
                if DEBUG.search(line) and not line.lstrip().startswith(("//", "#", "*")):
                    warnings.append(f"{c}:{n}: debug logging"); break
        except OSError: pass

    if not problems and not warnings and not notes: return 0
    out = []
    if problems:
        out.append("Evidence gate — a closeout is resting on verification that does not support it:")
        out += [f"  {p}" for p in problems]
        out.append("  Run the tests, record EXECUTED — PASS/FAIL with output, then close.")
    if warnings:
        out.append("Debug logging left in modified source:")
        out += [f"  {w}" for w in warnings[:10]]
    if notes:
        out.append("Not checked from here:")
        out += [f"  {n}" for n in notes]
    print("\n".join(out), file=sys.stderr)
    block = problems and (os.environ.get("ACP_STRICT") == "1" or os.environ.get("ACP_EVIDENCE_GATE") == "block")
    return 2 if block else 0

if __name__ == "__main__": sys.exit(main())
