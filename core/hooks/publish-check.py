#!/usr/bin/env python3
"""
publish-check — what a first push would publish, read before anything is pushed.

A push publishes every commit ever made on every branch it sends, not only today's
files. This reads the whole history of every local branch and tag, and the files a
commit could still add, and reports what should not leave the machine:

  - secrets, personal identifiers and host paths, with bin/sanitize's own rules,
    in every line any commit added, in every commit message, and in the working tree;
  - files that should not be published: logs, archives, patches, scratch and build
    folders, and files over a size limit, anywhere in the history;
  - the author and committer identities in the history that were not confirmed;
  - a second copy of the pipeline inside the repository;
  - branches already merged, or superseded (every commit already on the main branch
    under another id), which should be deleted first;
  - whether a remote exists. Whether it is private cannot be known without asking
    the host, so it is only reported.

It runs git read-only and never writes: no commit, no rewrite, no push, no fetch,
nothing in the repository or its .git folder.

Usage (normally through `acp publish-check`):

  publish-check.py --root <repo> --sanitize <bin/sanitize> [--pipeline-dir <rel>]
                   [--identity <email>]... [--deny <regex>]... [--allow <regex>]...
                   [--max-size <bytes>]

  --identity <email>  an author or committer address that may be published (GitHub
                      noreply addresses always may)
  --deny <regex>      a term that must not be published (a work name, a customer):
                      every match is a critical finding
  --allow <regex>     lines matching it are not read, as with bin/sanitize --allow
  --max-size <bytes>  a file in the history larger than this is reported (default 5 MB)
  --no-ignore         read the paths .sanitize-ignore lists for secrets too

A path a .sanitize-ignore file of the working tree lists is not read for secrets, in the
tree or in the history, as bin/sanitize skips it; the report says how many entries were
skipped, and --no-ignore reads them too. File names, sizes and copies are always checked.

Exit codes: 0 clean, 1 warnings only, 2 one or more critical findings, 3 usage error
or not a git repository.
"""
import argparse, hashlib, importlib.machinery, importlib.util, os, re, subprocess, sys

# Loading bin/sanitize must not leave a __pycache__ beside it, and this must write nothing.
sys.dont_write_bytecode = True

JUNK_SUFFIXES = (".log", ".zip", ".tar", ".tgz", ".gz", ".bz2", ".xz", ".7z", ".rar",
                 ".patch", ".diff", ".orig", ".rej", ".bak", ".tmp", ".swp")
JUNK_NAMES = {".DS_Store", "Thumbs.db"}
JUNK_DIRS = {"scratch", "tmp", "node_modules", "__pycache__", ".venv", "venv", "dist",
             "build", "coverage", ".pytest_cache"}
NOREPLY = "@users.noreply.github.com"
LONG = 8192   # a longer line is not matched (a pattern can take minutes on one), but reported to be read by hand


def load_sanitize(path):
    """bin/sanitize has no .py suffix, so it is loaded by an explicit source loader."""
    loader = importlib.machinery.SourceFileLoader("acp_sanitize", path)
    spec = importlib.util.spec_from_loader("acp_sanitize", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class Git:
    """git, read-only, with the repository's own pager, fsmonitor and diff drivers switched
    off, so reading a repository received from someone else runs none of its programs."""

    def __init__(self, root):
        # Each override names a program a repository's own configuration could otherwise run here:
        # fsmonitor (ls-files), the pager, an external diff, a signature checker (log.showSignature
        # with gpg.program), hooks. Textconv and diff drivers are off by --no-textconv --no-ext-diff.
        self.base = ["git", "-C", root, "-c", "core.fsmonitor=false", "-c", "core.pager=cat",
                     "-c", "core.quotepath=false", "-c", "diff.external=", "-c", "log.showSignature=false",
                     "-c", "core.hooksPath=/dev/null",
                     # ... and each setting that changes what is shown, so nothing is hidden: the root commit's
                     # diff, the identities' encoding, objects replaced by `git replace`.
                     "-c", "log.showRoot=true", "-c", "i18n.logOutputEncoding=UTF-8", "--no-replace-objects",
                     "--no-pager"]
        # No GIT_* variable of the caller's (GIT_DIR, GIT_EXTERNAL_DIFF, GIT_CONFIG_COUNT, ...) reaches git.
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        # info/grafts rewrites parentage as `git replace` does, and is not undone by --no-replace-objects.
        self.env.update(LC_ALL="C", GIT_OPTIONAL_LOCKS="0", GIT_GRAFT_FILE=os.devnull)

    def out(self, *args, check=True):
        r = subprocess.run(self.base + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=self.env)
        if check and r.returncode != 0:
            raise RuntimeError("git %s: %s" % (" ".join(args), r.stderr.decode("utf-8", "replace").strip()))
        return r.stdout.decode("utf-8", "replace"), r.returncode

    def lines(self, *args, check=True):
        return [l for l in self.out(*args, check=check)[0].split("\n") if l]

    def stream(self, *args):
        return subprocess.Popen(self.base + list(args), stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env=self.env)


class Report:
    def __init__(self):
        self.rows = []      # (severity, category, where, what)
        self.info = []

    def add(self, sev, cat, where, what):
        self.rows.append((sev, cat, where, what))

    def note(self, line):
        self.info.append(line)


def ignored(rel, ignores):
    return any(rel == i or rel.startswith(i.rstrip("/") + "/") for i in ignores)


def tree_ignores(root, files):
    """The paths the .sanitize-ignore files a push would carry name, each entry inside its own folder.
    A .sanitize-ignore that is not a regular file is a refusal: what it would skip cannot be known."""
    out = set()
    for rel in sorted(files):
        parts = rel.split("/")
        if ".sanitize-ignore" in parts[:-1] or (parts[-1] == ".sanitize-ignore" and (
                os.path.islink(os.path.join(root, rel)) or not os.path.isfile(os.path.join(root, rel)))):
            raise RuntimeError("%s is a .sanitize-ignore that is not a regular file; refusing" % rel)
        if parts[-1] != ".sanitize-ignore":
            continue
        d = os.path.dirname(rel)
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
            for l in f:
                l = l.strip()
                if not l or l.startswith("#"):
                    continue
                q = os.path.normpath(os.path.join(d, l))
                if q.startswith("..") or os.path.isabs(q) or (d and not (q == d or q.startswith(d + "/"))):
                    continue   # outside its own folder: not honoured
                out.add(q)
    return out


class LineScanner:
    """bin/sanitize's patterns, plus the --deny terms, over single lines; each distinct line
    is matched once, however many commits added it."""

    def __init__(self, S, allow, deny):
        self.S, self.allow, self.deny, self.seen = S, allow, deny, {}

    def scan(self, line):
        key = hashlib.sha1(line.encode("utf-8", "replace")).digest()
        hit = self.seen.get(key)
        if hit is not None:
            return hit
        hit = []
        if not any(a.search(line) for a in self.allow):
            for pid, sev, rx, label in self.S.PATTERNS:
                check = self.S.VALIDATORS.get(pid)
                m = rx.search(line) if check is None else next((x for x in rx.finditer(line) if check(x, line)), None)
                if m is not None:
                    hit.append((sev, pid, label, self.S.truncate(m.group(0))))
            for rx in self.deny:
                m = rx.search(line)
                if m is not None:
                    hit.append(("CRITICAL", "deny", "a term that must not be published", self.S.truncate(m.group(0))))
        self.seen[key] = hit
        return hit


def unquote(p):
    """A path git printed in C-style quotes ("b/a \\"q\\".txt", octal escapes for other bytes)."""
    if len(p) < 2 or p[0] != '"' or p[-1] != '"':
        return p
    s, out, i = p[1:-1], bytearray(), 0
    esc = {"n": 10, "t": 9, "r": 13, "a": 7, "b": 8, "f": 12, "v": 11, '"': 34, "\\": 92}
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n in esc:
                out.append(esc[n]); i += 2; continue
            if re.match(r"[0-7]{3}", s[i + 1:i + 4]):
                out.append(int(s[i + 1:i + 4], 8) & 0xFF); i += 4; continue
        out += s[i].encode("utf-8"); i += 1
    return out.decode("utf-8", "replace")


def scan_history(git, sc, rep, ignores):
    """Every line any commit reachable from any ref added, merges and stashes included (--cc shows
    what a merge changed against all its parents), and every commit message."""
    found = {}   # (sev, pid, path, snippet) -> [oldest commit, commits, label]
    # --text: a -diff or binary attribute, or core.bigFileThreshold, would otherwise print "Binary files
    # differ" for a text file; fixed prefixes, whatever diff.noprefix or diff.srcPrefix say.
    p = git.stream("log", "--all", "-p", "--cc", "--no-ext-diff", "--no-textconv", "--no-color",
                   "--text", "--src-prefix=a/", "--dst-prefix=b/",
                   "--no-renames", "--no-show-signature", "--format=%x01%H%n%B%x02")
    commit, path, state, k = "", "", "none", 1   # state: msg, header (before the first hunk), hunk
    longs = {}   # where -> oldest commit holding a line too long to match
    for raw in p.stdout:
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if line.startswith("\x01"):
            commit, state = line[1:], "msg"
            continue
        if state == "msg":
            if line.endswith("\x02"):
                line, state = line[:-1], "none"
            where = "(commit message)"
        elif line.startswith(("diff --git ", "diff --cc ", "diff --combined ")):
            state, path, k = "header", "", 1
            continue
        elif state == "header":
            if line.startswith("+++ "):
                t = line[4:]
                t = unquote(t[:-1] if t.endswith("\t") else t)   # git ends a name holding a space with a tab
                path = t[2:] if t.startswith("b/") else t
            elif line.startswith("@@"):
                k, state = len(line) - len(line.lstrip("@")) - 1, "hunk"
            continue
        elif state == "hunk":
            if line.startswith("@@"):
                k = len(line) - len(line.lstrip("@")) - 1
                continue
            pre = line[:k]   # one column per parent: a line the commit added has a + and no -
            if "+" not in pre or "-" in pre or "\x00" in line:   # a NUL: a true binary file, under --text
                continue
            line, where = line[k:], path
        else:
            continue
        if where != "(commit message)" and ignored(where, ignores):
            continue
        if len(line) > LONG:
            longs[where] = commit
            continue
        for sev, pid, label, snip in sc.scan(line):
            fk = (sev, pid, where, snip)
            v = found.get(fk)
            if v is None:
                found[fk] = [commit, 1, label]
            else:
                v[0] = commit   # git log runs newest first: the last one seen is the oldest
                v[1] += 1
    p.wait()
    if p.returncode != 0:
        raise RuntimeError("git log failed (exit %d)" % p.returncode)
    for (sev, pid, where, snip), (commit, n, label) in sorted(found.items(), key=lambda x: (x[0][0] != "CRITICAL", x[0][1], x[0][2])):
        times = "" if n == 1 else " (in %d commits)" % n
        rep.add(sev, pid, "history:%s@%s%s" % (where, commit[:7], times), label + (" " + snip if snip else ""))
    for where in sorted(longs):
        rep.add("WARNING", "line.long", "history:%s@%s" % (where, longs[where][:7]),
                "a line longer than %d characters; not read, check it by hand" % LONG)


def scan_tags(git, sc, rep):
    """Annotated tags, nested ones included: a push with --tags publishes their messages and taggers.
    Returns the taggers. A tag that ends at a blob or a tree is a refusal, as such a ref is."""
    names = {}
    for l in git.lines("for-each-ref", "--format=%(objectname) %(objecttype) %(refname)"):
        sha, typ, ref = l.split(" ", 2)
        if typ in ("blob", "tree"):
            raise RuntimeError("%s points at a %s, which this check does not read; refusing" % (ref, typ))
        if typ == "tag":
            names[sha] = ref
    taggers, seen, todo = set(), set(), list(names)
    while todo:
        batch = [s for s in todo if s not in seen]
        todo = []
        if not batch:
            break
        seen.update(batch)
        r = subprocess.run(git.base + ["cat-file", "--batch"], input="\n".join(batch).encode() + b"\n",
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=git.env)
        data, i = r.stdout, 0
        while i < len(data):
            j = data.index(b"\n", i)
            sha, typ, size = data[i:j].decode().split(" ")
            body = data[j + 1:j + 1 + int(size)].decode("utf-8", "replace")
            i = j + 1 + int(size) + 1
            head, _, msg = body.partition("\n\n")
            hdr = dict(h.split(" ", 1) for h in head.split("\n") if " " in h)
            ref = names.get(sha) or "tag " + hdr.get("tag", sha[:7])
            if hdr.get("type") == "tag":
                names.setdefault(hdr["object"], ref)
                todo.append(hdr["object"])
            elif hdr.get("type") in ("blob", "tree"):
                raise RuntimeError("%s ends at a %s, which this check does not read; refusing" % (ref, hdr["type"]))
            m = re.match(r"(.*<[^>]*>)", hdr.get("tagger", ""))
            if m:
                taggers.add(m.group(1))
            where = "history:(tag message %s)@%s" % (hdr.get("tag", "?"), sha[:7])
            hits = set()
            for line in msg.split("\n"):
                line = line.rstrip("\r")
                if len(line) > LONG:
                    rep.add("WARNING", "line.long", where, "a line longer than %d characters; not read, check it by hand" % LONG)
                    continue
                for sev, pid, label, snip in sc.scan(line):
                    if (pid, snip) not in hits:
                        hits.add((pid, snip))
                        rep.add(sev, pid, where, label + (" " + snip if snip else ""))
    return taggers


def publishable(git):
    """What a push would carry from the working tree: tracked files, and files a commit could
    add (untracked and not ignored)."""
    tracked = git.out("ls-files", "-z")[0].split("\0")
    others = git.out("ls-files", "-z", "--others", "--exclude-standard")[0].split("\0")
    return {p for p in tracked + others if p}


def scan_tree(root, files, S, sc, rep, ignores):
    for rel in sorted(files):
        p = os.path.join(root, rel)
        if not os.path.isfile(p) or os.path.islink(p):
            continue
        for rx, label in S.DANGEROUS_FILES:
            if rx.search(rel) and not rel.endswith(".example"):
                rep.add("CRITICAL", "file.dangerous", "tree:" + rel, label)
        if ignored(rel, ignores) or os.path.basename(rel) == ".sanitize-ignore":
            continue
        try:
            with open(p, "rb") as f:   # any file a push could carry, whatever its name, unless it is binary
                if b"\x00" in f.read(4096):
                    continue
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                for n, line in enumerate(f, 1):
                    line = line.rstrip("\r\n")
                    if len(line) > LONG:
                        rep.add("WARNING", "line.long", "tree:%s:%d" % (rel, n), "a line longer than %d characters; not read, check it by hand" % LONG)
                        continue
                    for sev, pid, label, snip in sc.scan(line):
                        rep.add(sev, pid, "tree:%s:%d" % (rel, n), label + (" " + snip if snip else ""))
        except OSError:
            pass


def junk_reason(path):
    base = os.path.basename(path)
    if base in JUNK_NAMES:
        return "a system file"
    low = base.lower()
    for s in JUNK_SUFFIXES:
        if low.endswith(s):
            return "a %s file" % s
    for seg in path.split("/")[:-1]:
        if seg in JUNK_DIRS:
            return "inside a %s/ folder" % seg
    return None


def scan_files(git, rep, paths, max_size, S):
    """Files in the history that should not be published, and dangerous file names. What to
    publish is not a pattern question, so .sanitize-ignore does not apply here."""
    junk = {}
    for p in sorted(paths):
        r = junk_reason(p)
        if r:
            junk.setdefault(r, []).append(p)
        for rx, label in S.DANGEROUS_FILES:
            if rx.search(p) and not p.endswith(".example"):
                rep.add("CRITICAL", "file.dangerous", "history:" + p, label)
    for r in sorted(junk):
        for p in junk[r]:
            rep.add("WARNING", "file.junk", "history:" + p, "should not be published: " + r)
    objs = git.out("rev-list", "--objects", "--all")[0]
    r = subprocess.run(git.base + ["cat-file", "--batch-check=%(objecttype) %(objectsize) %(rest)"],
                       input=objs.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=git.env)
    big = {}
    for l in r.stdout.decode("utf-8", "replace").split("\n"):
        parts = l.split(" ", 2)
        if len(parts) == 3 and parts[0] == "blob" and parts[1].isdigit() and int(parts[1]) > max_size and parts[2]:
            big[parts[2]] = max(big.get(parts[2], 0), int(parts[1]))
    for p in sorted(big):
        rep.add("WARNING", "file.large", "history:" + p, "%d bytes, over the %d-byte limit" % (big[p], max_size))


def scan_acp_copies(rep, paths, pipeline_dir):
    """A folder holding an installed pipeline (bin/wo and core/hooks/check.py) or a pipeline
    source (bin/install.sh and pipeline.config.example.sh), other than this project's own."""
    pset = set(paths)
    dirs = set()
    for p in pset:
        for tail in ("bin/wo", "bin/install.sh"):
            if p == tail or p.endswith("/" + tail):
                dirs.add(p[: len(p) - len(tail)])
    # "." is the repository itself (the pipeline's own source); a relative path is the project's own
    # copy; an absolute one is a pipeline outside the repository, so every copy inside is a second one.
    if pipeline_dir in ("", "."):
        own, ownname = "", "./"
    elif os.path.isabs(pipeline_dir):
        own, ownname = None, "outside this repository, at " + pipeline_dir
    else:
        own = pipeline_dir.strip("/") + "/"
        ownname = own
    for d in sorted(dirs):
        installed = d + "bin/wo" in pset and d + "core/hooks/check.py" in pset
        source = d + "bin/install.sh" in pset and d + "pipeline.config.example.sh" in pset
        if (installed or source) and d != own:
            rep.add("WARNING", "layout.acp-copy", "history:" + (d or "./"),
                    "a second copy of the pipeline (%s); this project's own is %s" % (
                        "a source clone" if source else "an installed copy", ownname))


def scan_branches(git, rep):
    # full ref names in every git argument, so a branch named like an option is still a branch
    full = git.lines("for-each-ref", "--format=%(refname)", "refs/heads/")
    heads = [h[len("refs/heads/"):] for h in full]
    main = next((b for b in ("main", "master") if b in heads), None)
    if main is None:
        cur, rc = git.out("symbolic-ref", "-q", "HEAD", check=False)
        cur = cur.strip()[len("refs/heads/"):] if cur.strip().startswith("refs/heads/") else ""
        main = cur if rc == 0 and cur in heads else None
    if main is None:
        rep.note("branches: no main branch (main, master or the checked-out one); merged branches were not looked for")
        return
    for b in sorted(heads):
        if b == main:
            continue
        if git.out("merge-base", "--is-ancestor", "refs/heads/" + b, "refs/heads/" + main, check=False)[1] == 0:
            rep.add("WARNING", "branch.merged", "branch:" + b, "already merged into %s; delete it before the push" % main)
            continue
        cherry = git.lines("cherry", "refs/heads/" + main, "refs/heads/" + b)
        if cherry and all(l.startswith("-") for l in cherry):
            rep.add("WARNING", "branch.superseded", "branch:" + b,
                    "superseded: its %d commit(s) are already on %s under other ids; delete it before the push" % (len(cherry), main))
        else:
            rep.note("branch %s: %d commit(s) not on %s; merge or delete it before the push, or push it on purpose" % (
                b, sum(1 for l in cherry if l.startswith("+")), main))


def scan_identities(git, rep, allowed, taggers):
    ids = set(git.lines("log", "--all", "--no-show-signature", "--format=%an <%ae>%n%cn <%ce>")) | taggers
    for ident in sorted(ids):
        m = re.search(r"<([^>]*)>$", ident)
        email = (m.group(1) if m else "").lower()
        if email.endswith(NOREPLY) or email in allowed:
            continue
        rep.add("WARNING", "history.identity", "history", "an author, committer or tagger not confirmed for publishing: %s "
                "(confirm it with --identity <email>, or change it before the first push)" % ident)
    return len(ids)


def scan_remotes(git, rep):
    names = git.lines("remote")
    if not names:
        rep.note("remote: none. Create a private repository, add it as a remote, then push (this check creates nothing)")
        return
    for n in names:
        url = git.out("remote", "get-url", n, check=False)[0].strip()
        url = re.sub(r"//[^/]*@", "//", url)   # never print a credential a URL might hold
        rep.note("remote %s (%s): whether it is private cannot be known without asking the host; check it is private before the push" % (n, url))


def main():
    class _AP(argparse.ArgumentParser):
        def error(self, message):
            self.print_usage(sys.stderr); print("publish-check: error: %s" % message, file=sys.stderr); sys.exit(3)
    ap = _AP(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True)
    ap.add_argument("--sanitize", required=True)
    ap.add_argument("--pipeline-dir", default="")
    ap.add_argument("--identity", action="append", default=[])
    ap.add_argument("--deny", action="append", default=[])
    ap.add_argument("--allow", action="append", default=[])
    ap.add_argument("--max-size", type=int, default=5 * 1024 * 1024)
    ap.add_argument("--no-ignore", action="store_true")
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    git = Git(root)
    top, rc = git.out("rev-parse", "--show-toplevel", check=False)
    if rc != 0 or os.path.realpath(top.strip()) != os.path.realpath(root):
        print("publish-check: %s is not the top of a git repository" % root, file=sys.stderr)
        return 3
    try:
        S = load_sanitize(a.sanitize)
        allow = [re.compile(x) for x in a.allow]
        deny = [re.compile(x) for x in a.deny]
    except (OSError, re.error) as e:
        print("publish-check: %s" % e, file=sys.stderr)
        return 3
    allowed = {e.lower() for e in a.identity}
    rep = Report()
    sc = LineScanner(S, allow, deny)
    try:
        files = publishable(git)
        ignores = set() if a.no_ignore else tree_ignores(root, files)
        taggers = scan_tags(git, sc, rep)
        commits = len(git.lines("rev-list", "--all"))
        heads = git.lines("for-each-ref", "--format=%(refname)", "refs/heads/")
        paths = set(git.lines("log", "--all", "--name-only", "--no-renames", "--no-show-signature", "--format=")) if commits else set()
        if commits:
            scan_history(git, sc, rep, ignores)
            scan_files(git, rep, paths, a.max_size, S)
            nids = scan_identities(git, rep, allowed, taggers)
        else:
            nids = 0
        scan_tree(root, files, S, sc, rep, ignores)
        scan_acp_copies(rep, paths | files, a.pipeline_dir)
        if commits:
            scan_branches(git, rep)
        scan_remotes(git, rep)
        gd = git.out("rev-parse", "--git-dir")[0].strip()
        if os.path.exists(os.path.join(root, gd, "shallow")):
            rep.note("this repository is shallow: commits behind its boundary are not here, so they were not read")
        if ignores:
            rep.note("%d path(s) listed in .sanitize-ignore were not read for secrets; --no-ignore reads them too" % len(ignores))
    except RuntimeError as e:
        print("publish-check: %s" % e, file=sys.stderr)
        return 3
    def esc(s):   # a path or name holding a control character stays on one line
        return "".join("\\x%02x" % ord(c) if ord(c) < 32 or ord(c) == 127 else c for c in s)
    print("publish-check: %s" % esc(root))
    print("read: %d commit(s) on %d branch(es), %d identit%s, %d file(s) in the working tree a push could carry" % (
        commits, len(heads), nids, "y" if nids == 1 else "ies", len(files)))
    for sev, cat, where, what in rep.rows:
        print("%s %s %s - %s" % (sev, cat, esc(where), esc(what)))
    for l in rep.info:
        print("info: " + esc(l))
    crit = sum(1 for r in rep.rows if r[0] == "CRITICAL")
    warn = len(rep.rows) - crit
    if crit:
        print("publish-check: %d critical, %d warning(s); do not push until each critical one is removed (and a credential rotated)" % (crit, warn))
        return 2
    if warn:
        print("publish-check: %d warning(s); review each before the first push" % warn)
        return 1
    skipped = " (%d .sanitize-ignore entr%s not read; --no-ignore reads them)" % (
        len(ignores), "y" if len(ignores) == 1 else "ies") if ignores else ""
    print("publish-check: clean; nothing matched bin/sanitize's rules in the history or the working tree%s" % skipped)
    return 0


def guarded():
    """Anything unexpected is exit 3, never 1 or 0: a gate that pushes below 2 must not push on a crash."""
    try:
        return main()
    except SystemExit:
        raise
    except BaseException as e:
        print("publish-check: internal error (%s: %s); the check did not run to the end, so nothing is clean (exit 3)"
              % (type(e).__name__, e), file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(guarded())
