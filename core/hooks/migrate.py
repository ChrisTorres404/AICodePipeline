#!/usr/bin/env python3
"""
migrate — move a project into the two-folder layout: the product in app/, the pipeline in acp/.

  migrate.py plan [--project <dir>] [--repo <dir>] [--replace]
  migrate.py backup --to <dir> [--project <dir>] [--repo <dir>]
  migrate.py backup --check [--project <dir>]
  migrate.py answer <n> <option> [--project <dir>]
  migrate.py answer <n> --folder <absolute folder outside the project> [--project <dir>]
  migrate.py apply [--project <dir>] [--repo <dir>]

plan reads the project folder and its repository and writes, into <project>/.acp-migration/ and
nowhere else, MIGRATION-PLAN.md (for the owner) and moves.json (for apply): every entry, where it
goes, and every decision the plan cannot make, numbered, with a suggested answer. It moves nothing,
runs git only in ways that write nothing and run nothing (no index refresh, no lock, no fsmonitor
hook), never follows a link, and opens only regular files.

  --project   the project folder (default: the current folder)
  --repo      the repository that holds pipeline.config.sh: the project folder itself or a folder directly
              inside it (default: the project folder if it is one, else the one such folder directly inside)
  --replace   replace a plan already in .acp-migration/ (its recorded answers are lost)

backup writes the whole project folder (.git included, .acp-migration/ left out) as one tar into a folder outside
it, then .acp-migration/manifest.json (every entry: type, mode, size, time, sha256 or link target) and
.acp-migration/backup.json (the archive, its sha256, the repository's HEAD and remote state). The archive is written
under a .partial name, read back and compared with the manifest, compared again with a fresh walk of the project, and
only then renamed; its sha256 file follows, and backup.json, the mark that a backup is whole, is written last. It
refuses, leaving nothing that looks like a backup, when the target is inside the project, when anything in the project
cannot be read or is a special file, when there is no room, and on any write error. --check re-reads a recorded backup
and compares it with backup.json and the manifest.

answer records the owner's answer to one numbered question in .acp-migration/moves.json, and nothing else: only
from the plan written for this project (moves.json and MIGRATION-PLAN.md carry the same plan id, the sha256 of the plan
with its answers left out; moves.json holds MIGRATION-PLAN.md's sha256 and the project it was made in), only one of the
question's options, or, where the plan asks for a folder, an absolute folder outside the project.
plan and answer each hold .acp-migration/'s lock while they read and write it, so two runs at once refuse rather than
lose a write.

apply restructures the repository as one commit: the pipeline into acp/, the product into app/, what tools read at the
root left there. It runs only from an ACP source clone of the project's own version, only for the answered plan written
for this project with a backup that checks whole, and checks everything before it moves anything. Each step is
journalled in .acp-migration/journal.jsonl; a failure before the install puts every step back exactly. From the install
on, a failure stops and names the way back: the backup, restored by hand. The commit holds only
what apply made, and runs without hooks. .acp-migration/applied.json records the run for rollback.

Exit 0 when the plan, the backup or the answer is written (or the backup checks whole), or apply commits; 1 with a
message otherwise.
"""
import base64, ctypes, errno, fcntl, hashlib, importlib.machinery, importlib.util, json, os, re, shlex, shutil, signal, stat, subprocess, sys, tarfile, tempfile
from datetime import date, datetime

sys.dont_write_bytecode = True
PLAN_DIR = ".acp-migration"
PLAN_FILES = ("MIGRATION-PLAN.md", "moves.json")
FOLDER_ANSWER = "<a folder outside the project>"   # the one option that is answered with a folder, not chosen
# the plan's own temporary files, and nothing else, are what a killed run can leave
TMP_PREFIX = ".acp-plan-tmp."
STALE_TMP = re.compile(r"^\.acp-plan-tmp\.(moves\.json|MIGRATION-PLAN\.md)\.[A-Za-z0-9_]{8}$")
ORDER = re.compile(r"^(WO|BUG)-(\d{3,})(-|$)")
# entries tools read from the repository root: moving them breaks the tool, so the owner decides
# root entries that may belong to either side: a question, with the suggested side
EITHER = {"docs": "app", ".sanitize-ignore": "acp"}
# loose work documents by name, and the home the design gives them. At the repository root only files and a
# handoff folder count (a root spec/ or specs/ is the product's tests, an RSpec folder, say).
LOOSE = [
    (re.compile(r"(?i)^handoffs?$|^handoff[-_.]"), "acp/Workspace/Sessions/archive/", True),
    (re.compile(r"(?i)^(audit|journey-map|journeys)([-_.]|$)"), "acp/Workspace/Docs/Audit/", False),
    (re.compile(r"(?i)^specs?$"), "each order's SPEC (by hand)", False),
    (re.compile(r"(?i)^work-plan[-_.]"), "regenerated (dropped)", False),
    (re.compile(r"(?i)^follow-?ups?([-_.]|$)"), "bugs or orders (by hand)", False),
    (re.compile(r"(?i)^tracker$"), "acp/Workspace/Docs/Audit/", False),
]
SNAPSHOT = re.compile(r"(?i)^(kb|knowledge[-_]?base)[-_]")
PRIVATE = re.compile(r"(?i)(^profiles?$|\.setup\.ya?ml$|restore|-share$|\.zip$)")
# git sees none of the caller's GIT_* settings (a GIT_DIR or GIT_WORK_TREE would point every call elsewhere), and
# runs in the C locale with no optional locks, no pager and no prompt
GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
GIT_ENV.update(LC_ALL="C", LANGUAGE="", GIT_OPTIONAL_LOCKS="0", GIT_PAGER="cat", GIT_TERMINAL_PROMPT="0")
# every git call: no index refresh or lock, no fsmonitor hook or untracked cache, no hooks, no signature check (stash
# list reads the log); a scanned repository's
# configuration can neither write nor run anything (its filter drivers are blanked per repository, below)
GIT = ["git", "--no-optional-locks", "-c", "core.fsmonitor=", "-c", "core.untrackedCache=false", "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false",
       "-c", "gc.auto=0", "-c", "maintenance.auto=false"]   # no housekeeping of migrate's own making: it would rewrite .git under its walks
_FILTERS, _GITVER = {}, None


def git_version():
    """(major, minor) of the git on PATH, or None when there is none."""
    global _GITVER
    if _GITVER is None:
        try: out = subprocess.run(["git", "--version"], capture_output=True, timeout=30, env=GIT_ENV).stdout.decode("ascii", "replace")
        except Exception: out = ""
        m = re.search(r"(\d+)\.(\d+)", out)
        _GITVER = (int(m.group(1)), int(m.group(2))) if m else ()
    return _GITVER or None


def no_filters(repo):
    """-c settings that blank every filter driver the repository's configuration names: git status runs a driver's
    clean or process command on a file it has to look at again, and a plan runs nothing. Reading the names runs
    nothing; a configuration that cannot be read refuses the plan."""
    if repo not in _FILTERS:
        try: p = subprocess.run(["git", "-C", repo, "config", "--name-only", "--get-regexp", r"^filter\."], capture_output=True, timeout=30, env=GIT_ENV)
        except Exception as e: raise Refusal(f"the git configuration of {repo} cannot be read ({e.__class__.__name__})")
        if p.returncode not in (0, 1): raise Refusal(f"the git configuration of {repo} cannot be read: " + (os.fsdecode(p.stderr).strip().splitlines() or ["git config failed"])[0])
        opts = []
        # the driver's name is everything between "filter." and the last dot: a name may hold dots itself
        for n in sorted({x[len("filter."):x.rindex(".")] for x in os.fsdecode(p.stdout).split() if x.count(".") >= 2}):
            for k, v in (("clean", ""), ("process", ""), ("smudge", ""), ("required", "false")): opts += ["-c", f"filter.{n}.{k}={v}"]
        _FILTERS[repo] = opts
    return _FILTERS[repo]


def git(repo, *args):
    """(exit code, stdout) of a git command that writes nothing and runs nothing."""
    opts = no_filters(repo)   # a configuration that cannot be read refuses, outside the try below
    try:
        p = subprocess.run(GIT + opts + ["-C", repo] + list(args), capture_output=True, timeout=60, env=GIT_ENV)
        return p.returncode, os.fsdecode(p.stdout)
    except Exception:
        return 127, ""


def is_bare(d):
    """A bare repository: HEAD, objects/ and refs/ in the folder itself."""
    return os.path.isfile(os.path.join(d, "HEAD")) and os.path.isdir(os.path.join(d, "objects")) and os.path.isdir(os.path.join(d, "refs"))


def is_repo(d):
    g = os.path.join(d, ".git")
    if os.path.isdir(g) and not os.path.islink(g): return os.path.isfile(os.path.join(g, "HEAD"))
    try:
        if not stat.S_ISREG(os.lstat(g).st_mode): return is_bare(d)
        with open(g, "rb") as f: return f.read(8) == b"gitdir: "
    except OSError: return is_bare(d)


def read_small(p, limit=1 << 20):
    """The text of a regular file (never a pipe or device, which could hang), at most limit bytes; None otherwise."""
    try:
        if not stat.S_ISREG(os.lstat(p).st_mode): return None
        with open(p, "rb") as f: return f.read(limit).decode("utf-8", errors="replace")
    except OSError: return None


def setting(cfg, name, default):
    """A folder the config names, read as data, never run: the last plain assignment, else the default."""
    val = None
    for line in cfg.splitlines():
        m = re.match(r"\s*(?:export\s+)?" + name + r"=(.*)$", line)
        if m: val = m.group(1).rstrip("\r")
    if val is None: return default
    m = re.fullmatch(r"""(?:'([^']*)'|"([^"$`\\]*)"|([^\s"'$`\\;&|<>()]*))(?:\s+#.*|\s*;.*)?\s*""", val)
    v = next((g for g in m.groups() if g is not None), "") if m else ""
    v = os.path.normpath(v) if v else ""   # normalised first, then judged: Workspace/../../x is ../x
    return v if v and v != "." and not os.path.isabs(v) and v != ".." and not v.startswith(".." + os.sep) else None


def walk_files(top):
    """(every entry under top, folders included, as (relative path, lstat), and what could not be read). Iterative,
    with no depth limit; links are listed, never followed. A .git at any depth is never looked into and
    is listed as not read: what it holds cannot be compared."""
    out, errors, stack = [], [], [top]
    while stack:
        d = stack.pop()
        try: names = sorted(os.listdir(d))
        except OSError: errors.append(os.path.relpath(d, top)); continue
        for n in names:
            p = os.path.join(d, n); rel = os.path.relpath(p, top)
            try: st = os.lstat(p)
            except OSError: errors.append(rel); continue
            if n == ".git": errors.append(rel); continue
            out.append((rel, st))
            if stat.S_ISDIR(st.st_mode): stack.append(p)
    return out, errors


def size_of(p):
    try:
        st = os.lstat(p)
        if not stat.S_ISDIR(st.st_mode): return st.st_size
    except OSError: return 0
    return sum(st.st_size for _, st in walk_files(p)[0] if not stat.S_ISDIR(st.st_mode))


def fingerprint(p, st):
    """What a file is, for comparing two copies. Only a regular file's bytes or a link's target can match; an
    unreadable or special file never equals anything, and is never opened."""
    if stat.S_ISDIR(st.st_mode): return ("dir", None, 0, False)   # an empty folder only one copy has is a difference
    if stat.S_ISLNK(st.st_mode):
        try: return ("link", os.readlink(p), st.st_size, False)
        except OSError: return ("unreadable", None, st.st_size, False)
    if not stat.S_ISREG(st.st_mode):
        kind = "fifo" if stat.S_ISFIFO(st.st_mode) else "socket" if stat.S_ISSOCK(st.st_mode) else "device"
        return ("special:" + kind, None, st.st_size, False)
    h = hashlib.sha256()
    try:
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
    except OSError: return ("unreadable", None, st.st_size, False)
    return ("sha256", h.hexdigest(), st.st_size, bool(st.st_mode & 0o111))   # the exec bit counts


def same(a, b):
    """Two copies of a file are the same only as bytes, or as a link's target; never as unreadable or special."""
    return bool(a and b) and a[0] in ("sha256", "link", "dir") and a == b


def tree_digest(fps, errors):
    """One sha256 over a copy's entries as compared (path, what, value, size, exec bit) and what could not be read: apply
    re-takes it before deleting the copy, so a copy changed since the plan is not deleted."""
    h = hashlib.sha256()
    for rel in sorted(fps): h.update(("%s\0%s\0%s\0%s\0%s\n" % ((rel,) + tuple(fps[rel]))).encode("utf-8", "surrogateescape"))
    for rel in sorted(errors): h.update(("unread\0%s\n" % rel).encode("utf-8", "surrogateescape"))
    return h.hexdigest()


def digest(folder):
    """({relative path: fingerprint} for every file in an order folder, the paths that could not be read)."""
    files, errors = walk_files(folder)
    return {rel: fingerprint(os.path.join(folder, rel), st) for rel, st in files}, errors


def find_under(top, match):
    """Folders under top that match, not inside a repository, not through links. Iterative, with no depth limit."""
    found, stack = [], [top]
    while stack:
        d = stack.pop()
        try: names = os.listdir(d)
        except OSError: continue   # what it holds is decided by its own entry: a folder not read whole is asked
        for name in names:
            p = os.path.join(d, name)
            if os.path.islink(p) or not os.path.isdir(p) or name == ".git": continue
            if match(name, p): found.append(p); continue
            if not is_repo(p): stack.append(p)
    return sorted(found)


def find_orders(top): return find_under(top, lambda n, p: bool(ORDER.match(n)))
def find_splits(top): return find_under(top, lambda n, p: is_order_folder(n, p) or is_repo(p))   # orders and repositories


# Stray material named for an order, in any case (wo-0007-run.log, WO-0007.out, WO-0007-scratch/), filed into the
# order's folder by order_item, or asked about. A bare number counts only when the repository has a work order or a bug
# of that number: below the project's top, 4 to 7 digits then - or . or the end (not a 3-digit name, a YYYYMMDD or
# YYYY-MM date, or a migration such as 0001_x.py); at the top, 4 to 7 digits then -, _ or . (2024-taxes/ is not an
# order's unless WO-2024 or BUG-2024 exists).
ORDER_NAMED = re.compile(r"(?i)^(wo|bug)-(\d{3,})(?=[-_.]|$)")
ORDER_ID = re.compile(r"(?i)(?<![A-Za-z0-9])(wo|bug)-(\d{3,})(?![0-9])")
BARE_NUMBER = re.compile(r"^(?!\d{4}-\d{2}(?:[-_.]|$))(\d{4,7})(?=[-.]|$)")
TOP_NUMBER = re.compile(r"^(?!\d{4}-\d{2}(?:[-_.]|$))(\d{4,7})(?=[-_.])")
NOTE_KIND = ((re.compile(r"(?i)handoff"), "HANDOFF"), (re.compile(r"(?i)draft"), "DRAFT"))
KEY_FILE = re.compile(r"(?i)^(\.env(\..*)?|id_(rsa|dsa|ecdsa|ed25519)(\.pub)?|.*\.(pem|key|p12|pfx))$")
_SECRETS = []


def secret_patterns():
    """bin/sanitize's rules (the one home of them), loaded once, as (line patterns, file-name patterns): every secret.*
    row, and the generic ones (a high-entropy NAME=value, a .secrets folder), since at planning time a false hit only
    becomes a question; and its dangerous file names. None when it cannot be loaded, and then every item the plan would
    file is asked about instead."""
    if not _SECRETS:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin", "sanitize")
        try:
            loader = importlib.machinery.SourceFileLoader("acp_sanitize", path)
            mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("acp_sanitize", loader)); loader.exec_module(mod)
            _SECRETS.append(([rx for pid, sev, rx, label in mod.PATTERNS if pid.startswith("secret.") or pid in ("cfg.entropy", "path.secrets")],
                             [rx for rx, label in mod.DANGEROUS_FILES]))
        except Exception: _SECRETS.append(None)
    return _SECRETS[0]


SCAN_CAP, SCAN_CHUNK, SCAN_KEEP = 50 << 20, 1 << 20, 64 << 10   # bytes: the largest file read, a read, the tail kept across reads
IMAGE = re.compile(r"(?i)\.(png|jpe?g|gif|webp|bmp|ico|tiff?|heic|avif)$")   # pictures are not read for secrets (svg is text, and is)


def secret_in(x, fps):
    """(a file under x, x included, as a path relative to x's parent, and why) when it may be private: named like a key
    file ("key file") or holding a line one of sanitize's rules matches ("secret"), found in any of its files; else the
    file not read for them, the first of the highest rank: "too large" (over 50 MB, and not binary), "unreadable" or
    "no rules" (sanitize's rules missing), then "binary"; None when none is. A file not read never hides a later one:
    every file is looked at, and a binary one never hides one that is asked about.
    A picture is not read (svg is). A file is read in 1 MB pieces, lines carried across a piece and a line without end
    read in overlapping windows, so memory stays bounded. Only names are reported, never content."""
    pats, base = secret_patterns(), os.path.dirname(x)
    rxs, names = pats if pats else (None, [])
    hit = lambda s: any(rx.search(s) for rx in rxs)
    unread = None
    keep = lambda u, c: c if u is None or (u[1] == "binary" and c[1] != "binary") else u   # binary ranks last
    for rel in sorted(fps):
        f = os.path.join(x, rel) if os.path.isdir(x) and not os.path.islink(x) else x
        shown = os.path.relpath(f, base)
        if KEY_FILE.match(os.path.basename(f)) or any(rx.search(shown.replace(os.sep, "/")) for rx in names): return shown, "key file"
        if fps[rel][0] != "sha256" or IMAGE.search(f): continue
        if rxs is None: unread = keep(unread, (shown + " (sanitize's rules could not be loaded)", "no rules")); continue
        try:
            with open(f, "rb") as fh:
                if b"\0" in fh.read(8192): unread = keep(unread, (shown + " (binary, not read)", "binary")); continue
                if fps[rel][2] > SCAN_CAP: unread = keep(unread, (shown + " (not scanned: larger than 50 MB)", "too large")); continue
                fh.seek(0); carry = ""
                while True:
                    chunk = fh.read(SCAN_CHUNK)
                    if not chunk: break
                    lines = (carry + chunk.decode("utf-8", "replace")).split("\n"); carry = lines.pop()
                    if any(hit(s) for s in lines) or hit(carry): return shown, "secret"
                    carry = carry[-SCAN_KEEP:]
        except OSError: unread = keep(unread, (shown + " (could not be read)", "unreadable"))
    return unread


def is_order_folder(name, p):
    """An order folder, not merely a folder named for one: it holds the order's metadata or one of its documents. A
    folder that cannot be listed is taken as one, where a copy not read whole is asked about."""
    m = ORDER.match(name)
    if not m: return False
    try: names = os.listdir(p)
    except OSError: return True
    oid = m.group(1) + "-" + m.group(2)
    return any(n in (".wo-meta", ".bug-meta") or (n.startswith(oid + "-") and n.endswith(".md")) for n in names)


def find_named(top, splits, numbers):
    """Files and folders under top named for an order, or for a bare number, outside the order folders and repositories
    found there; a bare number only when it is in numbers (the repository's order and bug numbers). A match is one whole
    entry, unless an order copy or a repository lies inside it: then it is looked into, as residue_of does, so no two
    entries overlap. Links are entries, never followed."""
    keep, out, stack = set(splits), [], [top]
    while stack:
        d = stack.pop()
        try: names = sorted(os.listdir(d))
        except OSError: continue   # a folder not read is asked about by its own entry
        # a folder mostly of bare numbers (frames/0001.png, ...) is a sequence, not orders' material
        seq = len(names) >= 10 and 2 * sum(1 for n in names if BARE_NUMBER.match(n)) > len(names)
        for n in names:
            p = os.path.join(d, n)
            if p in keep or n == ".git": continue
            real = os.path.isdir(p) and not os.path.islink(p)
            # a private folder, or a knowledge base, is never broken apart: it stays whole and is asked about as such
            if real and (PRIVATE.search(n) or looks_like_kb(p)): continue
            holds = real and any(s.startswith(p + os.sep) for s in splits)
            bare = None if seq else BARE_NUMBER.match(n)
            if (ORDER_NAMED.match(n) or (bare and int(bare.group(1)) in numbers)) and not holds: out.append(p); continue
            if real and not is_repo(p): stack.append(p)
    return sorted(out)


def looks_like_kb(p):
    return os.path.isdir(os.path.join(p, "profiles")) or os.path.isfile(os.path.join(p, "source-index.tsv"))


class Plan:
    def __init__(self, project, repo):
        self.project, self.repo = project, repo
        self.entries, self.questions, self.blockers = [], [], []
        self.suggestion_problems, self.gitignore_add = [], None

    def rel(self, p): return os.path.relpath(p, self.project)

    def entry(self, path, kind, dest, note="", question=None):
        e = {"path": self.rel(path), "kind": kind, "to": dest, "bytes": size_of(path), "note": note}
        if question is not None: e["question"] = question
        self.entries.append(e)
        return e

    def ask(self, text, options, suggested, about=None):
        q = {"n": len(self.questions) + 1, "question": text, "options": options, "suggested": suggested, "answer": None}
        if about: q["about"] = about
        self.questions.append(q)
        return q["n"]


def loose_home(name, at_root, is_dir):
    for rx, home, root_dir_ok in LOOSE:
        if rx.search(name) and (not at_root or not is_dir or root_dir_ok): return home
    return None


_LAYOUT = []


def root_names(repo):
    """What stays at the repository root, from layout.py (the one home of that list): its names, its prefixes, and
    the project's own LAYOUT_ROOT_EXTRA. A layout.py that cannot be loaded, or a config it cannot read, refuses."""
    if not _LAYOUT:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "layout.py")
        try:
            loader = importlib.machinery.SourceFileLoader("acp_layout", path)
            mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("acp_layout", loader)); loader.exec_module(mod)
            _LAYOUT.append(mod)
        except Exception as e: raise Refusal(f"layout.py cannot be loaded ({e.__class__.__name__}); the plan does not know what stays at the root")
    mod = _LAYOUT[0]
    try: extra = mod.config(repo)["LAYOUT_ROOT_EXTRA"]
    except mod.NoLayout as e: raise Refusal(str(e))
    return set(mod.ROOT_WIRING) | set(extra), tuple(mod.ROOT_PREFIXES)


def plan_repo(pl, cfg):
    """The repository's root entries. Precedence, first match wins: what tools read at the root (it stays there,
    unasked, unless it is a link leading out), pipeline, either side, a loose document (files, and a handoff folder),
    else product."""
    r = pl.repo
    pr = setting(cfg, "PIPELINE_ROOT", ".aicodepipeline")
    ws = setting(cfg, "WORKSPACE_DIR", "Workspace")
    wod = setting(cfg, "WORKORDERS_DIR", "Workspace/Docs/WorkOrders")
    bgd = setting(cfg, "BUGS_DIR", "Workspace/Docs/Bugs")
    for name, val in (("PIPELINE_ROOT", pr), ("WORKSPACE_DIR", ws), ("WORKORDERS_DIR", wod), ("BUGS_DIR", bgd)):
        if val is None: raise Refusal(f"{name} in pipeline.config.sh is not a plain folder inside the repository (a variable, a command, .. or an absolute path); the plan cannot place it")
    names, prefixes = root_names(r)   # after the plan's own checks, so their lines are the ones shown
    pipeline_top = {"pipeline.config.sh", "playbooks"} | {v.split(os.sep)[0] for v in (pr, ws) if v}
    rc, out = git(r, "ls-files", "-z")   # how much of each root entry git tracks: apply moves that part with git mv
    tracked = {}
    for f in (out.split("\0") if rc == 0 else []):
        if f: tracked[f.split("/")[0]] = tracked.get(f.split("/")[0], 0) + 1
    first = len(pl.entries)
    for name in listing(r):
        p = os.path.join(r, name)
        if name in (".git", PLAN_DIR): continue
        home = loose_home(name, True, os.path.isdir(p) and not os.path.islink(p))
        if name in names or name.startswith(prefixes):
            if os.path.islink(p) and not within(p, r):
                n = pl.ask(f"`{pl.rel(p)}` is read by tools at the repository root, but it is a link leading out of the repository. Keep it at the root as it is, or stop the migration and fix it by hand?",
                           ["root", "stop the migration"], "stop the migration", pl.rel(p))
                pl.entry(p, "tool-bound", "root (asked: a link leading out)", question=n)
            else:
                pl.entry(p, "tool-bound", "root")
        elif name in pipeline_top:
            pl.entry(p, "pipeline", "acp/" + name)
        elif name in EITHER:
            side = EITHER[name]
            n = pl.ask(f"`{pl.rel(p)}` could belong to the product or to the pipeline. Which side?", ["app", "acp"], side, pl.rel(p))
            pl.entry(p, "either", side + "/" + name + " (suggested)", question=n)
        elif home:
            loose(pl, p, home)
        else:
            pl.entry(p, "product", "app/" + name)
    for e in pl.entries[first:]: e["tracked"] = tracked.get(os.path.basename(e["path"]), 0)
    # the pipeline's folders are real folders under the repository, reached through no link: otherwise an order beside
    # the repository could be compared with itself, so the plan refuses
    rr = os.path.realpath(r)
    for name, base in (("PIPELINE_ROOT", pr), ("WORKSPACE_DIR", ws), ("WORKORDERS_DIR", wod), ("BUGS_DIR", bgd)):
        cur, linked = r, None
        for part in base.split(os.sep):
            cur = os.path.join(cur, part)
            if os.path.islink(cur): linked = cur; break
        if linked or (os.path.lexists(os.path.join(r, base)) and not os.path.realpath(os.path.join(r, base)).startswith(rr + os.sep)):
            raise Refusal(f"{name} ({base}) is reached through a link{' at ' + pl.rel(linked) if linked else ''} or lies outside the repository; the plan cannot tell its orders from copies elsewhere")
    inside = {}
    for base in (wod, bgd):
        if not os.path.lexists(os.path.join(r, base)): continue
        for n in listing(os.path.join(r, base)):
            m, q = ORDER.match(n), os.path.join(r, base, n)
            if not (m and os.path.isdir(q) and not os.path.islink(q)): continue
            if walk_files(q)[1]: raise Refusal(f"{pl.rel(q)} cannot be read whole; it could not be compared with copies elsewhere")
            inside.setdefault(m.group(1) + "-" + m.group(2), []).append(q)
    skip = {os.path.join(r, x) for x in (".git", pr, ws) if x}
    for p in find_orders(r):
        if any(p == s or p.startswith(s + os.sep) for s in skip): continue
        # importing it is the suggestion: left with the product it sits in app/, where acp doctor fails it (a work order
        # inside the code folder); app stays the answer for product content shaped like an order, a test fixture say
        n = pl.ask(f"`{pl.rel(p)}` is shaped like an order folder, inside the repository but outside the configured folders. Bring it into the work-order or bug folder, or leave it with the product (app: acp doctor then names it as a work order inside the code folder, so only for product content such as a test fixture)?",
                   ["import", "app"], "import", pl.rel(p))
        pl.entry(p, "stray-order", "the work-order or bug folder (suggested)", question=n)
    if has_submodules(r):
        n = pl.ask(f"`{pl.rel(r)}` has submodules: check them by hand. The plan does not look inside them, and apply moves them as they are. Agree?", ["yes", "stop the migration"], "stop the migration", pl.rel(r))
        pl.entry(r, "submodules", "(owner)", note="has submodules: check them by hand", question=n)
    if pr:
        rc, out = git(r, "ls-files", "-z", "--", pr)
        count = len([x for x in out.split("\0") if x]) if rc == 0 else 0
        if count:
            pl.ask(f"`{pr}/` is committed ({count} files). Keep it committed under acp/ (teammates get identical tools in one clone), or install it from a pinned ACP release instead?",
                   ["commit", "pinned"], "commit")
    return inside, wod, bgd


def listing(d):
    """The sorted names in a folder; a folder that cannot be read stops the plan with its reason, never a traceback."""
    try: return sorted(os.listdir(d))
    except OSError as e: raise Refusal(f"{d} cannot be read ({e.strerror})")


class Refusal(Exception):
    """A plan that cannot be made: the reason, for the person."""


def loose(pl, p, home):
    # yes is offered only for a home apply can file into (a folder under acp/); a home that is a person's work
    # ("by hand") or no folder at all ("dropped") is kept or deleted, and keeping it is the suggestion
    if home.startswith("acp/"):
        n = pl.ask(f"`{pl.rel(p)}` is a loose work document. The plan proposes: {home}. Agree?", ["yes", "delete", "keep where it is"], "yes", pl.rel(p))
    else:
        n = pl.ask(f"`{pl.rel(p)}` is a loose work document. Its place is {home}, which apply does not do: keep it where it is, or delete it?",
                   ["keep where it is", "delete"], "keep where it is", pl.rel(p))
    e = pl.entry(p, "loose", home, question=n)
    e["digest"] = {"self": self_digest(p)}   # apply re-takes it before it moves or deletes the document


def self_digest(p):
    """The digest of one entry as the plan saw it, a folder or a single file, which apply re-takes before it acts."""
    if os.path.isdir(p) and not os.path.islink(p): return tree_digest(*digest(p))
    return tree_digest({os.path.basename(p): fingerprint(p, os.lstat(p))}, [])


def reachable_blobs(repo):
    """Every blob reachable from a ref of the repository, read once (git rev-list --objects --all): a dangling blob,
    which git gc may prune, is not in it."""
    rc, out = git(repo, "rev-list", "--objects", "--all")
    if rc != 0: raise Refusal("the repository's history cannot be listed (git rev-list --objects --all)")
    return {x.split(" ", 1)[0] for x in out.splitlines() if x}


def in_history(repo, folder, blobs):
    """True when the content of every file under folder is a blob in blobs: dropping the folder loses nothing git
    does not hold. A link, a special file, a folder not read whole or a name git cannot be given on a line is not."""
    files, errors = walk_files(folder)
    if errors: return False
    paths = []
    for rel, st in files:
        if stat.S_ISDIR(st.st_mode): continue
        if not stat.S_ISREG(st.st_mode) or "\n" in rel or "\r" in rel: return False
        paths.append(os.path.join(folder, rel))
    if not paths: return True
    rc, out = git_in(repo, ("\n".join(paths) + "\n").encode("utf-8", "surrogateescape"), "hash-object", "--no-filters", "--stdin-paths")
    shas = out.split()
    return rc == 0 and len(shas) == len(paths) and all(x in blobs for x in shas)


def plan_outside(pl, inside, wod, bgd):
    """Everything beside the repository. Precedence, first match wins: a repository (a second ACP copy, or
    another); an order folder, or a folder holding orders or repositories (each one its own entry, the rest
    residue); a private item; a knowledge-base snapshot (only a folder that looks like one); a loose document;
    else unknown (asked, never guessed)."""
    if pl.repo == pl.project: return
    residue, private, held, homes, blobs = [], [], 0, {}, []
    numbers = {int(k.split("-")[1]) for k in inside}   # a bare number counts only when it is one of these
    # Every order item is planned after every copy of every order in every top-level folder, so what a copy carries in
    # is known before a stray is given a place; placeholders, folders and files alike, are numbered last of all.
    items, placeholders, deferred = [], [], []
    for name in listing(pl.project):
        p = os.path.join(pl.project, name)
        if p == pl.repo or name == PLAN_DIR: continue
        real_dir = os.path.isdir(p) and not os.path.islink(p)
        if real_dir and is_repo(p): nested_repo(pl, p); continue
        splits = [p] if real_dir and is_order_folder(name, p) else (find_splits(p) if real_dir else [])
        top_num = TOP_NUMBER.match(name)
        top_named = bool(ORDER_NAMED.match(name)) or bool(top_num and any(int(k.split("-")[1]) == int(top_num.group(1)) for k in inside))
        # a folder holding stray material of orders is worked like one holding orders, unless it is private, a
        # knowledge-base snapshot, a loose home or itself named for an order (filed whole)
        named = (find_named(p, splits, numbers) if splits != [p] else []) if real_dir and not top_named and not PRIVATE.search(name) \
                and not (SNAPSHOT.search(name) and looks_like_kb(p)) and not loose_home(name, False, True) else []
        if splits or named:
            for s in splits:
                # an order folder that is itself a repository keeps a history the repository's copy lacks
                om = ORDER.match(os.path.basename(s))
                if om and not is_repo(s) and int(om.group(2)) == 0: placeholders.append(s)   # a placeholder number: numbered last
                elif om and not is_repo(s): outside_order(pl, s, inside, wod, bgd)
                else: nested_repo(pl, s)
            for x in sorted(residue_of(p, splits + named) + named):
                if os.path.basename(x) == ".git" or (os.path.isdir(x) and not os.path.islink(x) and walk_files(x)[1]):
                    n = pl.ask(f"`{pl.rel(x)}` could not be read to the end, so what it holds is not known. Where does it go?", ["app", "acp", "private folder", "delete"], "private folder", pl.rel(x))
                    pl.entry(x, "unknown", "(owner)", note="not read to the end: " + ", ".join(walk_files(x)[1][:5]), question=n)
                elif found := private_in(x):   # never filed with the logs inside the project: asked, never dropped
                    held += 1
                    n = pl.ask(f"`{pl.rel(x)}` lies beside the work orders and holds what looks private or like a knowledge base ({len(found)} found: {', '.join(found[:5])}{', ...' if len(found) > 5 else ''}). Move it to the private folder, keep it with the logs under acp/Workspace/Testing/logs/, or delete it?",
                               ["private folder", "logs", "delete"], "private folder", pl.rel(x))
                    pl.entry(x, "private-residue", "(private folder) (suggested)", note=f"{len(found)} found: " + ", ".join(found[:5]) + (", ..." if len(found) > 5 else ""), question=n)
                elif x in named: items.append(x)
                elif (s2 := secret_in(x, digest(x)[0] if os.path.isdir(x) and not os.path.islink(x) else {os.path.basename(x): fingerprint(x, os.lstat(x))})) and s2[1] != "binary":
                    # a key file, a line sanitize's rules match, or a file too large (or unreadable) to read for them:
                    # never filed with the logs without a question; a binary file is not read, and stays residue
                    held += 1
                    n = pl.ask(f"`{pl.rel(x)}` lies beside the work orders and may hold something private ({s2[0]}). Move it to the private folder, keep it with the logs under acp/Workspace/Testing/logs/, or delete it?",
                               ["private folder", "logs", "delete"], "private folder", pl.rel(x))
                    pl.entry(x, "private-residue", "(private folder) (suggested)", note="may hold something private: " + s2[0], question=n)
                else: residue.append(x)
        elif top_named and not private_in(p):
            items.append(p)
        elif PRIVATE.search(name):
            private.append(p)
        elif real_dir and SNAPSHOT.search(name) and looks_like_kb(p):
            fps, unread = digest(p)
            if unread:   # dropped only when read whole
                n = pl.ask(f"`{pl.rel(p)}` looks like a knowledge-base snapshot but could not be read to the end, so what it holds is not known. Where does it go?", ["app", "acp", "private folder", "delete"], "private folder", pl.rel(p))
                pl.entry(p, "unknown", "(owner)", note="not read to the end: " + ", ".join(unread[:5]), question=n)
            else:
                if not blobs: blobs.append(reachable_blobs(pl.repo))   # read once, only when a snapshot is found
                if in_history(pl.repo, p, blobs[0]):
                    e = pl.entry(p, "kb-snapshot", "dropped", note="every file is in the repository's history")
                else:   # something in it git does not hold: asked, never dropped unasked
                    n = pl.ask(f"`{pl.rel(p)}` looks like a knowledge-base snapshot, but some of its files are not in the repository's history. Keep it with the logs under acp/Workspace/Testing/logs/, move it to the private folder, or delete it?",
                               ["logs", "private folder", "delete"], "logs", pl.rel(p))
                    e = pl.entry(p, "kb-snapshot", "(owner)", note="not every file is in the repository's history", question=n)
                e["digest"] = {"self": tree_digest(fps, unread)}
        elif loose_home(name, False, real_dir):
            loose(pl, p, loose_home(name, False, real_dir))
        else:
            n = pl.ask(f"`{pl.rel(p)}` is not something the plan recognises. Where does it go?", ["app", "acp", "private folder", "delete"], "private folder", pl.rel(p))
            pl.entry(p, "unknown", "(owner)", question=n)
    for x in items: order_item(pl, x, inside, homes, deferred)
    for s in placeholders: outside_order(pl, s, inside, wod, bgd)
    for x in deferred: order_item(pl, x, inside, homes)
    if residue:
        n = pl.ask(f"{len(residue)} logs, scratch and other files beside the work orders ({sum(size_of(x) for x in residue)} bytes). Keep them under acp/Workspace/Testing/logs/ (ignored by git), or delete them?",
                   ["keep", "delete"], "keep")
        for x in residue: pl.entry(x, "residue", "acp/Workspace/Testing/logs/" + pl.rel(x), question=n)
    # the one folder every private item, and every item answered "private folder", moves to: asked whenever any question offers it
    if private or held or any("private folder" in q["options"] for q in pl.questions):
        n = pl.ask(f"{len(private)} private items (profiles, restore notes, shared install files) leave the project. Name the private folder outside the project they move to." if private
                   else "Name the private folder outside the project that the items answered \"private folder\" move to.",
                   [FOLDER_ANSWER], None)
        for x in private: pl.entry(x, "private", "(private folder)", question=n)
    for e in pl.entries:   # every entry beside the repository carries what apply re-takes before it acts on it
        if "digest" not in e and os.path.relpath(os.path.join(pl.project, e["path"]), pl.repo).startswith(".." + os.sep):
            e["digest"] = {"self": self_digest(os.path.join(pl.project, e["path"]))}


def private_in(x):
    """What under x (x included) looks private or like a knowledge base, by name or by shape, as paths relative to x's
    parent; links are never followed. The most telling come first, so a knowledge base never hides behind zips:
    knowledge-base folders, then profiles, setup files and restore notes, then the rest. A folder that cannot be read
    is already asked about, never here."""
    base, found = os.path.dirname(x), []
    def look(p):
        n = os.path.basename(p)
        if os.path.isdir(p) and not os.path.islink(p) and looks_like_kb(p): rank = 0
        elif PRIVATE.search(n): rank = 1 if re.search(r"(?i)^profiles?$|\.setup\.ya?ml$|restore", n) else 2
        else: return
        found.append((rank, os.path.relpath(p, base)))
    look(x)
    if os.path.isdir(x) and not os.path.islink(x):
        for d, dirs, files in os.walk(x):
            for n in sorted(dirs) + sorted(files): look(os.path.join(d, n))
    return [r for _, r in sorted(found)]


def order_item(pl, x, inside, homes, deferred=None):
    """One thing beside the repository named for an order, or for a bare number. Filed into that order's folder in the
    repository: a note (.md) as <ID>-<KIND>-<n>.md, anything else under artifacts/ with its path relative to the
    project; dropped when the order's folder already holds it byte for byte (never an empty file); asked, never
    guessed, when it may be private (a key file, or a line sanitize's secret patterns match), when its place in the
    folder is taken (by a document of the order, or by an earlier item), when the number is a placeholder, the
    repository has no such order, two orders are named, or the name has no WO- or BUG-. Every entry carries its digest,
    which apply re-takes before it acts."""
    name, folder = os.path.basename(x), os.path.isdir(x) and not os.path.islink(x)
    fps, unread = digest(x) if folder else ({name: fingerprint(x, os.lstat(x))}, [])
    if unread:   # a folder not read whole may hold anything: asked, as elsewhere
        n = pl.ask(f"`{pl.rel(x)}` could not be read to the end, so what it holds is not known. Where does it go?", ["app", "acp", "private folder", "delete"], "private folder", pl.rel(x))
        pl.entry(x, "unknown", "(owner)", note="not read to the end: " + ", ".join(unread[:5]), question=n)
        return
    found = secret_in(x, fps)   # looked for first, whatever the item turns out to be
    why = f" It may hold something private ({found[0]})." if found else ""
    ask = lambda kind, text, options, suggested: pl.entry(x, kind, "(owner)", question=pl.ask(text + why, options, "private folder" if found else suggested, pl.rel(x)))
    ids = sorted({f"{a.upper()}-{b}" for a, b in ORDER_ID.findall(name)}, key=lambda s: (s.split("-")[0], int(s.split("-")[1])))
    m = ORDER_NAMED.match(name)
    def has(prefix, num): return next((k for k in sorted(inside) if k.split("-")[0] == prefix and int(k.split("-")[1]) == num), None)
    if not m:
        num = (BARE_NUMBER.match(name) or TOP_NUMBER.match(name)).group(1)
        e = ask("order-ambiguous", f"`{pl.rel(x)}` is named for the number {num}, with no WO- or BUG-, so whose it is is not known. File it with work order {num}, with bug {num}, keep it with the logs, move it to the private folder, or delete it?",
                ["work order", "bug", "logs", "private folder", "delete"], "logs")
        e["number"] = num
        e["homes"] = {k: os.path.relpath(inside[k][0], pl.repo) for k in (has("WO", int(num)), has("BUG", int(num))) if k}
    elif len({(i.split("-")[0], int(i.split("-")[1])) for i in ids}) > 1:   # two orders named: whose it is is not known
        e = ask("order-ambiguous", f"`{pl.rel(x)}` names {' and '.join(ids)}. File it with one of them, keep it with the logs, move it to the private folder, or delete it?",
                ids + ["logs", "private folder", "delete"], "logs")
        e["homes"] = {i: os.path.relpath(inside[k][0], pl.repo) for i in ids for k in [has(i.split("-")[0], int(i.split("-")[1]))] if k}
    else:
        prefix, num = m.group(1).upper(), int(m.group(2))
        oid = has(prefix, num)
        if num == 0 and deferred is not None:   # numbered once every order this plan imports is known
            deferred.append(x); return
        if num == 0:   # a placeholder: the next number after every one the repository and this plan use or import
            new = placeholder_number(pl, inside, prefix)
            e = ask("order-placeholder", f"`{pl.rel(x)}` carries the placeholder number {prefix}-{m.group(2)}. Adopt it as {new}, keep it with the logs, move it to the private folder, or delete it?",
                    [f"adopt as {new}", "logs", "private folder", "delete"], "logs")
            e["adopt_as"] = new
        elif oid is None:
            e = ask("order-missing", f"`{pl.rel(x)}` is named for {prefix}-{m.group(2)}, which the repository does not have. Keep it with the logs, move it to the private folder, or delete it?",
                    ["logs", "private folder", "delete"], "logs")
        elif found:
            e = ask("order-private", f"`{pl.rel(x)}` is named for {oid}. Move it to the private folder, file it under the order's artifacts/ (ignored by git), or delete it?",
                    ["private folder", "artifacts", "delete"], "private folder")
            e["id"], e["file_as"], e["home"] = oid, os.path.join("artifacts", pl.rel(x)), os.path.relpath(inside[oid][0], pl.repo)
        else:
            home = inside[oid][0]
            if home not in homes: homes[home] = digest(home)[0]
            mine = None if folder else fps[name]
            # compared without case, as a case-insensitive disk would; a folder the order already has may hold more
            have = {f.lower() for f in homes[home]}; files = {f.lower() for f, v in homes[home].items() if v[0] != "dir"}
            planned = {e2["file_as"].lower() for e2 in pl.entries if e2.get("id") == oid and "file_as" in e2}
            # and what a copy outside that differs carries in: every file only it has (D1)
            planned |= {d2["file"].lower() for e2 in pl.entries if e2.get("id") == oid and e2["kind"] == "outside-order-differs"
                        for d2 in e2.get("differences", []) if d2.get("outside") and not d2.get("repository")}
            twin = next((f for f, v in sorted(homes[home].items()) if mine and mine[0] == "sha256" and mine[2] > 0 and same(mine, v)), None)
            if not folder and name.lower().endswith(".md"):
                kind = next((k for rx, k in NOTE_KIND if rx.search(name)), "NOTES")
                i = 1
                while f"{oid}-{kind}-{i}.md".lower() in have | planned: i += 1
                fa = f"{oid}-{kind}-{i}.md"
            else:
                fa = os.path.join("artifacts", pl.rel(x))
            # taken: a document of the order with this name, the same path, a file where a folder would go, or something
            # already under the path it would take
            f_ = fa.lower()
            clash = (name.lower() in files and not twin) or f_ in have | planned or any(f_.startswith(h + "/") for h in files | planned) \
                    or any(h.startswith(f_ + "/") for h in have | planned)
            if twin:
                e = pl.entry(x, "order-duplicate", f"dropped ({pl.rel(os.path.join(home, twin))} holds it, byte-identical)")
                e["same_as"] = pl.rel(os.path.join(home, twin))
            elif clash:
                e = ask("order-clash", f"`{pl.rel(x)}` would be filed in {oid}'s folder where something of the same name is already, or will be. Keep it with the logs, move it to the private folder, or delete it?",
                        ["logs", "private folder", "delete"], "logs")
            else:
                e = pl.entry(x, "order-note" if fa.endswith(".md") and "/" not in fa else "order-artifact", pl.rel(os.path.join(home, fa)), note="" if "/" not in fa else "artifacts/ ignores itself")
                e["file_as"] = fa
            e["id"], e["home"] = oid, os.path.relpath(home, pl.repo)
    e["digest"] = {"self": tree_digest(fps, unread)}


def residue_of(top, splits):
    """What lies under top besides the order folders and repositories found in it, as the smallest whole entries.
    Iterative, with no depth limit."""
    keep = set(splits); out = []
    if top in keep: return out   # the entry is itself an order folder: nothing beside it
    stack = [top]
    while stack:
        d = stack.pop()
        try: names = sorted(os.listdir(d))
        except OSError: out.append(d); continue
        for name in names:
            p = os.path.join(d, name)
            if p in keep: continue
            if os.path.isdir(p) and not os.path.islink(p) and any(s.startswith(p + os.sep) for s in splits): stack.append(p)
            else: out.append(p)
    return sorted(out)


def placeholder_number(pl, inside, prefix):
    """The next number for a placeholder: past every one the repository has and this plan imports or adopts."""
    used = [int(k.split("-")[1]) for k in inside if k.split("-")[0] == prefix]
    used += [int(e2["id"].split("-")[1]) for e2 in pl.entries if e2["kind"].startswith("outside-order") and e2.get("id", "").startswith(prefix + "-")]
    used += [int(e2["adopt_as"].split("-")[1]) for e2 in pl.entries if e2.get("adopt_as", "").startswith(prefix + "-")]
    width = max([len(k.split("-")[1]) for k in inside if k.split("-")[0] == prefix] or [4])
    return f"{prefix}-{max(used or [0]) + 1:0{width}d}"


def outside_order(pl, o, inside, wod, bgd):
    m = ORDER.match(os.path.basename(o)); oid = m.group(1) + "-" + m.group(2)
    if int(m.group(2)) == 0:   # an order folder with a placeholder number: adopted under the next free one, or not at all
        fps, unread = digest(o); new = placeholder_number(pl, inside, m.group(1))
        found = None if unread else secret_in(o, fps)
        why = f" It may hold something private ({found[0]})." if found else (f" It could not be read to the end." if unread else "")
        n = pl.ask(f"`{pl.rel(o)}` is an order folder with the placeholder number {oid}. Adopt it as {new}, retire it, or move it to the private folder?{why}",
                   [f"adopt as {new}", "retire", "private folder"], "private folder" if (found or unread) else f"adopt as {new}", pl.rel(o))
        e = pl.entry(o, "outside-order-placeholder", "(owner)", question=n)
        e["id"], e["adopt_as"], e["digest"] = oid, new, {"self": tree_digest(fps, unread)}
        return
    # a configured folder that is not plain is an apply blocker already; the plan still places by the default
    dest = "acp/" + ((wod or "Workspace/Docs/WorkOrders") if m.group(1) == "WO" else (bgd or "Workspace/Docs/Bugs")) + "/" + os.path.basename(o)
    copies = inside.get(oid, [])
    (mine, err_o) = digest(o)
    found = None if err_o else secret_in(o, mine)   # what apply would commit is read for secrets first
    why = f" It may hold something private ({found[0]})." if found and found[1] != "binary" else ""
    if not copies:
        others = [x for x in pl.entries if x["kind"].startswith("outside-order") and x.get("id") == oid]
        n = pl.ask(f"`{pl.rel(o)}` ({oid}) exists only outside the repository. Bring it in as an open order, or retire it?{why}",
                   ["import", "retire"] + (["private folder"] if why else []), "private folder" if why else "import", pl.rel(o))
        e = pl.entry(o, "outside-order-only", dest, note=("another copy outside: " + ", ".join(x["path"] for x in others)) if others else "", question=n)
        e["id"], e["digest"] = oid, {"self": tree_digest(mine, err_o)}
        return
    theirs, err_r = digest(copies[0])
    cell = lambda x: x and {"what": x[0], "sha256": x[1] if x[0] == "sha256" else None, "bytes": x[2], "exec": x[3]}
    diff = [{"file": f, "outside": cell(mine.get(f)), "repository": cell(theirs.get(f))}
            for f in sorted(set(mine) | set(theirs)) if not same(mine.get(f), theirs.get(f))]
    conflicts = [x for x in diff if x["outside"] and x["repository"]]
    only_out = [x for x in diff if x["outside"] and not x["repository"]]
    # a copy that could not be read whole may hold anything: it is never identical or contained
    unread = [("outside: " + x) for x in err_o] + [("repository: " + x) for x in err_r]
    if not diff and not unread and os.path.basename(o) == os.path.basename(copies[0]):
        e = pl.entry(o, "outside-order-identical", "dropped (the repository's copy is byte-identical)")
        e["digest"] = {"outside": tree_digest(mine, err_o), "repository": tree_digest(theirs, err_r)}
    elif not conflicts and not only_out and not unread:
        # every file of this copy is in the repository's copy, byte for byte: dropping it loses nothing
        e = pl.entry(o, "outside-order-contained", "dropped (the repository's copy holds every file of it, byte-identical)",
                     note=f"{len(diff)} file(s) only in the repository's copy")
        e["digest"] = {"outside": tree_digest(mine, err_o), "repository": tree_digest(theirs, err_r)}
    else:
        note = f"{len(conflicts)} differ, {len(only_out)} only here" + (f"; not read whole: {', '.join(unread)}" if unread else "")
        n = pl.ask(f"`{pl.rel(o)}` and the repository's `{pl.rel(copies[0])}` are the same order ({oid}): {len(conflicts)} file(s) differ, {len(only_out)} exist only in this copy, {len(diff) - len(conflicts) - len(only_out)} only in the repository's" + (f", and {len(unread)} folder(s) could not be read" if unread else "") + f". Which copy wins, file by file?{why}",
                   ["repository", "outside", "file by file"] + (["private folder"] if why else []), "private folder" if why else "repository", pl.rel(o))
        e = pl.entry(o, "outside-order-differs", "merged into " + pl.rel(copies[0]), note=note, question=n)
        e["differences"] = diff
        e["digest"] = {"outside": tree_digest(mine, err_o), "repository": tree_digest(theirs, err_r)}
        if unread: e["unread"] = unread
    e["id"], e["home"] = oid, os.path.relpath(copies[0], pl.repo)


def has_submodules(repo):
    """A .gitmodules file, or a gitlink in the index: submodules, which git status would go into and whose own filters
    would run. The plan never looks inside them; the owner checks them by hand."""
    if os.path.lexists(os.path.join(repo, ".gitmodules")): return True
    rc, out = git(repo, "ls-files", "-z", "-s")
    return rc == 0 and any(x.startswith("160000 ") for x in out.split("\0"))


def unique_work(p):
    """What only this repository holds, as phrases: changes, untracked or ignored files, stashes, commits on no
    remote. Empty when nothing is unique."""
    out = []
    rc, bare = git(p, "rev-parse", "--is-bare-repository")
    bare = bare.strip() == "true"
    rc, st = (0, "") if bare else git(p, "status", "--porcelain", "-z", "--ignored", "-uall", "--ignore-submodules=all")
    if bare: out.append("a bare repository")
    if rc != 0: out.append("git status could not be read")
    else:
        rows = [x for x in st.split("\0") if x]
        ign = [x for x in rows if x.startswith("!! ")]; unt = [x for x in rows if x.startswith("?? ")]
        chg = len(rows) - len(ign) - len(unt)
        if chg: out.append(f"{chg} uncommitted change(s)")
        if unt: out.append(f"{len(unt)} untracked file(s)")
        if ign: out.append(f"{len(ign)} ignored file(s)")
    rc, n = (0, "") if bare else git(p, "stash", "list")
    if rc != 0: out.append("its stashes could not be read")
    elif n.strip(): out.append(f"{len(n.splitlines())} stash(es)")
    # every ref and a detached HEAD, but not the stash (its commits are counted as stashes above)
    rc, n = git(p, "rev-list", "--count", "HEAD", "--exclude=refs/stash", "--all", "--not", "--remotes")
    if rc != 0: out.append("its commits could not be compared with its remote")
    elif n.strip() not in ("", "0"): out.append(f"{n.strip()} commit(s) on no remote")
    rc, rem = git(p, "remote")
    if rc == 0 and not rem.strip(): out.append("no remote")
    if not bare and has_submodules(p): out.append("has submodules: check them by hand")
    for name, what in (("rebase-merge", "a rebase"), ("rebase-apply", "a rebase"), ("MERGE_HEAD", "a merge"), ("CHERRY_PICK_HEAD", "a cherry-pick"), ("REVERT_HEAD", "a revert"), ("BISECT_LOG", "a bisect")):
        rc, gp = git(p, "rev-parse", "--git-path", name)
        q = gp.strip()
        if rc == 0 and q and os.path.lexists(q if os.path.isabs(q) else os.path.join(p, q)) and what + " in progress" not in out: out.append(what + " in progress")
    return out


def nested_repo(pl, p):
    """A repository beside the product's, at any depth: a second ACP copy, or another; never residue."""
    unique = unique_work(p)
    if all(os.path.exists(os.path.join(p, x)) for x in ("bin/wo", "bin/install.sh", "core/hooks")):
        ver = (read_small(os.path.join(p, "VERSION"), 64) or "").strip()
        note = (("version " + ver + "; ") if ver else "") + ("; ".join(unique) if unique else "nothing unique: clean, nothing untracked or ignored, no stash, every commit on its remote")
        n = pl.ask(f"`{pl.rel(p)}` is a second copy of ACP's source ({note}). Remove it from the project?", ["remove", "keep beside the project"], "remove" if not unique else "keep beside the project", pl.rel(p))
        pl.entry(p, "second-acp", ("removed" if not unique else "kept beside the project") + " (suggested)", note=note, question=n)
    else:
        note = "; ".join(unique) if unique else "nothing unique"
        n = pl.ask(f"`{pl.rel(p)}` is another repository inside the project folder ({note}). What happens to it?", ["remove", "keep beside the project"], "keep beside the project", pl.rel(p))
        pl.entry(p, "other-repo", "(owner)", note=note, question=n)


def plan_git(pl):
    r = pl.repo
    rc, st = git(r, "status", "--porcelain", "-z", "-uall", "--ignore-submodules=all", "--", ".", ":(exclude)" + PLAN_DIR)   # the plan's own folder is not a change
    if rc != 0: pl.blockers.append("git status could not be read in the repository")
    elif st: pl.blockers.append(f"the repository has {len([x for x in st.split(chr(0)) if x])} uncommitted change(s): commit or set them aside before apply")
    rc, remotes = git(r, "remote")
    if rc == 0 and not remotes.strip():
        pl.blockers.append("the repository has no remote: push it to a private remote (after `acp publish-check`) before apply")
    elif rc == 0:
        rc2, ahead = git(r, "rev-list", "--count", "@{upstream}..HEAD")
        if rc2 != 0: pl.blockers.append("the current branch has no upstream: push it to the private remote before apply")
        elif ahead.strip() not in ("", "0"): pl.blockers.append(f"the current branch has {ahead.strip()} commit(s) not pushed: push before apply")
    rc, cur = git(r, "rev-parse", "--abbrev-ref", "HEAD"); cur = cur.strip()
    rc, heads = git(r, "for-each-ref", "--format=%(refname:short)", "refs/heads/")
    used = worktree_branches(r)
    for b in [x for x in heads.splitlines() if x and x != cur]:
        rc, _ = git(r, "merge-base", "--is-ancestor", b, "HEAD")
        if b in used:   # git deletes no branch a worktree has checked out
            q = pl.ask(f"Branch `{b}` is checked out in a worktree, so it is kept unless that worktree is removed first. Delete it, or keep it?", ["delete", "keep"], "keep", "branch " + b)
        elif rc == 0:
            q = pl.ask(f"Branch `{b}` is merged into `{cur}`. Delete it?", ["delete", "keep"], "delete", "branch " + b)
        else:
            rc2, n = git(r, "rev-list", "--count", "HEAD.." + b)
            q = pl.ask(f"Branch `{b}` has {n.strip() or '?'} commit(s) not in `{cur}`. Delete it, or keep it (it becomes an order's branch, or is merged first)?",
                       ["delete", "keep"], "keep", "branch " + b)
        rc, tip = git(r, "rev-parse", "--verify", "-q", "refs/heads/" + b)   # apply deletes only the tip the owner answered about
        pl.questions[q - 1]["branch"], pl.questions[q - 1]["tip"] = b, tip.strip()
    rc, head = git(r, "rev-parse", "HEAD")
    return cur, head.strip()


def worktree_branches(repo):
    """The branches the repository's worktrees have checked out (git worktree list --porcelain)."""
    rc, out = git(repo, "worktree", "list", "--porcelain")
    return {x[len("branch refs/heads/"):] for x in out.splitlines() if x.startswith("branch refs/heads/")} if rc == 0 else set()


def shown(s):
    """Text for display: a name's bytes that are not UTF-8 are shown as \\xNN, never written raw."""
    return str(s).encode("utf-8", "surrogateescape").decode("utf-8", "backslashreplace")


def md(s):
    """A value placed in a markdown table cell: one line, no column break."""
    return shown(s).replace("\\", "\\\\").replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def put(d, name, text):
    """Write one plan file as a new temporary file renamed over it: never through a link, never half-written."""
    fd, tmp = tempfile.mkstemp(dir=d, prefix=TMP_PREFIX + name + ".")
    try:
        mask = os.umask(0); os.umask(mask)
        os.fchmod(fd, 0o666 & ~mask)   # the mode any new file gets, not mkstemp's 0600
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f: f.write(text)   # names as they are, in any locale
        os.replace(tmp, os.path.join(d, name))
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def plan_id_of(data):
    """The plan's id: the sha256 of its data with every answer left out, so answering keeps it and any other change
    to moves.json breaks it."""
    d = dict(data); d.pop("plan_id", None); d.pop("plan_md_sha256", None)
    d["questions"] = [dict(q, answer=None) for q in d.get("questions", [])]
    return hashlib.sha256(json.dumps(d, sort_keys=True).encode("utf-8", "surrogateescape")).hexdigest()


HELD = []   # the plan folder's lock, held until the run ends


def lock(pd):
    """Hold the plan folder's lock (an flock on the folder itself, so no file is added to it) for the rest of this run,
    or refuse: two runs at once would read the same moves.json and one write would be lost."""
    try: fd = os.open(pd, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError: raise Refusal(f"{pd} is a link or not a folder; remove it first")
    try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd); raise Refusal(f"another acp migrate is working in {pd}; wait for it to finish, then run this again")
    HELD.append(fd)


def plan_line(pid):
    return f"- Plan id: `{pid}` (the same in moves.json; `acp migrate answer <n> <option>` records each answer there)"


def write(pl, cur, head, replace):
    d = os.path.join(pl.project, PLAN_DIR)
    try:
        try: os.mkdir(d)
        except FileExistsError: pass
        lock(d)   # the check below, the clean-up and both writes happen under the lock
        if os.path.lexists(os.path.join(d, "moves.json")) and not replace:
            raise Refusal(f"a plan is already in {d}; move it aside, or pass --replace (its recorded answers are lost)")
        for n in os.listdir(d):   # a temporary file a killed run left behind
            x = os.path.join(d, n)
            if STALE_TMP.fullmatch(n) and stat.S_ISREG(os.lstat(x).st_mode): os.unlink(x)
    except OSError as e: raise Refusal(f"{d} cannot be written ({e.strerror})")
    data = {"format": 1, "made": date.today().isoformat(), "project": pl.project, "repository": pl.rel(pl.repo),
            "branch": cur, "head": head, "entries": pl.entries, "questions": pl.questions, "apply_blockers": pl.blockers,
            "suggestions_apply_refuses": pl.suggestion_problems}
    if pl.gitignore_add: data["gitignore_add"] = pl.gitignore_add
    data["plan_id"] = plan_id_of(data)   # the same id in both files: they belong together
    kinds = {}
    for e in pl.entries: kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    L = ["# Migration plan", "", f"Made {data['made']} by `acp migrate plan`. Nothing has moved. `acp migrate apply` does exactly this plan, and refuses while a question below has no answer in `moves.json` or a blocker remains.", "",
         f"- Project folder: `{md(pl.project)}`", f"- Repository: `{md(data['repository'])}` on branch `{md(cur)}` at `{head[:12]}`", "",
         plan_line(data["plan_id"]), "",
         "## Before apply can run", ""]
    L += [f"- {md(b)}" for b in pl.blockers] or ["- nothing blocks apply"]
    if pl.suggestion_problems:
        L += ["", "A suggested answer below is one apply would refuse (a fault in the plan): answer it differently."] + [f"- {md(x)}" for x in pl.suggestion_problems]
    L += ["", "## Questions for the owner", "", "| # | Question | Options | Suggested |", "|---|---|---|---|"]
    L += [f"| {q['n']} | {md(q['question'])} | {md(', '.join(q['options']))} | {md(q['suggested'] if q['suggested'] is not None else '(none: you name it)')} |" for q in pl.questions]
    if pl.gitignore_add:   # the lines in full, one per line, as they would be added (the table above shows them on one line)
        ga = pl.gitignore_add
        L += ["", f"## The .gitignore lines of question {ga['question']}", "", f"{ga['files']} ignored file(s) would become visible after the moves. Answered yes, apply adds these lines to the repository's .gitignore:", "", "```"] + [shown(x) for x in ga["lines"]] + ["```"]
    L += ["", "## Every entry", "", "| Path | Kind | Goes to | Bytes | Question | Note |", "|---|---|---|---|---|---|"]
    L += [f"| `{md(e['path'])}` | {e['kind']} | {md(e['to'])} | {e['bytes']} | {e.get('question', '')} | {md(e['note'])} |" for e in pl.entries]
    diffs = [e for e in pl.entries if e.get("differences") or e.get("unread")]
    if diffs:
        L += ["", "## Orders in two places that differ", ""]
        cell = lambda x: "absent" if not x else (f"{x['bytes']} bytes, `{x['sha256'][:12]}`" if x["sha256"] else f"{x['what']}, {x['bytes']} bytes")
        for e in diffs:
            L += [f"### `{md(e['path'])}` (question {e['question']})", ""]
            if e.get("unread"): L += ["Not read whole: " + ", ".join(f"`{md(x)}`" for x in e["unread"]), ""]
            L += ["| File | Outside | Repository |", "|---|---|---|"]
            L += [f"| `{md(x['file'])}` | {cell(x['outside'])} | {cell(x['repository'])} |" for x in e.get("differences", [])]
            L.append("")
    L += ["", "## Summary", ""] + [f"- {k}: {v}" for k, v in sorted(kinds.items())]
    # moves.json is the marker a plan is here: written last, so it never stands without its MIGRATION-PLAN.md
    text = "\n".join(L).rstrip("\n") + "\n"
    data["plan_md_sha256"] = hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()   # binds every byte of it
    try:
        put(d, "MIGRATION-PLAN.md", text)
        put(d, "moves.json", json.dumps(data, indent=1, sort_keys=True) + "\n")
    except OSError as e: raise Refusal(f"{d} cannot be written ({e.strerror})")


BACKUP_FILES = ("manifest.json", "backup.json")
STALE_BACKUP_TMP = re.compile(r"^\.acp-plan-tmp\.(manifest|backup)\.json\.[A-Za-z0-9_]{8}$")


def in_git_objects(top, rel):
    """Whether rel lies under the objects/ folder of a git directory (a folder holding HEAD, objects/ and refs/)."""
    parts = rel.split(os.sep)
    return any(parts[i] == "objects" and os.path.isfile(os.path.join(top, *parts[:i], "HEAD")) for i in range(1, len(parts)))


def walk_tree(top, skip_top=(), vanish_ok=False):
    """Every entry under top, .git included, as (relative path, lstat), sorted so a folder comes before what it holds;
    and what could not be read, each with its reason. Iterative, links never followed; skip_top names at top are left
    out. With vanish_ok, a file that vanishes under a git directory's objects/ while it is walked (git packing loose
    objects, as gc and maintenance do) is left out instead: only a comparing walk asks for that, never a backup."""
    out, errors, stack = [], [], [top]
    while stack:
        d = stack.pop()
        try: names = os.listdir(d)
        except OSError as e:
            if not (vanish_ok and isinstance(e, FileNotFoundError) and in_git_objects(top, os.path.relpath(d, top))):
                errors.append((os.path.relpath(d, top), e))
            continue
        for n in names:
            if d == top and n in skip_top: continue
            p = os.path.join(d, n); rel = os.path.relpath(p, top)
            try: st = os.lstat(p)
            except OSError as e:
                if not (vanish_ok and isinstance(e, FileNotFoundError) and in_git_objects(top, rel)): errors.append((rel, e))
                continue
            out.append((rel, st))
            if stat.S_ISDIR(st.st_mode): stack.append(p)
    out.sort(key=lambda x: x[0].split(os.sep))
    return out, errors


def why(e):
    """A file's reason for not being read, said plainly: a file gone while read is not one that cannot be read."""
    if isinstance(e, FileNotFoundError): return "it vanished while being read (git's own housekeeping, such as an automatic gc, can do this: run again when git is idle)"
    return e.strerror or e.__class__.__name__


def file_sha(p):
    """sha256 of a regular file, opened only after lstat says it is one."""
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
    return h.hexdigest()


def manifest_of(top, vanish_ok=False):
    """The manifest of a tree: one row per entry. Refuses on anything it cannot read, naming each with its reason, and
    on a special file: a backup that silently left them out would look whole. vanish_ok as for walk_tree."""
    entries, errors = walk_tree(top, skip_top=(PLAN_DIR,), vanish_ok=vanish_ok)
    rows, unread = [], list(errors)
    for rel, st in entries:
        m = st.st_mode
        row = {"path": rel, "mode": stat.S_IMODE(m), "mtime_ns": st.st_mtime_ns}
        if stat.S_ISDIR(m): row["type"] = "dir"
        elif stat.S_ISLNK(m): row.update(type="link", target=os.readlink(os.path.join(top, rel)))
        elif stat.S_ISREG(m):
            row.update(type="file", size=st.st_size)
            try: row["sha256"] = file_sha(os.path.join(top, rel))
            except OSError as e:
                if not (vanish_ok and isinstance(e, FileNotFoundError) and in_git_objects(top, rel)): unread.append((rel, e))
                continue
        else: raise Refusal(f"{rel} is a special file (a pipe, socket or device); a backup copies files, folders and links only, so remove it first")
        rows.append(row)
    if unread:
        unread.sort(key=lambda x: x[0])
        raise Refusal("these cannot be read, so a backup would miss them: " + ", ".join(f"{r} ({why(e)})" for r, e in unread[:10]) + (f" (and {len(unread) - 10} more)" if len(unread) > 10 else ""))
    return rows


def git_dirs(rows):
    """Every git directory in a manifest, as its path: a folder holding HEAD (a file), objects/ and refs/ (a repository's
    .git, or a bare repository). What lies in one is judged by git_state, not row by row."""
    kind = {r["path"]: r["type"] for r in rows}
    return sorted(p for p, t in kind.items() if t == "dir" and kind.get(os.path.join(p, "HEAD")) == "file"
                  and kind.get(os.path.join(p, "objects")) == "dir" and kind.get(os.path.join(p, "refs")) == "dir")


def drop_git(rows, dirs):
    """The rows outside every git directory: git rewrites its own files (packing objects, the index, its logs)."""
    return [r for r in rows if not any(r["path"] == d or r["path"].startswith(d + os.sep) for d in dirs)]


def git_state(gitdir):
    """What matters in a git directory: HEAD, every ref, the config, the hooks and info files, each worktree's HEAD, and
    every object reachable from a ref or a reflog (their sorted ids, as one sha256, and how many). Read with no lock and
    no housekeeping. Two states are equal when nothing a person or a tool relies on has changed."""
    def g(*args):
        p = subprocess.run(GIT + ["--git-dir=" + gitdir] + list(args), capture_output=True, timeout=900, env=GIT_ENV)
        if p.returncode != 0: raise Refusal(f"git could not read {gitdir} ({(os.fsdecode(p.stderr).strip().splitlines() or ['exit %d' % p.returncode])[-1]})")
        return p.stdout
    shas = lambda sub: {os.path.relpath(os.path.join(d, f), os.path.join(gitdir, sub)): file_sha(os.path.join(d, f))
                        for d, _, fs in os.walk(os.path.join(gitdir, sub)) for f in fs if not os.path.islink(os.path.join(d, f))}
    ids = sorted({x.split(b" ")[0] for x in g("rev-list", "--objects", "--all", "--reflog").splitlines() if x})
    wt = os.path.join(gitdir, "worktrees")
    return {"HEAD": (read_small(os.path.join(gitdir, "HEAD")) or ""),
            "refs": os.fsdecode(g("for-each-ref", "--format=%(refname) %(objectname) %(symref)")),
            "config": file_sha(os.path.join(gitdir, "config")) if os.path.isfile(os.path.join(gitdir, "config")) else None,
            "hooks": shas("hooks"), "info": {k: v for k, v in shas("info").items() if k != "refs"},   # info/refs is derived (update-server-info, run by gc)
            "worktrees": {n: (read_small(os.path.join(wt, n, "HEAD")) or "") for n in (sorted(os.listdir(wt)) if os.path.isdir(wt) else [])},
            "objects": hashlib.sha256(b"\n".join(ids)).hexdigest(), "objects_count": len(ids)}


def git_states(top, dirs):
    return {d: git_state(os.path.join(top, d)) for d in dirs}


def git_states_or_none(top, dirs):
    """git_states, or None when git cannot read one: a record written while apply stops must not hide why it stopped."""
    try: return git_states(top, dirs)
    except (Refusal, OSError, subprocess.SubprocessError): return None


def git_changes(before, after):
    """What differs between two sets of git states, each named for a person: the repository, then what moved."""
    out = []
    for d in sorted(set(before) | set(after)):
        a, b = before.get(d), after.get(d)
        if a is None or b is None: out.append(f"{d}: {'a repository that was not there' if a is None else 'a repository that is gone'}"); continue
        for k in ("HEAD", "refs", "config", "hooks", "info", "worktrees", "objects"):
            if a.get(k) != b.get(k):
                if k == "refs":
                    ra, rb = set(a[k].splitlines()), set(b[k].splitlines())
                    names = sorted({x.split(" ")[0] for x in ra ^ rb})
                    out.append(f"{d}: refs {', '.join(names[:3])}" + (" …" if len(names) > 3 else "") + " moved")
                elif k == "objects": out.append(f"{d}: the reachable objects ({a['objects_count']} then, {b['objects_count']} now)")
                else: out.append(f"{d}: {k}")
    return out


class HashingReader:
    """A file read for the archive, hashing what it gives, so the archive's bytes are the bytes the manifest names."""
    def __init__(self, f): self.f, self.h = f, hashlib.sha256()
    def read(self, n=-1):
        b = self.f.read(n); self.h.update(b); return b


def write_archive(fd, top, rows):
    """Write the archive of rows under top into fd, a file this run created, and fsync it."""
    with os.fdopen(fd, "wb") as raw:
        with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tf: add_rows(tf, top, rows)
        raw.flush(); os.fsync(raw.fileno())


def add_rows(tf, top, rows):
    for r in rows:
        p = os.path.join(top, r["path"])
        ti = tf.gettarinfo(p, arcname=r["path"])
        if ti is None: raise Refusal(f"{r['path']} cannot be archived")
        if ti.isreg():
            with open(p, "rb") as f:
                hr = HashingReader(f); tf.addfile(ti, hr)
            if hr.h.hexdigest() != r["sha256"]: raise Refusal(f"{r['path']} changed while the backup was written")
        else: tf.addfile(ti)


def check_archive(archive, rows):
    """Read the archive back: every row archived, as it was (type, mode, size, sha256, link target); nothing else."""
    want = {r["path"]: r for r in rows}
    seen = set()
    with tarfile.open(archive, "r") as tf:
        hard = {}
        for ti in tf:
            r = want.get(ti.name)
            if r is None or ti.name in seen: raise Refusal(f"the archive holds {ti.name!r}, which the manifest does not")
            seen.add(ti.name)
            kind = "dir" if ti.isdir() else "link" if ti.issym() else "file" if (ti.isreg() or ti.islnk()) else "?"
            if kind != r["type"] or (ti.mode & 0o7777) != r["mode"]: raise Refusal(f"{ti.name} is not archived as it was")
            if kind == "link" and ti.linkname != r["target"]: raise Refusal(f"{ti.name} is not archived as it was")
            if ti.isreg():
                h = hashlib.sha256(); f = tf.extractfile(ti)
                for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
                hard[ti.name] = h.hexdigest()
                if ti.size != r["size"] or h.hexdigest() != r["sha256"]: raise Refusal(f"{ti.name} is not archived as it was")
            elif ti.islnk() and hard.get(ti.linkname) != r["sha256"]: raise Refusal(f"{ti.name} is not archived as it was")
    missing = sorted(set(want) - seen)
    if missing: raise Refusal("the archive is missing " + ", ".join(missing[:10]))


def backup_put(d, name, text):
    for n in os.listdir(d):   # a temporary file a killed run left behind, named as only these writes name them
        x = os.path.join(d, n)
        if STALE_BACKUP_TMP.fullmatch(n) and stat.S_ISREG(os.lstat(x).st_mode): os.unlink(x)
    put(d, name, text)


def remote_state(repo):
    rc, rem = git(repo, "remote")
    if rc != 0 or not rem.strip(): return {"exists": False, "pushed": False}
    rc, ahead = git(repo, "rev-list", "--count", "@{upstream}..HEAD")
    return {"exists": True, "pushed": rc == 0 and ahead.strip() == "0"}


def within(path, folder):
    """Whether path is folder or lies inside it, judged by the device and inode of path and of each of its parents,
    never by spelling: a case-variant or firmlink spelling of the same folder is the same folder."""
    try: key = (os.stat(folder).st_dev, os.stat(folder).st_ino)
    except OSError: return False
    d = os.path.realpath(path)
    while True:
        try:
            st = os.stat(d)
            if (st.st_dev, st.st_ino) == key: return True
        except OSError: pass
        if os.path.dirname(d) == d: return False
        d = os.path.dirname(d)


def outside_git_data(top, rows):
    """Where a repository in top keeps data outside top, as phrases: a .git file or commondir naming a folder outside
    (a linked worktree, --separate-git-dir), an alternates entry outside (clone --shared, --reference), any http
    alternates, or a link inside a .git folder leading out. A backup of top would not hold that data."""
    out, have = [], {r["path"] for r in rows}
    bare = {r["path"] for r in rows if r["type"] == "dir" and all(os.path.join(r["path"], x) in have for x in ("HEAD", "objects", "refs"))}
    for r in rows:
        rel = r["path"]; parts = rel.split(os.sep); p = os.path.join(top, rel)
        in_git = ".git" in parts[:-1] or parts[-1] == ".git" or any(rel.startswith(b + os.sep) for b in bare)
        if r["type"] == "link":
            if in_git and not within(p, top): out.append(f"{rel} (a link to {r['target']})")
            continue
        if r["type"] != "file": continue
        named = []
        if parts[-1] == ".git":
            t = read_small(p, 4096) or ""
            if t.startswith("gitdir: "): named = [t[8:].strip()]
        elif parts[-1] == "commondir" and in_git: named = [(read_small(p, 4096) or "").strip()]
        elif parts[-3:] == ["objects", "info", "alternates"]:
            named = [x.strip() for x in (read_small(p) or "").splitlines() if x.strip() and not x.startswith("#")]
            p = os.path.join(os.path.dirname(os.path.dirname(p)), "x")   # alternates are relative to the objects folder
        elif parts[-3:] == ["objects", "info", "http-alternates"]: out.append(f"{rel} (http alternates)"); continue
        for n in named:
            if n and not within(os.path.join(os.path.dirname(p), n), top): out.append(f"{rel} (names {n})")
    return out


def changed(before, after):
    """The paths two manifests disagree on, named for a refusal: the first five, and how many more."""
    a, b = {r["path"]: r for r in before}, {r["path"]: r for r in after}
    diff = sorted(p for p in set(a) | set(b) if a.get(p) != b.get(p))
    return ", ".join(diff[:5]) + (f" (and {len(diff) - 5} more)" if len(diff) > 5 else "")


def mounts_in(project, rows):
    """Folders in the project on another device than the project: a mount a backup and a rollback cannot hold."""
    dev = os.lstat(project).st_dev
    return [r["path"] for r in rows if r["type"] == "dir" and os.lstat(os.path.join(project, r["path"])).st_dev != dev]


def backup(project, repo, to):
    """Write the backup, or raise Refusal with the reason; nothing that looks like a backup is left on failure."""
    to = os.path.realpath(to)
    if not os.path.isdir(to): raise Refusal(f"{to} is not a folder")
    if within(to, project): raise Refusal(f"{to} is inside the project; the backup must be kept outside it")
    if not os.access(to, os.W_OK): raise Refusal(f"{to} cannot be written to")
    pd = os.path.join(project, PLAN_DIR)
    for p in [pd] + [os.path.join(pd, n) for n in BACKUP_FILES]:   # never written through a link
        if os.path.lexists(p) and (os.path.islink(p) or not (os.path.isdir(p) if p == pd else os.path.isfile(p))):
            raise Refusal(f"{p} is a link or not a {'folder' if p == pd else 'regular file'}; remove it first")
    if os.path.isdir(pd): lock(pd)   # no plan folder, no plan, so no apply can be running
    for f in ("journal.jsonl", "applied.json"):
        if os.path.lexists(os.path.join(pd, f)):
            raise Refusal(f"an apply has run here ({PLAN_DIR}/{f}); a new backup would describe the migrated tree. Roll back first, or start again from a fresh copy")
    name = os.path.basename(project) + "-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".tar"
    final, partial = os.path.join(to, name), os.path.join(to, name + ".partial")
    for p in (final, partial, final + ".sha256"):
        if os.path.lexists(p): raise Refusal(f"{p} already exists; a backup is never written over anything")
    rows = manifest_of(project)
    gits = git_states(project, git_dirs(rows))   # what the comparing checks judge .git by (the archive holds .git whole)
    mounted = mounts_in(project, rows)
    if mounted: raise Refusal(f"{mounted[0]} is on another device (a mount inside the project); a backup cannot hold it, so unmount it or move it out first")
    elsewhere = outside_git_data(project, rows)
    if elsewhere: raise Refusal("a repository in the project keeps data outside it, so a backup would not hold it: " + "; ".join(elsewhere[:5]))
    # everything that could refuse is asked before the archive is written: once it has its final name, only the
    # sha256 file and the record follow
    rc, head = git(repo, "rev-parse", "HEAD"); rc, cur = git(repo, "rev-parse", "--abbrev-ref", "HEAD"); remote = remote_state(repo)
    need = 10240 + sum(1536 + -(-r.get("size", 0) // 512) * 512 for r in rows)   # per entry a PAX header block set and its data in 512-byte blocks; the end
    vfs = os.statvfs(to)
    if vfs.f_bavail * vfs.f_frsize < need: raise Refusal(f"{to} has {vfs.f_bavail * vfs.f_frsize} bytes free; the backup needs about {need}")
    # an earlier backup's record goes now, after every check that could refuse: a refused run leaves a record
    # that is still true; from here until this run's record is written, no backup is recorded
    try:
        for n in BACKUP_FILES:
            if os.path.lexists(os.path.join(pd, n)): os.unlink(os.path.join(pd, n))
    except OSError as e: raise Refusal(f"{pd} cannot be written ({e.strerror})")
    created = False
    try:
        fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)   # never a file already there
        created = True
        write_archive(fd, project, rows)
        check_archive(partial, rows)
        now = manifest_of(project)
        if now != rows: raise Refusal("the project changed while the backup was written: " + changed(rows, now))
        if not os.path.lexists(pd): os.mkdir(pd)   # made only once the archive has been read back whole
        if not os.access(pd, os.W_OK): raise Refusal(f"{pd} cannot be written to")
        sha = file_sha(partial)
        os.replace(partial, final)
    except BaseException as e:
        if created:   # only the file this run created, by its exact name
            try: os.unlink(partial)
            except OSError: pass
        if isinstance(e, Refusal): raise
        if isinstance(e, FileExistsError): raise Refusal(f"{partial} already exists; a backup is never written over anything")
        if isinstance(e, OSError): raise Refusal(f"the archive could not be written ({e.strerror or e}); nothing was kept")
        raise
    made, tmp = [final], None   # from here a failure removes what this run made: a refused backup leaves nothing like one
    try:
        fd, tmp = tempfile.mkstemp(dir=to, prefix="." + name + ".sha256.")
        mask = os.umask(0); os.umask(mask); os.fchmod(fd, 0o666 & ~mask)
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f: f.write(f"{sha}  {name}\n")
        os.replace(tmp, final + ".sha256"); tmp = None; made.append(final + ".sha256")
        mtext = json.dumps({"format": 1, "entries": rows}, indent=1, sort_keys=True) + "\n"
        record = {"format": 1, "made": datetime.now().isoformat(timespec="seconds"), "project": project, "repository": os.path.relpath(repo, project),
                  "archive": final, "archive_sha256": sha, "archive_bytes": os.path.getsize(final), "entries": len(rows),
                  "manifest_sha256": hashlib.sha256(mtext.encode()).hexdigest(),
                  "head": head.strip(), "branch": cur.strip(), "remote": remote, "git": gits}
        backup_put(pd, "manifest.json", mtext); made.append(os.path.join(pd, "manifest.json"))
        backup_put(pd, "backup.json", json.dumps(record, indent=1, sort_keys=True) + "\n")   # the mark the backup is whole: last
    except BaseException as e:
        for p in ([tmp] if tmp else []) + made:
            try: os.unlink(p)
            except OSError: pass
        if isinstance(e, Refusal): raise
        if isinstance(e, OSError): raise Refusal(f"the backup's record could not be written ({e.strerror or e}); nothing was kept")
        raise
    return record


def check_backup(project):
    """Re-read the recorded backup against its record, its sha256 file, its manifest and the project as it is now.
    head, branch and remote are recorded, not vouched for."""
    pd = os.path.join(project, PLAN_DIR)
    btext, mtext = read_small(os.path.join(pd, "backup.json"), 1 << 24), read_small(os.path.join(pd, "manifest.json"), 1 << 30)
    if btext is None or mtext is None: raise Refusal(f"no backup is recorded in {pd}")
    try: rec, entries = json.loads(btext), json.loads(mtext)["entries"]
    except (ValueError, KeyError, TypeError) as e: raise Refusal(f"the backup record in {pd} cannot be read ({e.__class__.__name__})")
    if not isinstance(rec, dict) or not isinstance(entries, list): raise Refusal(f"the backup record in {pd} cannot be read")
    if hashlib.sha256(mtext.encode()).hexdigest() != rec.get("manifest_sha256"): raise Refusal("manifest.json is not the one the backup recorded")
    if rec.get("entries") != len(entries) or rec.get("project") != project: raise Refusal("backup.json does not describe this project's manifest")
    archive = str(rec.get("archive", ""))
    if not os.path.isfile(archive) or os.path.islink(archive): raise Refusal(f"the archive {archive} is not there (or is not a regular file)")
    if file_sha(archive) != rec.get("archive_sha256"): raise Refusal(f"the archive {archive} is not the one recorded: its sha256 differs")
    if (read_small(archive + ".sha256", 4096) or "") != f"{rec.get('archive_sha256')}  {os.path.basename(archive)}\n" or rec.get("archive_bytes") != os.path.getsize(archive):
        raise Refusal(f"{archive}.sha256 does not match")
    check_archive(archive, entries)
    now = manifest_of(project, vanish_ok=True)   # git may pack its loose objects under this walk: that is not a change
    if not isinstance(rec.get("git"), dict):   # a backup made before git directories were judged by their state
        if now != entries: raise Refusal("the project has changed since the backup: " + changed(entries, now) + " (this backup judges .git byte for byte; a new backup judges it by its refs and objects)")
        return rec
    dirs = sorted(rec["git"])
    before, after = drop_git(entries, dirs), drop_git(now, dirs)
    if before != after: raise Refusal("the project has changed since the backup: " + changed(before, after))
    moved = git_changes(rec["git"], git_states(project, dirs))
    if moved: raise Refusal("the repository has changed since the backup: " + "; ".join(moved[:5]))
    return rec


def read_plan_file(p, limit):
    """The bytes of one plan file: a regular file, never through a link, at most limit bytes; None if it is missing."""
    try: fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError: return None
    except OSError: raise Refusal(f"{p} is a link or not a regular file; remove it first")
    if not stat.S_ISREG(os.fstat(fd).st_mode):   # a folder or a pipe by that name: checked before it is read
        os.close(fd); raise Refusal(f"{p} is a link or not a regular file; remove it first")
    with os.fdopen(fd, "rb") as f: b = f.read(limit + 1)
    if len(b) > limit: raise Refusal(f"{p} is larger than a plan can be")
    return b


def read_plan(project):
    """The plan written for this project, read under the plan folder's lock (held until the run ends), or a refusal:
    both plan files regular and never through a link, the same plan id, MIGRATION-PLAN.md's every byte, the project
    by device and inode."""
    pd = os.path.join(project, PLAN_DIR)
    if not os.path.lexists(pd): raise Refusal(f"no plan to {CMD} in {pd} (run: acp migrate plan)")
    lock(pd)   # refuses a linked folder
    raw = {f: read_plan_file(os.path.join(pd, f), 1 << 30) for f in PLAN_FILES}
    if any(v is None for v in raw.values()): raise Refusal(f"no plan to {CMD} in {pd} (run: acp migrate plan)")
    not_same = Refusal("moves.json and MIGRATION-PLAN.md are not the same plan (an edit, or a file from another run); run: acp migrate plan --replace")
    try: data = json.loads(raw["moves.json"].decode("utf-8", "surrogateescape"))
    except ValueError as e: raise Refusal(f"moves.json cannot be read ({e.__class__.__name__})")
    qs = data.get("questions") if isinstance(data, dict) else None
    if not (isinstance(qs, list) and all(isinstance(q, dict) and isinstance(q.get("options"), list) for q in qs)):
        raise Refusal("moves.json cannot be read (it is not a plan)")
    pid, md = data.get("plan_id"), raw["MIGRATION-PLAN.md"]
    if (not isinstance(pid, str) or pid != plan_id_of(data) or data.get("plan_md_sha256") != hashlib.sha256(md).hexdigest()
            or [x for x in md.decode("utf-8", "surrogateescape").split("\n") if x.startswith("- Plan id:")] != [plan_line(pid)]):
        raise not_same
    try: same = isinstance(data.get("project"), str) and os.path.samefile(data["project"], project)   # by device and inode
    except OSError: same = False
    if not same:   # a copy of the project, or a plan carried from another one
        if not isinstance(data.get("project"), str): raise not_same
        raise Refusal(f"this is not the plan's project (it was made in {data['project']}); run: acp migrate plan --replace")
    return data


def folder_answer_ok(value, project, n):
    """The one rule for the private folder, at answer and again at apply: absolute, one line of plain text, and
    neither inside the project nor holding it."""
    if not isinstance(value, str) or not os.path.isabs(value) or re.search(r"[\x00-\x1f\x7f]", value):
        raise Refusal(f"question {n} needs an absolute folder, on one line")
    if any("\udc80" <= c <= "\udcff" for c in value):   # bytes that are not UTF-8, carried in by surrogateescape
        raise Refusal(f"question {n} needs a folder whose name is UTF-8 text")
    if within(value, project): raise Refusal(f"{value} is inside the project; question {n} asks for a folder outside it")
    if within(project, value): raise Refusal(f"{value} holds the project; question {n} asks for a folder outside it")


def answer(project, n, value, folder):
    """Record one answer in moves.json, or refuse: the two plan files must be the plan written for this project, and the
    answer must be one of the question's options, or an absolute folder outside the project where the plan asks for one."""
    pd = os.path.join(project, PLAN_DIR)
    data = read_plan(project)
    qs = data["questions"]
    if not qs: raise Refusal("the plan has no questions to answer")
    by_n = {q.get("n"): q for q in qs}
    if not re.fullmatch(r"[1-9][0-9]*", n or "") or int(n) not in by_n: raise Refusal(f"there is no question {n} (questions 1 to {len(qs)})")
    q = by_n[int(n)]
    opts = ", ".join(str(o) for o in q["options"])
    if q["options"] == [FOLDER_ANSWER]:
        if not folder: raise Refusal(f"question {n} asks for a folder: acp migrate answer {n} --folder <absolute folder outside the project>")
        folder_answer_ok(value, project, n)
    else:
        if folder: raise Refusal(f"question {n} is answered with one of its options: {opts}")
        if value not in q["options"]: raise Refusal(f"question {n} has no option '{value}'; its options: {opts}")
    was, q["answer"] = q.get("answer"), value
    try: put(pd, "moves.json", json.dumps(data, indent=1, sort_keys=True) + "\n")
    except OSError as e: raise Refusal(f"{pd} cannot be written ({e.strerror})")
    left = sum(1 for x in qs if x.get("answer") is None)
    return was, left


# --- apply: the restructure in one commit -------------------------------------------------------------------------

ACP_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))   # <root>/core/hooks/migrate.py
APPLY_DIRS = ("acp", "app")
MSG = "Move the product into app/ and the pipeline into acp/"


def version_of(acp_script):
    """The ACP version a bin/acp states, in the line the plugin build reads; None if it states none."""
    text = read_small(acp_script)
    m = re.search(r'^VERSION="([^"]*)"', text or "", re.M)
    return m.group(1) if m else None


def run_tool(cmd, cwd):
    """(exit code, its last line of output) of one of this ACP's own tools."""
    try: p = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=900)
    except (OSError, subprocess.SubprocessError) as e: return 127, str(e)
    lines = [x for x in os.fsdecode(p.stderr + p.stdout).splitlines() if x.strip()]
    err = [x for x in os.fsdecode(p.stderr).splitlines() if x.strip()]
    return p.returncode, (err or lines or [""])[-1].strip()


def git_write(repo, *args):
    """(exit code, stdout, stderr) of a git command that changes the index or makes the commit: no hook, no filter
    driver, no lock left behind on failure."""
    opts = no_filters(repo)
    p = subprocess.run(GIT + opts + ["-C", repo] + list(args), capture_output=True, timeout=600, env=GIT_ENV)
    return p.returncode, os.fsdecode(p.stdout), os.fsdecode(p.stderr).strip()


def git_in(repo, data, *args):
    """(exit code, stdout) of a read-only git command fed on stdin."""
    p = subprocess.run(GIT + no_filters(repo) + ["-C", repo] + list(args), input=data, capture_output=True, timeout=600, env=GIT_ENV)
    return p.returncode, os.fsdecode(p.stdout)


def journal_path(project): return os.path.join(project, PLAN_DIR, "journal.jsonl")
JOURNAL_N = {}   # journal path -> (its steps, its size after this process's last line): a step costs the same at any length


def read_journal(project):
    """The journal as one record: its first line, with every step in order, each marked done once its mark is there. A
    last line cut short (a stop mid-write) is left out: its step was not taken, or its mark not written, and undo puts
    back by what is on disk."""
    path = journal_path(project)
    if not os.path.isfile(path): raise Refusal(f"{path} is missing: the journal is written before the first step")
    data = open(path, "rb").read(); data = data[:data.rfind(b"\n") + 1]
    try:
        lines = data.splitlines(); j = dict(json.loads(lines[0]), steps=[])
        for line in lines[1:]:
            r = json.loads(line)
            if "mark" in r: j["steps"][r.pop("mark") - 1].update(r, done=True)
            else: j["steps"].append(r)
    except (ValueError, IndexError, KeyError, TypeError, AttributeError) as e: raise Refusal(f"{path} cannot be read ({e.__class__.__name__}: {e})")
    return j


def journal_append(project, line, new):
    """Append one line and sync it, so every finished step is on disk before the next starts. Returns the step count."""
    path = journal_path(project); n, size = JOURNAL_N.get(path, (None, None))
    if os.path.islink(path) or not os.path.isfile(path): raise Refusal(f"{path} is missing: the journal is written before the first step")
    if os.path.getsize(path) != size: n = len(read_journal(project)["steps"])   # written by another hand: counted again
    with open(path, "ab") as f:
        f.write((json.dumps(line(n), sort_keys=True) + "\n").encode()); f.flush(); os.fsync(f.fileno())
        JOURNAL_N[path] = (n + new, os.fstat(f.fileno()).st_size)
    return n + new


def journal_step(project, step):
    """Record a step before it is taken (done: false), by the plan folder's own writer."""
    return journal_append(project, lambda n: dict(step, n=n + 1, done=False), 1)


def journal_done(project, n, **more): journal_append(project, lambda _: dict(more, mark=n), 0)


def b64(b): return None if b is None else base64.b64encode(b).decode()


def file_bytes(p):
    try:
        with open(p, "rb") as f: return f.read()
    except FileNotFoundError: return None


def indexes_of(project):
    """sha256 of the staged content (ls-files -s -z) of every index in the project, read with no refresh."""
    out = {}
    for d, dirs, files in os.walk(project):
        dirs[:] = [x for x in dirs if not os.path.islink(os.path.join(d, x))]
        if "index" in files and (os.path.basename(d) == ".git" or os.path.basename(os.path.dirname(d)) == "worktrees"):
            p = subprocess.run(["git", "--git-dir=" + d, "ls-files", "-s", "-z"], capture_output=True, timeout=120,
                               env=dict(GIT_ENV, GIT_OPTIONAL_LOCKS="0"))
            out[os.path.relpath(os.path.join(d, "index"), project)] = hashlib.sha256(p.stdout).hexdigest() if p.returncode == 0 else None
    return out


def write_applied(project, outcome, extra=None):
    """The record rollback reads: `started` before the first move, the outcome when apply ends."""
    pd = os.path.join(project, PLAN_DIR)
    path = os.path.join(pd, "applied.json")
    rec = json.load(open(path)) if outcome != "started" else {}
    rec.update(extra or {}); rec["outcome"] = outcome
    if outcome != "started":
        rows = manifest_of(project, vanish_ok=True)   # git may pack its loose objects under this walk
        mtext = json.dumps({"format": 1, "entries": rows}, indent=1, sort_keys=True) + "\n"
        put(pd, "applied-manifest.json", mtext)
        rec.update(manifest_sha256=hashlib.sha256(mtext.encode()).hexdigest(), indexes=indexes_of(project),
                   git=git_states_or_none(project, git_dirs(rows)))   # what rollback judges .git by, as backup --check does
    put(pd, "applied.json", json.dumps(rec, indent=1, sort_keys=True) + "\n")


def preflight(project, repo, data):
    """Every check apply makes before it touches anything, each a one-line refusal. Returns what the steps need:
    the answers, the private folder, the moves in order, the open orders to rewrite, and the entries beside the
    repository (carried out by the part of apply that works beside it)."""
    rrel = data.get("repository", ".")
    # the ACP running this: a source clone outside the project, the same version as the project's pipeline
    if not os.path.isfile(os.path.join(ACP_ROOT, "bin", "install.sh")) or os.path.exists(os.path.join(ACP_ROOT, ".source")) or within(ACP_ROOT, project):
        raise Refusal(f"apply runs from an ACP source clone outside the project, not from an installed copy ({ACP_ROOT}); run it as <clone>/bin/acp migrate apply")
    cfg = read_small(os.path.join(repo, "pipeline.config.sh")) or ""
    pr = setting(cfg, "PIPELINE_ROOT", ".aicodepipeline")
    mine = version_of(os.path.join(ACP_ROOT, "bin", "acp"))
    theirs = (read_small(os.path.join(repo, pr or ".aicodepipeline", "VERSION")) or "").strip() or None
    if mine is None or theirs != mine:
        raise Refusal(f"upgrade first: {ACP_ROOT}/bin/install.sh {repo}, commit, then acp migrate plan again (this project's pipeline is {theirs or 'unversioned'}, this ACP is {mine}; one change per commit: upgrade, then plan, backup, answer, apply)")
    # the backup first: a git command that refreshes the index would make --check refuse
    check_backup(project)
    if has_submodules(repo): raise Refusal("this repository has submodules; moving them changes where their git data is found, so apply does not yet: move them by hand, commit, and plan again")
    rc, files = git(repo, "ls-files", "-z")
    rc2, attrs = git_in(repo, files.encode("utf-8", "surrogateescape"), "check-attr", "-z", "--stdin", "filter")
    a = attrs.split("\0")
    filtered = [a[i] for i in range(0, len(a) - 2, 3) if a[i + 2] not in ("unspecified", "unset")]
    if rc != 0 or rc2 != 0 or filtered:   # a driver configured but used by no tracked file (a global Git LFS) is harmless
        rc3, where = git(repo, "config", "--show-scope", "--get-regexp", r"^filter\.")
        scopes = sorted({x.split()[0] for x in where.splitlines() if x.strip()} - {"command"}) if rc3 == 0 else []   # "command": migrate's own blanking
        raise Refusal(f"{(filtered or ['the attributes'])[0]} passes through a filter driver (configured: {', '.join(scopes) or 'nowhere'}); apply stages files as they are on disk, so a filtered file would be committed unfiltered: move this repository by hand")
    rc, st = git(repo, "status", "--porcelain", "-z", "-uall", "--ignore-submodules=all", "--", ".", ":(exclude)" + PLAN_DIR)
    if rc != 0: raise Refusal("the repository's status cannot be read")
    if st:   # staged, unstaged or untracked (not ignored): apply stages the whole tree, so nothing of the owner's may be in it
        names = [x[3:] for x in st.split("\0") if len(x) > 3]
        raise Refusal("the repository has changes apply would sweep into its commit: " + ", ".join(names[:5]) + (f" (and {len(names) - 5} more)" if len(names) > 5 else "") + "; commit or set them aside, then plan again")
    # the plan's own state
    if data.get("apply_blockers"): raise Refusal("the plan has a blocker: " + str(data["apply_blockers"][0]))
    qs = {q["n"]: q for q in data["questions"]}
    answers, private_folder = {}, None
    for n, q in sorted(qs.items()):
        a = q.get("answer")
        if a is None: raise Refusal(f"question {n} has no answer: acp migrate answer {n} <option> (MIGRATION-PLAN.md lists them)")
        if q["options"] == [FOLDER_ANSWER]:
            folder_answer_ok(a, project, n); private_folder = os.path.realpath(a)
        elif a not in q["options"]: raise Refusal(f"question {n} is answered '{a}', which is not one of its options; answer it again")
        if a == "pinned": raise Refusal(f"question {n}: a pipeline installed from a pinned release is not supported by apply yet; answer commit")
        if a == "stop the migration": raise Refusal(f"question {n} is answered 'stop the migration'")
        answers[n] = a
    # the repository as the plan saw it
    rc, head = git(repo, "rev-parse", "HEAD")
    if head.strip() != data.get("head"): raise Refusal(f"the repository is not at the commit the plan was made on ({str(data.get('head'))[:12]}); plan again")
    rc, cur = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if cur.strip() != data.get("branch"): raise Refusal(f"the repository is not on the plan's branch {data.get('branch')}; plan again")
    rc, remotes = git(repo, "remote")
    if rc != 0 or not remotes.strip(): raise Refusal("the repository has no remote: push it to a private remote before apply")
    rc, ahead = git(repo, "rev-list", "--count", "@{upstream}..HEAD")
    if rc != 0 or ahead.strip() != "0": raise Refusal("the branch has no upstream, or commits not pushed: push before apply")
    rc, _ = git(repo, "var", "GIT_COMMITTER_IDENT")
    if rc != 0: raise Refusal("git has no name and email for the commit: set user.name and user.email first")
    rc, line = run_tool([os.path.join(ACP_ROOT, "bin", "acp"), "layout", "--check", "--pipeline-dir", "acp", "--code-dir", "app"], repo)
    if rc != 0: raise Refusal(line)
    # the moves, from each entry's kind and answer, never from its display text
    wod = setting(cfg, "WORKORDERS_DIR", "Workspace/Docs/WorkOrders"); bgd = setting(cfg, "BUGS_DIR", "Workspace/Docs/Bugs")
    for top in APPLY_DIRS:
        if os.path.lexists(os.path.join(repo, top)): raise Refusal(f"the repository already has {top} at its top; rename it, commit, and plan again")
    moves, outside = planned_moves(repo, rrel, data, answers, wod, bgd, pr)
    dsts = [d for _, d in moves]
    if len(set(dsts)) != len(dsts): raise Refusal("two entries would move to the same place: " + ", ".join(sorted({d for d in dsts if dsts.count(d) > 1})[:5]))
    for i, (s_, d) in enumerate(moves):   # nothing is ever moved onto something: tracked, ignored, or an empty folder
        there = unmap_path(d, moves[:i])
        if os.path.lexists(os.path.join(repo, there)): raise Refusal(f"`{s_}` would move to `{d}`, where `{there}` already is; apply never moves anything over it: move one aside, commit, and plan again")
    links = crossing_links(project, repo, rrel, moves)
    if links: raise Refusal("these links would point at the wrong place after the moves, and apply does not rewrite links: " + ", ".join(links[:5]) + (f" (and {len(links) - 5} more)" if len(links) > 5 else "") + "; change them to work from both places, commit, and plan again")
    trees = worktrees_moved(repo, moves)
    beside = preflight_outside(project, repo, data, outside, moves, private_folder, answers, cfg)
    rc, out = git(repo, "ls-files", "-z")
    return {"answers": answers, "private_folder": private_folder, "moves": moves, "outside": outside, "worktrees": trees, "beside": beside,
            "open_orders": open_orders(repo, wod, moves), "tracked": set(x for x in out.split("\0") if x)}


def suggested_answers(pl):
    """Each question's suggested answer, as apply would read it; a question that asks for a folder has none."""
    return {q["n"]: q["suggested"] for q in pl.questions if q.get("suggested") is not None and q["options"] != [FOLDER_ANSWER]}


def check_suggestions(pl, cfg, cur, head):
    """Every answer the plan suggests is one apply accepts: one of its question's options, and moves apply's own rules
    (planned_moves) carry out. Kept in the plan, and shown, should one ever not be: a fault in the plan, not the owner's.
    "stop the migration" is the one suggestion that is a stop on purpose (a repository with submodules)."""
    for q in pl.questions:
        s = q.get("suggested")
        if s is None or q["options"] == [FOLDER_ANSWER] or s == "stop the migration": continue
        if s not in q["options"]: pl.suggestion_problems.append(f"question {q['n']}: its suggestion '{s}' is not one of its options")
        elif s == "pinned": pl.suggestion_problems.append(f"question {q['n']}: it suggests 'pinned', which apply does not support")
    wod = setting(cfg, "WORKORDERS_DIR", "Workspace/Docs/WorkOrders"); bgd = setting(cfg, "BUGS_DIR", "Workspace/Docs/Bugs")
    pr = setting(cfg, "PIPELINE_ROOT", ".aicodepipeline")
    answers = suggested_answers(pl)
    rrel = pl.rel(pl.repo)
    data = {"format": 1, "project": pl.project, "repository": pl.rel(pl.repo), "branch": cur, "head": head,   # the plan as write() makes it
            "entries": pl.entries, "questions": pl.questions, "apply_blockers": pl.blockers}
    try: moves, outside = planned_moves(pl.repo, rrel, data, answers, wod, bgd, pr)
    except Refusal as e:
        pl.suggestion_problems.append(str(e)); return None
    # doctor, lightly: a suggestion that leaves an order folder in the code folder is one acp doctor fails (layout in-code)
    for e in pl.entries:
        rel = e["path"] if rrel == "." else os.path.relpath(e["path"], rrel)
        if rel == ".." or rel.startswith("../"): continue
        new = map_path(rel, moves)
        if e["kind"] == "stray-order" and answers.get(e.get("question")) != "import" and (new == "app" or new.startswith("app/")):
            pl.suggestion_problems.append(f"question {e['question']}: the suggestion '{answers.get(e.get('question'))}' leaves `{rel}` in the code folder as `{new}`, which acp doctor fails (a work order inside the code folder)")
    # beside the repository, apply's own step 0 (preflight_outside) decides; only what it says of an answer counts here
    # (a destination taken, a link or a secret is apply's to judge on the day), and a scratch folder stands in for the
    # private folder the owner has not named yet
    if outside:
        pf = tempfile.mkdtemp(prefix="acp-pf.")
        try: preflight_outside(pl.project, pl.repo, data, outside, moves, pf, answers, cfg)
        except Refusal as e:
            if re.match(r"question [0-9]+: ", str(e)) or "which apply does not know" in str(e): pl.suggestion_problems.append(str(e))
        finally: shutil.rmtree(pf, ignore_errors=True)
    return moves


def gitignore_escape(rel):
    return "/" + re.sub(r"([\\\[\]*?!# ])", r"\\\1", rel)


def plan_ignores(pl, moves):
    """The ignored files the moves would make visible: a .gitignore pattern names their old place. Each .gitignore of
    the repository (and its .git/info/exclude, and the lines apply adds itself) is copied to where the moves leave it
    in a scratch repository, and git check-ignore is asked about every ignored file at its new place. One question
    offers the lines that keep them ignored, an anchored line for the highest ignored folder above each (or the file);
    apply adds them, journalled, before it stages. Apply's own check after the moves stays as the backstop."""
    if not moves: return
    repo = pl.repo
    rc, out = git(repo, "ls-files", "-z", "-o", "-i", "--exclude-standard")
    if rc != 0: return
    ignored = [f for f in out.split("\0") if f and f.split("/")[0] != PLAN_DIR]
    moved = [(f, map_path(f, moves)) for f in ignored if map_path(f, moves) != f]
    if not moved: return
    rc, gis = git(repo, "ls-files", "-z", "-c", "-o", "--exclude-standard", "--", ":(glob)**/.gitignore", ".gitignore")
    gis = sorted({g for g in gis.split("\0") if g and os.path.basename(g) == ".gitignore"}) if rc == 0 else []
    tmp = tempfile.mkdtemp(prefix="acp-ignores.")
    try:
        if subprocess.run(["git", "init", "-q", tmp], capture_output=True, env=GIT_ENV).returncode != 0: return
        for g in gis:
            dst = os.path.join(tmp, map_path(g, moves))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(os.path.join(repo, g), "rb") as f: b = f.read()
            if map_path(g, moves) == ".gitignore": b += b"\n*.log\n" + PLAN_DIR.encode() + b"/\n"   # apply's own lines
            with open(dst, "wb") as f: f.write(b)
        ex = os.path.join(repo, ".git", "info", "exclude")
        if os.path.isfile(ex):
            os.makedirs(os.path.join(tmp, ".git", "info"), exist_ok=True)
            with open(ex, "rb") as f, open(os.path.join(tmp, ".git", "info", "exclude"), "wb") as o: o.write(f.read())
        r = subprocess.run(GIT + ["-C", tmp, "check-ignore", "--no-index", "-z", "--stdin"], input="\0".join(n for _, n in moved).encode("utf-8", "surrogateescape"),
                           capture_output=True, env=GIT_ENV)
        still = set(r.stdout.decode("utf-8", "surrogateescape").split("\0"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    visible = [(o, n) for o, n in moved if n not in still]
    if not visible: return
    # one line per highest ignored folder above a file (asked in the repository as it is), or the file itself
    rc, dirs_out = git(repo, "ls-files", "-z", "-o", "-i", "--exclude-standard", "--directory")
    tops = [d.rstrip("/") for d in dirs_out.split("\0") if d.endswith("/")] if rc == 0 else []
    lines = []
    for o, n in visible:
        top = next((d for d in tops if o.startswith(d + "/")), None)
        line = gitignore_escape(map_path(top, moves)) + "/" if top else gitignore_escape(n)
        if line not in lines: lines.append(line)
    q = pl.ask(f"{len(visible)} ignored file(s) would become visible after the moves: a .gitignore pattern names their old place. "
               f"Add these {len(lines)} line(s) to the repository's .gitignore, so they stay ignored at the new place?\n" + "\n".join(lines),
               ["yes", "no"], "yes")
    pl.gitignore_add = {"question": q, "lines": lines, "files": len(visible)}


def planned_moves(repo, rrel, data, answers, wod, bgd, pr):
    """The moves, from each entry's kind and its answer, in order: the entries' own, then the playbooks and the
    loose documents and imported orders after them; and the entries beside the repository or to be deleted. One
    set of rules, read by apply (preflight) and by the plan, which checks its own suggested answers with it. A
    refusal is the one apply gives."""
    moves, later, outside, root_pb = [], [], [], False
    for e in data["entries"]:
        k, path, a = e["kind"], e["path"], answers.get(e.get("question"))
        rel = path if rrel == "." else os.path.relpath(path, rrel)   # repository-relative
        if k == "submodules": continue   # a question only: the submodule folders move with their entries
        if rel == ".." or rel.startswith("../"):   # beside the repository: not this part's to move
            outside.append(dict(e, at=path)); continue
        name = os.path.basename(rel)
        if k == "pipeline":
            if name == "pipeline.config.sh": continue   # the config stays at the root
            if name == "playbooks": root_pb = True
            moves.append((rel, "acp/" + name))
        elif k == "product": moves.append((rel, "app/" + name))
        elif k == "tool-bound":
            if e.get("question") is not None and a != "root": raise Refusal(f"question {e['question']}: `{rel}` is read by tools at the repository root, so it stays there; answer root")
        elif k == "either": moves.append((rel, a + "/" + name))
        elif k == "loose":
            if a == "keep where it is": continue
            if a == "delete": outside.append(dict(e, at=path)); continue   # deletions are not this part's
            home = e["to"]
            if not home.startswith("acp/"): raise Refusal(f"question {e['question']}: `{rel}` has no folder to go to ({home}); answer 'keep where it is' or 'delete'")
            later.append((rel, None, home.rstrip("/") + "/" + name))   # its home is already a place after the moves
        elif k == "stray-order":
            if a == "import":
                m = ORDER.match(name); later.append((rel, os.path.join(wod if m.group(1) == "WO" else bgd, name), None))
        else:
            raise Refusal(f"`{rel}` is planned as {k}, which apply does not know; plan again with this ACP")
    for s_, d in moves:
        if not os.path.lexists(os.path.join(repo, s_)): raise Refusal(f"`{s_}` is no longer there; plan again")
    # moves made after the entries' own: their sources as those moves leave them
    pb = os.path.join(pr, "playbooks") if pr else None
    extra = []
    if pb and os.path.isdir(os.path.join(repo, pb)) and not os.path.islink(os.path.join(repo, pb)):
        if root_pb: raise Refusal(f"both playbooks/ and {pb}/ hold playbooks; merge them into one by hand, commit, and plan again")
        extra.append((map_path(pb, moves), "acp/playbooks"))
    for s_, before, after in later:   # loose documents and imported orders, after the entries' own moves
        if not os.path.lexists(os.path.join(repo, s_)): raise Refusal(f"`{s_}` is no longer there; plan again")
        if before:   # an imported order: its number must be free in the folder it joins, whatever the rest of the name
            m = ORDER.match(os.path.basename(s_)); home = os.path.join(repo, os.path.dirname(before))
            same = [x for x in (listing(home) if os.path.isdir(home) else []) if ORDER.match(x) and ORDER.match(x).group(1, 2) == m.group(1, 2)]
            if same: raise Refusal(f"`{s_}` is {m.group(1)}-{m.group(2)}, and `{os.path.join(os.path.dirname(before), same[0])}` already has that number; answer app, or renumber one, commit, and plan again")
        extra.append((map_path(s_, moves), after or map_path(before, moves)))
    moves += extra
    return moves, outside


def crossing_links(project, repo, rrel, moves):
    """Links inside the repository whose target, read from where they will be, is no longer what it is now (a
    relative link that crosses the edge of a move, or an absolute one into a moved entry). Taken from the backup's
    manifest, which lists every link. Refused, not rewritten."""
    rows = json.load(open(os.path.join(project, PLAN_DIR, "manifest.json")))["entries"]
    rroot = os.path.realpath(repo)
    out = []
    for r in rows:
        if r["type"] != "link": continue
        rel = r["path"] if rrel == "." else os.path.relpath(r["path"], rrel)
        if rel == ".." or rel.startswith("../") or rel.split("/")[0] == ".git" or "/.git/" in "/" + rel + "/": continue
        t = r["target"]
        now = os.path.normpath(t if os.path.isabs(t) else os.path.join(os.path.dirname(os.path.join(rroot, rel)), t))
        if not (now == rroot or now.startswith(rroot + os.sep)): continue   # leads out of the repository: unchanged by any move
        want = os.path.join(rroot, map_path(os.path.relpath(now, rroot), moves)) if now != rroot else rroot
        later = os.path.normpath(t if os.path.isabs(t) else os.path.join(os.path.dirname(os.path.join(rroot, map_path(rel, moves))), t))
        if os.path.normpath(want) != later: out.append(rel)
    return out


def worktrees_moved(repo, moves):
    """The repository's linked worktrees that lie under a move's source, with where they will be. A worktree that is
    locked, or whose folder is missing, refuses: it cannot be repaired."""
    rc, out = git(repo, "worktree", "list", "--porcelain")
    if rc != 0: raise Refusal("git could not list the repository's worktrees")
    rroot, found, cur = os.path.realpath(repo), [], None
    for line in out.splitlines() + [""]:
        if line.startswith("worktree "): cur = {"path": line[9:]}
        elif cur is not None and line.split(" ")[0] in ("locked", "prunable"): cur[line.split(" ")[0]] = True
        elif not line and cur is not None:
            p = os.path.realpath(cur["path"])
            if p != rroot and p.startswith(rroot + os.sep):
                rel = os.path.relpath(p, rroot); new = map_path(rel, moves)
                if new != rel:
                    if cur.get("locked") or cur.get("prunable"): raise Refusal(f"the worktree `{rel}` is locked or its folder is missing; unlock or remove it with git worktree, then plan again")
                    found.append((rel, new))
            cur = None
    return found


def unmap_path(rel, moves):
    """Where a path after the moves was before them: the moves taken back, newest first."""
    for s_, d in reversed(moves):
        if rel == d or rel.startswith(d + "/"): rel = s_ + rel[len(d):]
    return rel


def newly_unignored(repo, pre):
    """Files git now offers to add that it ignored before the moves: a pattern anchored at the old place (/dist, say)
    no longer matches the new one (app/dist). The tree was clean, so any untracked file whose old path was not tracked
    is one of them."""
    rc, out = git(repo, "ls-files", "-o", "--exclude-standard", "-z")
    if rc != 0: raise Refusal("git could not list the untracked files after the moves")
    return [f for f in out.split("\0") if f and unmap_path(f, pre["moves"]) not in pre["tracked"] and f.split("/")[0] != PLAN_DIR]


INSTALL_OWNED = (".claude", "AGENTS.md", "CLAUDE.md", "pipeline.config.sh", ".gitignore", "acp/.aicodepipeline", "acp/playbooks")


def install_owned(repo):
    """What the install writes, as the layout now names it: the fixed paths, and the .gitignore it keeps in the
    work-order and bug folders (read from WORKORDERS_DIR and BUGS_DIR through layout.py, once acp layout has run)."""
    root_names(repo)   # loads layout.py, or refuses
    try: c = _LAYOUT[0].config(repo)
    except _LAYOUT[0].NoLayout as e: raise Refusal(str(e))
    return INSTALL_OWNED + tuple(os.path.join(c[k], ".gitignore") for k in ("WORKORDERS_DIR", "BUGS_DIR"))


def kept_tracked(pre):
    """Every file tracked before, at its place after the moves, that is not the install's to change."""
    under = lambda f, xs: any(f == x or f.startswith(x + "/") for x in xs)
    return sorted(m for m in (map_path(t, pre["moves"]) for t in pre["tracked"]) if not under(m, INSTALL_OWNED))


def force_add_tracked(repo, pre):
    """git add -A leaves out a tracked file that is ignored at its new place (a force-added vendor file, a tracked log
    once *.log is ignored): it would be deleted from git. Each is added by name, as git add -f does."""
    names = [m for m in kept_tracked(pre) if os.path.lexists(os.path.join(repo, m))]
    if not names: return 0, "", ""
    p = subprocess.run(GIT + no_filters(repo) + ["-C", repo, "--literal-pathspecs", "add", "-f", "--pathspec-from-file=-", "--pathspec-file-nul"],   # names, never patterns
                       input="\0".join(names).encode("utf-8", "surrogateescape"), capture_output=True, timeout=600, env=GIT_ENV)
    return p.returncode, os.fsdecode(p.stdout), os.fsdecode(p.stderr).strip()


def staged_problems(repo, pre):
    """Every staged change judged against what apply did: a rename of a planned move, a file the install writes, or
    the edited orders. A new gitlink, a deletion apply did not plan, anything under .acp-migration, and a file that
    was not tracked before (not the install's) are each a problem."""
    rc, out = git(repo, "diff", "--cached", "--raw", "-z", "--no-renames")
    if rc != 0: return ["git could not list the staged changes"]
    under = lambda f, xs: any(f == x or f.startswith(x + "/") for x in xs)
    owned = install_owned(repo)
    srcs = [s_ for s_, _ in pre["moves"]]; dsts = [d for _, d in pre["moves"]]
    orders = [map_path(o["order"], pre["moves"]) for o in pre["open_orders"]]
    bad, parts = [], out.split("\0")
    for i in range(0, len(parts) - 1, 2):
        meta, f = parts[i], parts[i + 1]
        if not meta.startswith(":"): continue
        old_mode, new_mode, status = meta[1:].split(" ")[0], meta[1:].split(" ")[1], meta.split(" ")[-1]
        if f.split("/")[0] == PLAN_DIR: bad.append(f + " (the plan folder)")
        elif new_mode == "160000" and old_mode != "160000": bad.append(f + " (a new gitlink)")
        elif status == "D" and not under(f, srcs + list(owned)): bad.append(f + " (a deletion apply did not plan)")
        elif status == "A" and under(f, owned): pass
        elif status == "A" and under(f, dsts) and unmap_path(f, pre["moves"]) in pre["tracked"]: pass
        elif status == "A": bad.append(f + " (not tracked before, and not the install's)")
        elif status == "M" and not under(f, list(owned) + orders): bad.append(f + " (changed, though apply only moves it)")
    rc, idx = git(repo, "ls-files", "-z")
    have = set(x for x in idx.split("\0") if x) if rc == 0 else set()
    bad += [m + " (tracked before, missing from the commit)" for m in kept_tracked(pre) if m not in have]
    return bad


def map_path(rel, moves):
    """A repository-relative path after the moves, taken in order (a later move's source is where earlier moves left
    it); a path no move covers keeps its name."""
    for s_, d in moves:
        if rel == s_ or rel.startswith(s_ + "/"): rel = d + rel[len(s_):]
    return rel


def open_orders(repo, wod, moves):
    """Each open order (no CLOSEOUT in its folder) with a manifest or declared paths, and those paths as the moves
    leave them. A path no move covers keeps its name: its entry stays where it is."""
    out = []
    base = os.path.join(repo, wod)
    for n in (listing(base) if os.path.isdir(base) else []):
        d = os.path.join(base, n)
        if not ORDER.match(n) or not os.path.isdir(d) or any(re.search(r"(?i)-CLOSEOUT", x) for x in os.listdir(d)): continue
        man, meta = os.path.join(d, ".wo-manifest"), os.path.join(d, ".wo-meta")
        rows, paths = [], None
        if os.path.isfile(man):
            for line in (read_small(man, 1 << 28) or "").split("\n"):
                if not line or line.startswith("#"): continue
                if "\t" not in line: raise Refusal(f"{os.path.relpath(man, repo)} has a line that is not '<hash><tab><path>'; open orders are rewritten line by line, so fix it first")
                rows.append(line.split("\t", 1)[1])
        mt = read_small(meta) or ""
        m = re.search(r"^paths=(.*)$", mt, re.M)
        if m and m.group(1): paths = m.group(1).split(",")
        w = re.search(r"^worktree=(.+)$", mt, re.M)   # wo start's record of the order's worktree
        wt = (w.group(1), map_path(w.group(1), moves)) if w and map_path(w.group(1), moves) != w.group(1) else None
        if not rows and not paths and not wt: continue
        if (paths and re.search(r"^paths_pre_migration=", mt, re.M)) or (wt and re.search(r"^worktree_pre_migration=", mt, re.M)):
            raise Refusal(f"{os.path.relpath(d, repo)} already holds what apply keeps of its old paths (paths_pre_migration= or worktree_pre_migration= in .wo-meta); move that aside first")
        out.append({"order": os.path.relpath(d, repo), "manifest": [(r, map_path(r, moves)) for r in rows],
                    "paths": None if paths is None else [(x, map_path(x, moves)) for x in paths], "worktree": wt})
    return out


def undo(project, repo):
    """Put back every step the journal holds, newest first, each by what is on disk: a step interrupted between its
    act and its mark is put back too, and an edit is undone only where the bytes differ. A step that fails to go back
    does not stop the others. Worktrees are repaired to their old places once every folder is back. The index is never
    touched before the install. Returns what could not be put back."""
    j = read_journal(project)
    left, trees = [], []
    for st in reversed(j["steps"]):
        k = st["kind"]
        try:
            if k == "move":
                if os.path.lexists(os.path.join(repo, st["dst"])) and not os.path.lexists(os.path.join(repo, st["src"])):
                    os.rename(os.path.join(repo, st["dst"]), os.path.join(repo, st["src"]))
                elif os.path.lexists(os.path.join(repo, st["dst"])): left.append(st["dst"])
            elif k == "mkdir":
                try: os.rmdir(os.path.join(repo, st["path"]))
                except FileNotFoundError: pass
                except OSError: left.append(st["path"])   # not empty: something this run did not make is there; it stays
            elif k in ("edit", "layout"):
                p = os.path.join(repo, st["path"]); before = st.get("before")
                if before is None:
                    if os.path.lexists(p): os.unlink(p)   # a file this run made: its name did not exist before
                elif file_bytes(p) != base64.b64decode(before):
                    write_bytes(p, base64.b64decode(before))
            elif k == "worktrees": trees.append(st); continue   # after every folder is back
        except OSError as e: left.append(f"{st.get('dst') or st.get('path')} ({e.strerror})")
        restore_times(repo, st, left)
    for st in trees:
        rc, _, err = git_write(repo, "worktree", "repair", *[old for old, _ in st["trees"]])
        if rc != 0: left.append("worktrees (" + (err.splitlines() or ["repair failed"])[-1] + ")")
        back = lambda r: next((o + r[len(n):] for o, n in st["trees"] if r == n or r.startswith(n + "/")), r)   # a worktree's own .git is back at its old place
        restore_times(repo, dict(st, times={back(r): t for r, t in st.get("times", {}).items()}), left)
    return left


def restore_times(repo, st, left):
    for r, t in st.get("times", {}).items():   # newest first, so each path ends with the time it had at the start
        try:
            if os.path.lexists(os.path.join(repo, r)): os.utime(os.path.join(repo, r), ns=(t, t), follow_symlinks=False)
        except OSError: left.append(r + " (its time)")


def way_back(project, archive):
    """The way back once the backup is the only one: the archive restored by hand, beside the project."""
    return (f"restore by hand: mkdir {shlex.quote(project + '.restored')} && tar -xpf {shlex.quote(archive)} -C {shlex.quote(project + '.restored')}, "
            f"then move {shlex.quote(project)} aside and {shlex.quote(project + '.restored')} into its place")


def move_one(src, dst):
    """One rename, never over anything: preflight found the place free, and it is looked at again just before."""
    if os.path.lexists(dst): raise Refusal(f"{dst} appeared after the checks; apply never moves anything over it")
    os.rename(src, dst)


def write_bytes(p, b):
    with open(p, "wb") as f: f.write(b)


def times_of(repo, paths):
    """The mtime of each path that exists, so a put-back leaves every folder and file as it found it."""
    out = {}
    for r in paths:
        try: out[r] = os.lstat(os.path.join(repo, r)).st_mtime_ns
        except OSError: pass
    return out


def step(project, repo, st, act, touches=()):
    """Journal the step with the times it is about to change, take it, then mark it done."""
    st = dict(st, times=times_of(repo, list(touches)))
    n = journal_step(project, st); act(); journal_done(project, n)


def apply(project, repo):
    data = read_plan(project)   # holds the plan folder's lock to the end of the run
    pd = os.path.join(project, PLAN_DIR)
    for f in ("journal.jsonl", "applied.json"):
        if os.path.lexists(os.path.join(pd, f)):
            try: archive = json.load(open(os.path.join(pd, "applied.json")))["backup_archive"]
            except (OSError, ValueError, KeyError, TypeError): archive = None
            raise Refusal(f"an apply has run here ({PLAN_DIR}/{f}); " + (way_back(project, archive) if archive else "its record names no backup: restore the project from your own copy"))
    pre = preflight(project, repo, data)
    rec = json.load(open(os.path.join(pd, "backup.json")))
    write_applied(project, "started", {"format": 1, "plan_id": data["plan_id"], "head_before": data["head"],
                  "backup_archive": rec["archive"], "backup_archive_sha256": rec["archive_sha256"], "backup_manifest_sha256": rec["manifest_sha256"]})
    put(pd, "journal.jsonl", json.dumps({"format": 1, "plan_id": data["plan_id"], "started": datetime.now().isoformat(timespec="seconds")}, sort_keys=True) + "\n")
    JOURNAL_N.pop(journal_path(project), None)
    rp = lambda r: os.path.join(repo, r)
    try:
        for s_, d in pre["moves"]:
            par = os.path.dirname(d)
            for i in range(1, len(par.split("/")) + 1):   # the folders above the destination, each journalled
                q = "/".join(par.split("/")[:i])
                if q and not os.path.lexists(rp(q)):
                    step(project, repo, {"kind": "mkdir", "path": q, "undo": True}, lambda q=q: os.mkdir(rp(q)), [os.path.dirname(q) or "."])
            step(project, repo, {"kind": "move", "src": s_, "dst": d, "undo": True}, lambda s_=s_, d=d: move_one(rp(s_), rp(d)),
                 [os.path.dirname(s_) or ".", os.path.dirname(d) or "."])
        if pre["worktrees"]:   # git's record of each moved worktree follows it; put back by repairing to the old places
            touches = []
            for old, new in pre["worktrees"]:
                g = (read_small(os.path.join(repo, new, ".git")) or "").strip()
                touches.append(new + "/.git")   # the worktree's own link back, which repair may rewrite
                if g.startswith("gitdir: "):
                    gd = os.path.relpath(g[8:], repo); touches += [gd + "/gitdir", gd]
            def repair():
                rc, _, err = git_write(repo, "worktree", "repair", *[new for _, new in pre["worktrees"]])
                if rc != 0: raise Refusal("git worktree repair failed: " + (err.splitlines() or ["?"])[-1])
            step(project, repo, {"kind": "worktrees", "trees": pre["worktrees"], "undo": True}, repair, touches)
        gi = file_bytes(rp(".gitignore"))
        lines = (gi or b"").decode("utf-8", "surrogateescape").split("\n")
        add = [x for x in ("*.log", PLAN_DIR + "/") if x not in lines]
        ga = data.get("gitignore_add") or {}
        if ga and pre["answers"].get(ga.get("question")) == "yes":   # the lines the plan offered, as offered
            add += [x for x in ga.get("lines", []) if x not in lines and x not in add]
        if add:
            text = (gi or b"").decode("utf-8", "surrogateescape")
            new = (text + ("" if not text or text.endswith("\n") else "\n") + "\n".join(add) + "\n").encode("utf-8", "surrogateescape")
            step(project, repo, {"kind": "edit", "path": ".gitignore", "before": b64(gi), "undo": True}, lambda: write_bytes(rp(".gitignore"), new), [".gitignore", "."])
        loose_ends = newly_unignored(repo, pre)
        if loose_ends:
            raise Refusal("after the moves git no longer ignores " + ", ".join(loose_ends[:5]) + (f" (and {len(loose_ends) - 5} more)" if len(loose_ends) > 5 else "")
                          + ": a .gitignore pattern names their old place. Add one for the new place (app/…), commit, take a new backup, and plan again")
        for o in pre["open_orders"]:
            od = map_path(o["order"], pre["moves"])
            if o["manifest"]:
                man = rp(od + "/.wo-manifest"); before = file_bytes(man)   # the old bytes stay in the journal and the backup, not beside it
                text = before.decode("utf-8", "surrogateescape"); m = dict(o["manifest"])
                out = "\n".join(l if (not l or l.startswith("#")) else l.split("\t", 1)[0] + "\t" + m.get(l.split("\t", 1)[1], l.split("\t", 1)[1]) for l in text.split("\n"))
                step(project, repo, {"kind": "edit", "path": od + "/.wo-manifest", "before": b64(before), "undo": True},
                     lambda man=man, out=out: write_bytes(man, out.encode("utf-8", "surrogateescape")), [od + "/.wo-manifest", od])
            if o["paths"] or o["worktree"]:
                meta = rp(od + "/.wo-meta"); before = file_bytes(meta); text = before.decode("utf-8", "surrogateescape")
                text = text + ("" if text.endswith("\n") else "\n")
                if o["paths"]:
                    old = ",".join(x for x, _ in o["paths"]); new_ = ",".join(y for _, y in o["paths"])
                    text = re.sub(r"^paths=.*$", lambda _m: "paths=" + new_, text, count=1, flags=re.M) + "paths_pre_migration=" + old + "\n"
                if o["worktree"]:
                    text = re.sub(r"^worktree=.*$", lambda _m: "worktree=" + o["worktree"][1], text, count=1, flags=re.M) + "worktree_pre_migration=" + o["worktree"][0] + "\n"
                step(project, repo, {"kind": "edit", "path": od + "/.wo-meta", "before": b64(before), "undo": True},
                     lambda meta=meta, text=text: write_bytes(meta, text.encode("utf-8", "surrogateescape")), [od + "/.wo-meta", od])
        cfgb = file_bytes(rp("pipeline.config.sh"))
        n = journal_step(project, {"kind": "layout", "path": "pipeline.config.sh", "before": b64(cfgb), "undo": True, "times": times_of(repo, ["pipeline.config.sh", "."])})
        rc, line = run_tool([os.path.join(ACP_ROOT, "bin", "acp"), "layout", "--pipeline-dir", "acp", "--code-dir", "app"], repo)
        if rc != 0: raise Refusal("acp layout refused after its check passed: " + line)
        journal_done(project, n)
    except BaseException as e:
        why = str(e) if isinstance(e, Refusal) else f"{e.__class__.__name__}: {e}"
        left = undo(project, repo)
        if left:   # the journal stays where it is: the record says how far it got, and the backup is the way back
            write_applied(project, "stopped, not all put back")
            raise Refusal(f"apply stopped ({why}) and could not put back {', '.join(left[:5])}; nothing was committed; {way_back(project, rec['archive'])}")
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        for f in ("journal.jsonl", "applied.json"):   # set aside, never removed: a new apply may run once the cause is fixed
            os.rename(os.path.join(pd, f), os.path.join(pd, f.replace(".", "-put-back-" + stamp + ".")))
        raise Refusal(f"apply stopped ({why}); every move was put back and nothing was committed; fix that, then run apply again")
    # from here the backup is the way back: any stop, an interruption included, says where and how
    back, where = way_back(project, rec["archive"]), "install"
    try:
        n = journal_step(project, {"kind": "install", "undo": False})
        rc, line = run_tool([os.path.join(ACP_ROOT, "bin", "install.sh"), repo, "--pipeline-dir", "acp", "--code-dir", "app"], repo)
        if rc != 0: raise Refusal(f"the moves are done and the install failed ({line})")
        journal_done(project, n); where = "staging"
        rc, _, err = git_write(repo, "add", "-A", "--", ".")   # .acp-migration/ is ignored by now; staged_problems refuses it if not
        if rc == 0: rc, _, err = force_add_tracked(repo, pre)
        bad = [err or "git add failed"] if rc != 0 else staged_problems(repo, pre)
        if bad: raise Refusal(f"staging the restructure found what apply did not make: {', '.join(bad[:5])}; nothing was committed")
        where = "commit"
        n = journal_step(project, {"kind": "commit", "undo": False})
        rc, _, err = git_write(repo, "commit", "-q", "-m", MSG)
        if rc != 0: raise Refusal(f"the commit failed ({err.splitlines()[-1] if err else rc})")
        rc, sha = git(repo, "rev-parse", "HEAD"); sha = sha.strip()
        journal_done(project, n, sha=sha)
    except BaseException as e:
        write_applied(project, f"stopped at {where}")
        raise Refusal((str(e) if isinstance(e, Refusal) else f"apply stopped at {where} ({e.__class__.__name__}: {e})") + f"; {back}")
    pre["result"] = apply_outside(project, repo, data, pre, sha, rec)   # beside the repository; it writes its own stops
    write_applied(project, "done", dict(pre["result"], commit=sha))
    return pre, sha


# --- apply beside the repository: after the move commit -------------------------------------------------------------

MSG2 = "Import work orders and the migration record"
RE_PLAN = "the plan was made before apply could check what it moves and deletes; run acp migrate plan --replace (its answers are lost; answer them again)"


def layout_config(repo):
    """The folders as the layout names them now, read through layout.py (the one home of them)."""
    root_names(repo)   # loads layout.py, or refuses
    try: return _LAYOUT[0].config(repo)
    except _LAYOUT[0].NoLayout as e: raise Refusal(str(e))


def rec_path(rel, folder=False):
    """A path inside the migration record: every folder named like an order (the last part too when it is a folder) is
    named copy-of-<it>, so the layout rule never counts the record's copy as a second place of that order, and no
    driver takes it for one."""
    parts = rel.split("/")
    return "/".join("copy-of-" + x if ORDER.match(x) and (i < len(parts) - 1 or folder) else x for i, x in enumerate(parts))


def fps_of(p):
    """(fingerprints, unread) of a folder, or of one file under its own name."""
    if os.path.isdir(p) and not os.path.islink(p): return digest(p)
    return {os.path.basename(p): fingerprint(p, os.lstat(p))}, []


def same_copy(src, dst, rename=lambda k: k, skip=()):
    """True when dst holds what src holds, entry for entry (names through rename; what skip names at src's top left
    out), every entry read."""
    (a, ea), (b, eb) = fps_of(src), fps_of(dst)
    if not (os.path.isdir(src) and not os.path.islink(src)): a, b = list(a.values()), list(b.values())
    else: a = {rename(k): v for k, v in a.items() if k.split(os.sep)[0] not in skip}
    return not ea and not eb and a == b


def not_copyable(src):
    """Why src cannot be copied as it is, or None: a folder not read whole, a file not read, a pipe, socket or device, or
    a link pointing outside src (a copy would point somewhere else)."""
    fps, unread = fps_of(src)
    if unread: return f"{unread[0]} could not be read"
    for k, v in sorted(fps.items()):
        if v[0] == "unreadable" or v[0].startswith("special"): return f"{k} is {v[0].replace('special:', 'a ')}, which apply does not copy"
    if os.path.islink(src): return "it is a link"
    for k, v in sorted(fps.items()):
        if v[0] == "link":
            t = os.path.normpath(os.path.join(os.path.dirname(os.path.join(src, k)), v[1]))
            if os.path.isabs(v[1]) or not t.startswith(src + os.sep): return f"{k} is a link to {v[1]}, outside it"
    return None


def below_link(path, top):
    """True when a folder between top and path is a link."""
    rel = os.path.relpath(os.path.dirname(path), top)
    cur = top
    for part in ([] if rel == "." else rel.split(os.sep)):
        cur = os.path.join(cur, part)
        if os.path.islink(cur): return True
    return False


def remove_tree(p, left):
    """Remove p, never following a link; carries on past an error, adding what stayed to left."""
    try:
        if not os.path.isdir(p) or os.path.islink(p):
            if os.path.lexists(p): os.unlink(p)
            return
    except OSError as e: left.append(f"{p} ({e.strerror})"); return
    for d, dirs, files in os.walk(p, topdown=False):
        for n in files + [x for x in dirs if os.path.islink(os.path.join(d, x))]:
            try: os.unlink(os.path.join(d, n))
            except OSError as e: left.append(f"{os.path.join(d, n)} ({e.strerror})")
        for n in dirs:
            if not os.path.islink(os.path.join(d, n)):
                try: os.rmdir(os.path.join(d, n))
                except OSError as e: left.append(f"{os.path.join(d, n)} ({e.strerror})")
    try: os.rmdir(p)
    except OSError as e: left.append(f"{p} ({e.strerror})")


_FAILS, _MADE_DIRS = [], set()


def fail_points():
    """{label: n} from ACP_TEST_FAIL ("<label>:<n>[,<label>:<n>...]"); a value not of that form is warned about once and
    taken as unset."""
    spec, out = os.environ.get("ACP_TEST_FAIL", ""), {}
    for part in [x for x in spec.split(",") if x]:
        m = re.fullmatch(r"([a-z]+):([1-9][0-9]*)", part)
        if not m:
            if "warned" not in _FAILS: _FAILS.append("warned"); print(f"acp migrate: ACP_TEST_FAIL={spec!r} is not <point>:<n>[,...]; ignored", file=sys.stderr)
            return {}
        out[m.group(1)] = int(m.group(2))
    return out


def fail_point(label):
    """A failure planted for the eval, never set otherwise: ACP_TEST_FAIL=<label>:<n> acts the n-th time apply reaches
    this point. copy, keep (a merge's saved copy), replace and putback (a merge putting back a replaced file) raise an
    OSError there; leak returns True, and the record then holds a path of this machine; signal raises KeyboardInterrupt,
    as an interrupt would; occupy returns True, and the caller then puts something where the copy goes. Unset, nothing
    happens."""
    n = fail_points().get(label)
    if n is None: return False
    _FAILS.append(label)
    if _FAILS.count(label) != n: return False
    if label == "signal": raise KeyboardInterrupt()
    if label in ("copy", "keep", "replace", "putback"): raise OSError(errno.ENOSPC if label == "putback" else errno.EIO, f"a failure planted at {label} {n}")
    return True


def remove_made(made, keep, left):
    """Take back what a failed step made, newest first: a folder this step created only once it is empty, anything else
    whole; never a path in keep (a saved copy that is now the only one) nor a folder holding one."""
    for p in reversed(made):
        if any(p == k or k.startswith(p + os.sep) for k in keep): continue
        if p in _MADE_DIRS:
            try: os.rmdir(p)
            except FileNotFoundError: pass
            except OSError: pass   # not empty: something kept is in it, and it stays
        else: remove_tree(p, left)


def copy_in(src, dst, made, top, skip=None, point="copy"):
    """Copy src to dst, never over anything nor through a link below top; links are copied as links; skip names what a
    folder's copy leaves out at its top. Every folder made for it, and dst, is in made before a byte is written, so a
    failed copy removes only what it made."""
    if fail_point("occupy"): write_bytes(dst, b"in the way\n")
    if os.path.lexists(dst) or below_link(dst, top): raise Refusal(f"{dst} appeared after the checks, or lies below a link; apply never copies over anything")
    new, q = [], os.path.dirname(dst)
    while not os.path.lexists(q): new.append(q); q = os.path.dirname(q)
    for q in reversed(new): os.mkdir(q); made.append(q); _MADE_DIRS.add(q)
    made.append(dst)
    fail_point(point)
    if os.path.isdir(src) and not os.path.islink(src):
        shutil.copytree(src, dst, symlinks=True, ignore=(lambda d, names: [n for n in names if d == src and n in skip]) if skip else None)
    else: shutil.copy2(src, dst, follow_symlinks=False)


def is_open_order(d):
    return not any(re.search(r"(?i)-CLOSEOUT", x) for x in os.listdir(d))


def map_order_paths(d, moves, keep, made):
    """An imported open order's manifest, declared paths and worktree, mapped as apply maps the open orders already in
    the repository. The old manifest is kept in the migration record (keep), not in the order's folder, where the
    layout rule allows only the order's own files; the old paths stay in .wo-meta (paths_pre_migration=,
    worktree_pre_migration=)."""
    man, meta = os.path.join(d, ".wo-manifest"), os.path.join(d, ".wo-meta")
    if os.path.isfile(man):
        before = file_bytes(man); text = before.decode("utf-8", "surrogateescape")
        out = "\n".join(l if (not l or l.startswith("#")) else l.split("\t", 1)[0] + "\t" + map_path(l.split("\t", 1)[1], moves) for l in text.split("\n"))
        if out != text:
            if os.path.lexists(keep): raise Refusal(f"{keep} is already there")
            os.makedirs(os.path.dirname(keep), exist_ok=True); made.append(keep); write_bytes(keep, before)
            write_bytes(man, out.encode("utf-8", "surrogateescape"))
    if os.path.isfile(meta):
        text = file_bytes(meta).decode("utf-8", "surrogateescape"); t = text + ("" if text.endswith("\n") else "\n")
        m = re.search(r"^paths=(.*)$", t, re.M)
        if m and m.group(1):
            new = ",".join(map_path(x, moves) for x in m.group(1).split(","))
            if new != m.group(1): t = re.sub(r"^paths=.*$", lambda _m: "paths=" + new, t, count=1, flags=re.M) + "paths_pre_migration=" + m.group(1) + "\n"
        w = re.search(r"^worktree=(.+)$", t, re.M)
        if w and map_path(w.group(1), moves) != w.group(1):
            t = re.sub(r"^worktree=.*$", lambda _m: "worktree=" + map_path(w.group(1), moves), t, count=1, flags=re.M) + "worktree_pre_migration=" + w.group(1) + "\n"
        if t != text + ("" if text.endswith("\n") else "\n"): write_bytes(meta, t.encode("utf-8", "surrogateescape"))


def import_marks(d):
    """What an open order to import already holds of old paths, or of a line apply could not map; None when nothing."""
    man, meta = os.path.join(d, ".wo-manifest"), os.path.join(d, ".wo-meta")
    if os.path.lexists(man + ".pre-migration"): return ".wo-manifest.pre-migration"
    if os.path.isfile(man) and any(l and not l.startswith("#") and "\t" not in l for l in (read_small(man, 1 << 28) or "").split("\n")):
        return "a .wo-manifest line that is not '<hash><tab><path>'"
    m = re.search(r"^(paths|worktree)_pre_migration=", read_small(meta) or "", re.M)
    return m.group(0)[:-1] if m else None


def preflight_outside(project, repo, data, outside, moves, private_folder, answers, cfg):
    """Step 0 beside the repository, before anything moves: every entry beside it, and every deletion, resolved from its
    kind and answer to one action; each digest re-taken; each destination free and below no link; what the second
    commit would add read for secrets; every branch to delete still at the tip the owner answered about. One refusal
    line each; returns what apply_outside carries out."""
    wod, bgd = setting(cfg, "WORKORDERS_DIR", "Workspace/Docs/WorkOrders"), setting(cfg, "BUGS_DIR", "Workspace/Docs/Bugs")
    ws, td = setting(cfg, "WORKSPACE_DIR", "Workspace"), setting(cfg, "TESTING_DIR", "Workspace/Testing")
    if ws is None or td is None: raise Refusal("WORKSPACE_DIR or TESTING_DIR in pipeline.config.sh is not a plain folder inside the repository; apply cannot place what lies beside it")
    post = {"WORKORDERS_DIR": map_path(wod, moves), "BUGS_DIR": map_path(bgd, moves), "TESTING_DIR": map_path(td, moves), "WORKSPACE_DIR": map_path(ws, moves)}
    rec, logs = post["WORKSPACE_DIR"] + "/Migration/" + date.today().isoformat(), post["TESTING_DIR"] + "/logs"
    acts, blobs = [], []
    order_dir = lambda oid: post["WORKORDERS_DIR"] if oid.startswith("WO-") else post["BUGS_DIR"]
    def numbers(folder):   # (prefix, number) of every order folder in a configured folder, before the moves
        d = os.path.join(repo, unmap_path(folder, moves))
        return {(m.group(1), int(m.group(2))) for n in (listing(d) if os.path.isdir(d) else []) for m in [ORDER.match(n)] if m}
    taken = numbers(post["WORKORDERS_DIR"]) | numbers(post["BUGS_DIR"])
    for e in outside:
        k, a, at = e["kind"], answers.get(e.get("question")), e["at"]
        src = os.path.join(project, at)
        act = lambda do, where=None, dst=None, **kw: acts.append(dict(dict(e=e, do=do, src=src, rel=at, where=where, dst=dst, commit=False,
                                                                           in_repo=within(src, repo)), **kw))
        if a in ("keep beside the project", "keep where it is"): continue
        want = (e.get("digest") or {}).get("outside" if k in ("outside-order-identical", "outside-order-contained", "outside-order-differs") else "self")
        if want is None: raise Refusal(RE_PLAN)
        if not os.path.lexists(src): raise Refusal(f"`{at}` is no longer there; plan again")
        if self_digest(src) != want: raise Refusal(f"`{at}` has changed since the plan; apply acts only on what the owner answered about: plan again")
        home = (lambda h: map_path(h, moves))
        if k == "outside-order-only":
            if a == "import":
                m = ORDER.match(os.path.basename(src)); num = (m.group(1), int(m.group(2)))
                if num in taken: raise Refusal(f"`{at}` is {e['id']}, and the repository already has an order of that number; answer retire, or renumber one, and plan again")
                taken.add(num); act("copy", "repo", order_dir(e["id"]) + "/" + os.path.basename(src), commit=True, open=is_open_order(src))
            elif a == "retire": act("copy", "repo", rec + "/retired/" + rec_path(at, folder=True), commit=True, retired=True)
            elif a == "private folder": act("move", "pf", at)
            else: raise Refusal(f"question {e['question']} is answered '{a}', which apply does not know for {k}")
        elif k == "outside-order-placeholder":
            if a == "adopt as " + e.get("adopt_as", ""):
                new, old = e["adopt_as"], e["id"]; m = ORDER.match(new); num = (m.group(1), int(m.group(2)))
                if num in taken: raise Refusal(f"`{at}` would be adopted as {new}, which the repository or another entry already has; plan again")
                taken.add(num)
                names = os.listdir(src)
                renamed = [new + n[len(old):] if n.upper().startswith(old + "-") else n for n in names]
                if len(set(x.lower() for x in renamed)) != len(names): raise Refusal(f"`{at}`: two of its files would have the same name once {old} becomes {new}; rename one by hand and plan again")
                act("copy", "repo", order_dir(new) + "/" + new + os.path.basename(src)[len(old):], commit=True, open=is_open_order(src), old=old, new=new)
            elif a == "retire": act("copy", "repo", rec + "/retired/" + rec_path(at, folder=True), commit=True, retired=True)
            elif a == "private folder": act("move", "pf", at)
            else: raise Refusal(f"question {e['question']} is answered '{a}', which apply does not know for {k}")
        elif k in ("outside-order-identical", "outside-order-contained"):
            h = os.path.join(repo, e.get("home") or "")
            if not e.get("home") or not os.path.isdir(h) or self_digest(h) != e["digest"]["repository"]:
                raise Refusal(f"`{at}`: the repository's copy of {e['id']} is not as the plan saw it; plan again")
            act("delete")
        elif k == "outside-order-differs":
            if a == "file by file": raise Refusal(f"question {e['question']}: apply does not merge `{at}` file by file; merge it by hand, commit, and plan again")
            if a == "private folder": act("move", "pf", at); continue
            h = os.path.join(repo, e.get("home") or "")
            if not e.get("home") or not os.path.isdir(h) or self_digest(h) != e["digest"]["repository"]:
                raise Refusal(f"`{at}`: the repository's copy of {e['id']} is not as the plan saw it; plan again")
            if e.get("unread"): raise Refusal(f"`{at}`: a copy of {e['id']} could not be read whole; merge it by hand and plan again")
            meta = [d["file"] for d in e["differences"] if d["outside"] and d["repository"] and d["file"] in (".wo-manifest", ".wo-meta")]
            if meta and is_open_order(h): raise Refusal(f"`{at}`: {meta[0]} of the open order {e['id']} differs between the copies, and apply maps that file; answer repository, or merge by hand")
            act("merge", "repo", home(e["home"]), commit=True, wins=a)
        elif k == "kb-snapshot":
            if e.get("question") is None:
                if not blobs: blobs.append(reachable_blobs(repo))
                if not in_history(repo, src, blobs[0]): raise Refusal(f"`{at}` holds a file that is no longer in the repository's history; plan again")
                act("delete", snapshot=True)
            elif a == "logs": act("move", "logs", at)
            elif a == "private folder": act("move", "pf", at)
            elif a == "delete": act("delete")
            else: raise Refusal(f"question {e['question']} is answered '{a}', which apply does not know for {k}")
        elif k in ("order-note", "order-artifact", "order-private", "order-ambiguous") and a not in ("logs", "private folder", "delete"):
            if k == "order-ambiguous":
                pick = a if a in (e.get("homes") or {}) else next((i for i in (e.get("homes") or {}) if a in ("work order", "bug") and i.startswith(("WO-" if a == "work order" else "BUG-"))), None)
                if pick is None: raise Refusal(f"question {e['question']}: `{at}` is answered '{a}', and the repository has no such order; answer again")
                h, name = e["homes"][pick], os.path.basename(src)
                fa = None if os.path.isdir(src) or not name.lower().endswith(".md") else "NOTE"
            else:
                if k == "order-private" and a != "artifacts": raise Refusal(f"question {e['question']} is answered '{a}', which apply does not know for {k}")
                h, fa = e.get("home"), e.get("file_as")
                if not h or not fa: raise Refusal(RE_PLAN)
            if not os.path.isdir(os.path.join(repo, h)): raise Refusal(f"`{at}`: its order's folder {h} is not there; plan again")
            act("copy", "repo", home(h), file_as=fa, order=pick if k == "order-ambiguous" else e["id"], commit=None)
        elif k == "order-duplicate":
            same_as = os.path.join(project, e.get("same_as") or "")
            if not e.get("same_as") or not os.path.isfile(same_as) or fingerprint(same_as, os.lstat(same_as))[1] != fps_of(src)[0][os.path.basename(src)][1]:
                raise Refusal(f"`{at}`: the order's own copy of it is not there as the plan saw it; plan again")
            act("delete")
        elif k == "order-placeholder" and a == "adopt as " + e.get("adopt_as", ""):
            if os.path.isdir(src) or not src.lower().endswith(".md"): raise Refusal(f"question {e['question']}: only a note (.md) can be adopted as an order; answer logs, private folder or delete")
            m = ORDER.match(e["adopt_as"]); num = (m.group(1), int(m.group(2)))
            if num in taken: raise Refusal(f"`{at}` would be adopted as {e['adopt_as']}, which the repository or another entry already has; plan again")
            taken.add(num); act("adopt", new=e["adopt_as"], commit=True)
        elif k in ("order-clash", "order-missing", "order-placeholder", "order-private", "order-ambiguous", "private-residue", "unknown") and a in ("logs", "private folder", "delete"):
            act("move", "logs" if a == "logs" else "pf", at) if a != "delete" else act("delete")
        elif k == "unknown" and a in ("app", "acp"): act("copy", "repo", a + "/" + at, commit=True)
        elif k in ("second-acp", "other-repo") and a == "remove":
            u = unique_work(src)
            if u: raise Refusal(f"`{at}` holds work nothing else has ({'; '.join(u)}); answer keep beside the project, or clear it, and plan again")
            act("delete", repo_=True)
        elif k == "private": act("move", "pf", at)
        elif k == "residue": act("move", "logs", at) if a == "keep" else act("delete")
        elif k == "loose" and a == "delete": act("delete")
        elif k == "loose" and a == "yes":
            if not e["to"].startswith("acp/"): raise Refusal(f"question {e['question']}: `{at}` has no folder to go to ({e['to']}); answer 'keep where it is' or 'delete'")
            act("copy", "repo", e["to"].rstrip("/") + "/" + os.path.basename(src), commit=True)
        else:
            raise Refusal(f"`{at}` is planned as {k} and answered '{a}', which apply does not know; plan again with this ACP")
    for x in list(acts):   # what each copy leaves out of the commit, and where that goes instead
        x["want"] = x.get("want") or x["e"]["digest"].get("outside") or x["e"]["digest"].get("self")
        art = os.path.join(x["src"], "artifacts")
        if x.get("retired") and os.path.isdir(art) and not os.path.islink(art):   # an order's working files are never committed
            x["skip"] = ("artifacts",)
            acts.append(dict(x, do="move", where="pf" if private_folder else "logs", src=art, rel=x["rel"] + "/artifacts", dst=x["rel"] + "/artifacts",
                             commit=False, retired=False, skip=(), sub=True, want=self_digest(art)))
        if x["do"] == "merge":   # each file the answer does not keep in the order: kept in the record, unless private or working
            x["lose"] = []
            for d in x["e"]["differences"]:
                if not (d["outside"] and d["repository"]): continue
                lose = os.path.join(repo, x["e"]["home"], d["file"]) if x["wins"] == "outside" else os.path.join(x["src"], d["file"])
                lrel = os.path.relpath(lose, project)
                if d["file"].split("/")[0] == "artifacts": to = "pf" if private_folder else "logs"
                else:
                    hit = secret_in(lose, {os.path.basename(lose): fingerprint(lose, os.lstat(lose))})
                    to = "pf" if hit and hit[1] != "binary" else "kept"
                    if to == "pf" and not private_folder:
                        raise Refusal(f"`{lrel}` may hold something private ({hit[0]}), and the merge would keep it in the record; answer the private folder question, or move it out by hand, and plan again")
                x["lose"].append({"file": d["file"], "to": to, "rel": lrel})
    # each action's destination, and what every destination must be
    if any(x["where"] == "pf" or any(l["to"] == "pf" for l in x.get("lose", [])) for x in acts) and not private_folder:
        raise Refusal("the private folder question has no answer")
    notes = {}
    for x in acts:
        if x["do"] == "copy" and x.get("file_as") is not None:   # an order item: its place in the order's folder
            if x["file_as"] == "NOTE":   # an ambiguous note, numbered now as the plan numbers notes
                folder = os.path.join(repo, unmap_path(x["dst"], moves)); have = {n.lower() for n in os.listdir(folder)} | notes.setdefault(x["dst"], set())
                kind = next((kk for rx, kk in NOTE_KIND if rx.search(os.path.basename(x["src"]))), "NOTES"); i = 1
                while f"{x['order']}-{kind}-{i}.md".lower() in have: i += 1
                x["file_as"] = f"{x['order']}-{kind}-{i}.md"
            elif x["file_as"] is None: x["file_as"] = os.path.join("artifacts", x["rel"])
            notes.setdefault(x["dst"], set()).add(x["file_as"].lower())
            x["dst"] = x["dst"] + "/" + x["file_as"]
            x["ignored"] = x["file_as"].startswith("artifacts/")
            x["commit"] = not x["ignored"]
        if x["where"] == "repo":
            pre_ = unmap_path(x["dst"], moves) if x["do"] != "merge" else None
            if pre_ is not None and (os.path.lexists(os.path.join(repo, pre_)) or below_link(os.path.join(repo, pre_), repo)):
                raise Refusal(f"`{x['dst']}` is already there, or lies below a link; apply never copies over anything: move it aside, commit, and plan again")
            if x["do"] == "copy" and x["dst"].startswith(rec + "/"):
                if os.path.lexists(os.path.join(repo, unmap_path(rec, moves))): raise Refusal(f"`{rec}` is already there: a migration was recorded today; move it aside, commit, and plan again")
        elif x["where"] == "pf":
            d = os.path.join(private_folder, x["dst"])
            if os.path.lexists(d) or below_link(d, private_folder): raise Refusal(f"{d} is already there, or lies below a link; apply never moves anything over it")
            if within(private_folder, x["src"]): raise Refusal(f"the private folder is inside `{x['rel']}`, which moves into it")
        elif x["where"] == "logs":
            d = os.path.join(repo, unmap_path(logs, moves), x["dst"])
            if os.path.lexists(d) or below_link(d, repo): raise Refusal(f"`{logs}/{x['dst']}` is already there, or lies below a link; apply never moves anything over it")
        if x["do"] in ("copy", "move", "adopt", "merge"):
            why = not_copyable(x["src"])
            if why: raise Refusal(f"`{x['rel']}` cannot be carried as it is: {why}; move it by hand, or answer delete, and plan again")
        for l in x.get("lose", []):   # a losing version that goes to the private folder or the logs: its place is free
            d = os.path.join(private_folder, l["rel"]) if l["to"] == "pf" else os.path.join(repo, unmap_path(logs, moves), l["rel"]) if l["to"] == "logs" else None
            if d and (os.path.lexists(d) or below_link(d, private_folder if l["to"] == "pf" else repo)): raise Refusal(f"{d} is already there, or lies below a link; apply never moves anything over it")
        if x["commit"]:   # nothing private enters the second commit
            found = secret_in(x["src"], {k: v for k, v in fps_of(x["src"])[0].items() if k.split(os.sep)[0] not in x.get("skip", ())})
            if found and found[1] != "binary":
                raise Refusal(f"`{x['rel']}` may hold something private ({found[0]}), and the answer would commit it; answer private folder where offered, or move it out by hand and plan again")
        if x.get("open") and import_marks(x["src"]): raise Refusal(f"`{x['rel']}` already holds {import_marks(x['src'])}; move that aside first")
    ends = sorted(os.path.normpath(os.path.join(repo if x["where"] in ("repo", "logs") else private_folder, (logs + "/" if x["where"] == "logs" else "") + x["dst"]))
                  for x in acts if x["dst"] and x["do"] != "merge")
    for i in range(1, len(ends)):
        if ends[i] == ends[i - 1] or ends[i].startswith(ends[i - 1] + os.sep): raise Refusal(f"two entries would go to the same place: {ends[i]}")
    if any(x["where"] == "logs" or any(l["to"] == "logs" for l in x.get("lose", [])) for x in acts):
        gi = os.path.join(repo, unmap_path(logs, moves), ".gitignore")
        if os.path.islink(os.path.dirname(gi)) or os.path.islink(gi) or (os.path.lexists(gi) and file_bytes(gi) != b"*\n"):
            raise Refusal(f"`{logs}/.gitignore` is a link or holds something other than '*', and apply keeps that folder out of git with it; fix it by hand, commit, and plan again")
    if any(x.get("ignored") for x in acts):   # the orders folders' .gitignore keeps artifacts/ out of git: its own writer judges it
        rc, line = run_tool([sys.executable, os.path.join(ACP_ROOT, "core", "hooks", "order-ignore.py")] + [os.path.join(repo, x) for x in (wod, bgd)] + ["--dry-run"], repo)
        if rc != 0: raise Refusal(line)
    branches = []
    for q in data["questions"]:
        if not str(q.get("about", "")).startswith("branch ") or answers.get(q["n"]) != "delete": continue
        b, tip = q.get("branch"), q.get("tip")
        if not b or not tip: raise Refusal(RE_PLAN)
        rc, now = git(repo, "rev-parse", "--verify", "-q", "refs/heads/" + b)
        if now.strip() != tip: raise Refusal(f"branch `{b}` is not at the commit the owner answered about ({tip[:12]}); plan again")
        if b in worktree_branches(repo): raise Refusal(f"question {q['n']}: branch `{b}` is checked out in a worktree, and git deletes no such branch; answer keep, or remove the worktree and plan again")
        branches.append({"branch": b, "tip": tip, "q": q["n"]})
    return {"acts": acts, "branches": branches, "post": post, "rec": rec, "logs": logs, "pf": private_folder}


def path_forms(*paths):
    """Every way a path of this machine can be written: as typed, normalised (.. and a trailing slash gone), through its
    links, and with or without /private (macOS's /tmp, /var and /etc are /private/...)."""
    out = set()
    for p in paths:
        if not p: continue
        for q in (p, os.path.normpath(p), os.path.realpath(p)):
            q = q.rstrip("/")
            if len(q) < 2: continue
            out.add(q)
            if q.startswith("/private/"): out.add(q[len("/private"):])
            elif q.split("/")[1] in ("tmp", "var", "etc"): out.add("/private" + q)
    return out


def scrub(text, names):
    """A record file as it is committed: each (form, name), longest form first, replaced where the form is a whole path
    or a path's beginning (never inside a longer name)."""
    for form, name in sorted(names, key=lambda t: -len(t[0])):
        text = re.sub(re.escape(form) + r"(?=/|$|[^A-Za-z0-9._~-])", lambda _m: name, text)
    return text


def hide(obj, priv):
    """moves.json or journal.json as committed: an item moved to the private folder named only <private item n>, with no
    name, digest, note or differences of it left."""
    if isinstance(obj, list): return [hide(v, priv) for v in obj]
    if not isinstance(obj, dict): return obj
    tag = next((priv[obj[k]] for k in ("path", "src", "about") if isinstance(obj.get(k), str) and obj[k] in priv), None)
    if tag is None: return {k: hide(v, priv) for k, v in obj.items()}
    out = {k: v for k, v in obj.items() if k in ("kind", "n", "options", "suggested", "answer", "done", "undo", "question")}
    if isinstance(out.get("question"), str): out["question"] = "(about a private item)"
    for k in ("path", "src", "about", "dst"):
        if k in obj: out[k] = tag
    return out


def hide_md(text, priv):
    """MIGRATION-PLAN.md as committed: a row about a private item keeps only its kind and question number, and the
    differences shown for one are left out."""
    out, skip = [], False
    for line in text.split("\n"):
        if line.startswith(("### ", "## ")): skip = any(line.startswith(f"### `{md(r)}`") for r in priv)
        if skip: continue
        hit = next((t for r, t in priv.items() if f"`{md(r)}`" in line or md(r) in line), None)
        if hit and line.startswith("|"):
            cells = re.split(r"(?<!\\)\|", line)
            line = (f"| `{hit}` | {cells[2].strip()} | (private folder) | | {cells[5].strip()} | |" if len(cells) == 8
                    else f"| {cells[1].strip()} | (about a private item) | {cells[3].strip()} | {cells[4].strip()} |" if len(cells) == 6 else f"| {hit} |")
        elif hit:
            line = hit
        out.append(line)
    return "\n".join(out)


def apply_outside(project, repo, data, pre, sha, brec):
    """Steps 6a to 11, after the move commit: what lies beside the repository is copied in (7), moved out (8), recorded
    and committed (9), then deleted (10) once what keeps it is committed; then the branches (11). Stops at the first
    surprise, removing only what the step in hand made, and says what is committed and the way back."""
    b = pre["beside"]
    if not b["acts"] and not b["branches"]: return {}
    rp = lambda x: os.path.join(repo, x)
    dest = lambda x: (rp(x["dst"]) if x["where"] == "repo" else os.path.join(b["pf"], x["dst"]) if x["where"] == "pf"
                      else rp(b["logs"] + "/" + x["dst"]) if x["where"] == "logs" else None)
    where, made, done, committed, counts = "the re-check", [], [], [sha], {"copied in": 0, "moved out": 0, "deleted": 0, "branches deleted": 0}
    keep_ = []   # saved copies a failed merge could not put back: the only ones left, never removed
    def run_step(kind, x, fn):
        fail_point("signal")
        n = journal_step(project, {"kind": kind, "src": x["rel"], "dst": x.get("dst"), "digest": (x["e"].get("digest") or {}), "undo": False})
        fn(); journal_done(project, n); made.clear(); done.append(x["rel"])
    try:
        c = layout_config(repo)
        for k_, v in b["post"].items():
            if c.get(k_) != v: raise Refusal(f"{k_} is {c.get(k_)} after the layout, not {v}, where the checks placed what lies beside the repository")
        for x in b["acts"]:   # 6a: only what can have changed since step 0
            if self_digest(x["src"]) != x["want"]: raise Refusal(f"`{x['rel']}` changed during apply")
            if x["do"] in ("copy", "move") and os.path.lexists(dest(x)): raise Refusal(f"{dest(x)} appeared during apply")
        where = "the copies into the repository"
        for x in b["acts"]:
            if x["do"] == "copy":
                def one(x=x):
                    if x.get("ignored"):
                        rc, _ = git(repo, "check-ignore", "-q", "--", x["dst"])
                        if rc != 0: raise Refusal(f"git does not ignore `{x['dst']}`, so an order's working file would be committed")
                    copy_in(x["src"], dest(x), made, repo, x.get("skip"))
                    def ren(k):   # a placeholder's own names, at its top: WO-0000-x becomes <new>-x, and what a renamed folder holds with it
                        parts = k.split(os.sep)
                        if x.get("new") and parts[0].upper().startswith(x["old"] + "-"): parts[0] = x["new"] + parts[0][len(x["old"]):]
                        return os.sep.join(parts)
                    if x.get("new"):
                        for n in os.listdir(dest(x)):
                            if n.upper().startswith(x["old"] + "-"): os.rename(os.path.join(dest(x), n), os.path.join(dest(x), x["new"] + n[len(x["old"]):]))
                    if not same_copy(x["src"], dest(x), ren, x.get("skip", ())): raise Refusal(f"the copy of `{x['rel']}` is not the same as it")
                    if x.get("open"): map_order_paths(dest(x), pre["moves"], rp(b["rec"] + "/pre-migration/" + rec_path(x["dst"], folder=True) + "/.wo-manifest"), made)
                    counts["copied in"] += 1
                run_step("copy", x, one)
            elif x["do"] == "merge":
                def one(x=x):
                    h, kept = dest(x), rp(b["rec"] + "/kept")
                    for d in x["e"]["differences"]:   # first every copy, each checked: what only the outside copy has (D1)
                        f, o = d["file"], os.path.join(x["src"], d["file"])
                        if not (d["outside"] and not d["repository"]): continue
                        if d["outside"]["what"] == "dir":
                            if not os.path.isdir(os.path.join(h, f)): made.append(os.path.join(h, f)); _MADE_DIRS.add(os.path.join(h, f)); os.makedirs(os.path.join(h, f))
                            continue
                        copy_in(o, os.path.join(h, f), made, repo)
                        if not same_copy(o, os.path.join(h, f)): raise Refusal(f"the copy of `{x['rel']}/{f}` is not the same as it")
                    swaps = []
                    for l in x["lose"]:   # then each losing version where it is kept, and each winner beside its place
                        o, mine = os.path.join(x["src"], l["file"]), os.path.join(h, l["file"])
                        lose = mine if x["wins"] == "outside" else o
                        k = {"kept": os.path.join(kept, rec_path(os.path.relpath(lose, project))), "pf": os.path.join(b["pf"] or "", l["rel"]),
                             "logs": rp(b["logs"] + "/" + l["rel"])}[l["to"]]
                        copy_in(lose, k, made, b["pf"] if l["to"] == "pf" else repo, point="keep")
                        if not same_copy(lose, k): raise Refusal(f"the saved copy of `{l['rel']}` is not the same as it")
                        if x["wins"] == "outside":
                            tmp = mine + ".acp-migrate-new"
                            copy_in(o, tmp, made, repo)
                            if not same_copy(o, tmp): raise Refusal(f"the copy of `{x['rel']}/{l['file']}` is not the same as it")
                            swaps.append((tmp, mine, k, o))
                    placed = []
                    try:   # last, the winners into place; a failure after one puts the replaced files back before anything is removed
                        for tmp, mine, k, o in swaps:
                            fail_point("replace"); os.replace(tmp, mine); made.remove(tmp); placed.append((mine, k))
                            if not same_copy(o, mine): raise Refusal(f"`{os.path.relpath(mine, repo)}` is not the outside version after it was put in place")
                    except BaseException:
                        stuck = []
                        for mine, k in reversed(placed):
                            back = mine + ".acp-migrate-back"
                            try:
                                shutil.copy2(k, back, follow_symlinks=False); fail_point("putback"); os.replace(back, mine)
                                if not same_copy(k, mine): stuck.append((mine, k))
                            except OSError:
                                stuck.append((mine, k))
                                try: os.unlink(back)
                                except OSError: pass
                        for mine, k in stuck:   # its saved copy is now the only one: it, and every folder holding it, stays
                            keep_.append(k)
                            for m_ in [m_ for m_ in made if m_ == k or k.startswith(m_ + os.sep)]: made.remove(m_)
                        if stuck: raise Refusal("the merge stopped and could not put back " + ", ".join(f"{os.path.relpath(m_, repo)} (its version is at {k_})" for m_, k_ in stuck))
                        raise
                    counts["copied in"] += 1
                run_step("merge", x, one)
            elif x["do"] == "adopt":
                def one(x=x):
                    m = ORDER.match(x["new"]); folder = rp(c["WORKORDERS_DIR"] if m.group(1) == "WO" else c["BUGS_DIR"])
                    before = set(os.listdir(folder)) if os.path.isdir(folder) else set()
                    rc, line = run_tool([rp(os.path.join(c["PIPELINE_ROOT"], "bin", "wo" if m.group(1) == "WO" else "bug")), "adopt", os.path.relpath(x["src"], repo),
                                         "--number", str(int(m.group(2))), "--status", "migrated"], repo)
                    new = sorted(n for n in (set(os.listdir(folder)) if os.path.isdir(folder) else set()) - before if ORDER.match(n))
                    made.extend(os.path.join(folder, n) for n in new)
                    if rc != 0: raise Refusal(f"{'wo' if m.group(1) == 'WO' else 'bug'} adopt refused `{x['rel']}`: {line}")
                    sha_src = fingerprint(x["src"], os.lstat(x["src"]))[1]
                    if len(new) != 1 or not any(fingerprint(os.path.join(folder, new[0], n), os.lstat(os.path.join(folder, new[0], n)))[1] == sha_src for n in os.listdir(os.path.join(folder, new[0]))):
                        raise Refusal(f"adopting `{x['rel']}` did not make one order holding it")
                    x["dst"] = os.path.relpath(os.path.join(folder, new[0]), repo); x["where"] = "repo"
                    counts["copied in"] += 1
                run_step("adopt", x, one)
        where = "the moves out of the project"
        for x in b["acts"]:
            if x["do"] != "move": continue
            def one(x=x):
                if x["where"] == "logs":
                    gi = rp(b["logs"] + "/.gitignore")
                    if not os.path.lexists(gi):
                        os.makedirs(os.path.dirname(gi), exist_ok=True); made.append(gi); write_bytes(gi, b"*\n"); made.remove(gi)
                copy_in(x["src"], dest(x), made, b["pf"] if x["where"] == "pf" else repo)
                if not same_copy(x["src"], dest(x)): raise Refusal(f"the copy of `{x['rel']}` is not the same as it")
                counts["moved out"] += 1
            run_step("moveout", x, one)
        def record_and_commit():   # step 9: the record, then the second commit, with the project's hooks (D4)
            r_ = rp(b["rec"]); os.makedirs(r_, exist_ok=True)
            nrec = journal_step(project, {"kind": "record", "path": b["rec"], "undo": False})
            pd = os.path.join(project, PLAN_DIR); arch = brec["archive"]
            typed = next((q.get("answer") for q in data["questions"] if q["options"] == [FOLDER_ANSWER]), None)
            pwd = os.environ.get("PWD") if os.path.realpath(os.environ.get("PWD") or "/") == project else None
            sets = [(path_forms(project, data.get("project"), pwd), "<project>"), (path_forms(b["pf"], typed), "<private folder>"),
                    (path_forms(os.path.dirname(arch)), "<backup folder>"), (path_forms(os.path.expanduser("~")), "~")]
            machine = [(f_, n_) for forms, n_ in sets for f_ in forms]
            priv = {}
            for x in b["acts"]:   # what went to the private folder is named in the record only by a number
                for r in ([x["rel"]] if x["where"] == "pf" and not x.get("sub") else []) + [l["rel"] for l in x.get("lose", []) if l["to"] == "pf"]:
                    priv.setdefault(r, f"<private item {len(priv) + 1}>")
            for f in ("MIGRATION-PLAN.md", "moves.json", "backup.json", "journal.json"):   # the journal's lines committed as one record
                text = "" if f == "journal.json" else (file_bytes(os.path.join(pd, f)) or b"").decode("utf-8", "surrogateescape")
                if f.endswith(".json"): text = json.dumps(hide(read_journal(project) if f == "journal.json" else json.loads(text), priv), indent=1, sort_keys=True) + "\n"
                else: text = hide_md(text, priv)
                for r, t in sorted(priv.items(), key=lambda kv: -len(kv[0])):   # and wherever else the text names one
                    text = re.sub(r"(?<![A-Za-z0-9._-])" + re.escape(r) + r"(?![A-Za-z0-9._-])", lambda _m: t, text)
                write_bytes(os.path.join(r_, f), scrub(text, machine).encode("utf-8", "surrogateescape"))
            rows = []
            for base, status in ((c["WORKORDERS_DIR"], None), (c["BUGS_DIR"], None), (b["rec"] + "/retired", "retired")):
                for d, dirs, files in (os.walk(rp(base)) if os.path.isdir(rp(base)) else []):
                    for n in sorted(dirs):
                        if not ORDER.match(n[len("copy-of-"):] if status else n): continue
                        q = os.path.join(d, n); names = os.listdir(q)
                        v = sorted(x for x in names if re.search(r"(?i)-VERIFICATION\.md$", x))
                        rows.append("\t".join([os.path.relpath(q, repo), status or ("open" if is_open_order(q) else "closed"), v[-1] if v else "-",
                                               file_sha(os.path.join(q, v[-1])) if v else "-"]))
                    dirs[:] = [n for n in dirs if not ORDER.match(n[len("copy-of-"):] if status else n)]
            write_bytes(os.path.join(r_, "ORDERS.tsv"), ("path\tstatus\tverification\tsha256\n" + "\n".join(sorted(rows)) + "\n").encode("utf-8", "surrogateescape"))
            lines = [f"# Migration record, {date.today().isoformat()}", "", f"Plan `{data['plan_id']}`. The move commit is `{sha}`; this record and what was carried in are the commit that follows it.", "",
                     "What was done beside the repository (paths relative to the project folder):", ""]
            for x in b["acts"]:
                if x["rel"] in priv: lines.append(f"- {priv[x['rel']]}: moved to the private folder; the original deleted after this commit"); continue
                if x.get("sub"): lines.append(f"- `{x['rel']}`: the order's working files, moved to {'the private folder' if x['where'] == 'pf' else 'the logs folder'}, not committed"); continue
                lines.append(f"- `{x['rel']}`: " + {"copy": "copied in as `" + str(x.get("dst")) + "`" + (" (retired)" if x.get("retired") else ""), "merge": "merged into `" + str(x.get("dst")) + "`, the " + str(x.get("wins")) + " copy winning; the other side's versions are under kept/",
                                                      "adopt": "adopted as " + str(x.get("new")), "move": ("moved to the private folder" if x["where"] == "pf" else "kept with the logs, ignored by git"), "delete": "deleted"}[x["do"]]
                             + ("" if x["do"] == "delete" else "; the original deleted after this commit"))
            for br in b["branches"]: lines.append(f"- branch `{br['branch']}` at `{br['tip'][:12]}`: deleted after this commit")
            lines += ["", "The plan files here are the ones in .acp-migration/, with this machine's paths named <project>, <private folder>, <backup folder> and ~.",
                      "", "Left to the owner: place the repository at the project folder's path (a folder rename outside git), once the outer folder is empty."]
            if fail_point("leak"): lines.append(project)
            write_bytes(os.path.join(r_, "README.md"), ("\n".join(lines) + "\n").encode("utf-8", "surrogateescape"))
            left_ = [f for f in os.listdir(r_) if os.path.isfile(os.path.join(r_, f))
                     and any(re.search(re.escape(form) + r"(?=/|$|[^A-Za-z0-9._~-])", (file_bytes(os.path.join(r_, f)) or b"").decode("utf-8", "surrogateescape")) for form, _ in machine)]
            if left_: raise Refusal(f"the record would commit a path of this machine ({', '.join(sorted(left_))}); nothing was committed")
            journal_done(project, nrec)
            names = [b["rec"]] + [x["dst"] for x in b["acts"] if x["where"] == "repo" and x.get("commit") and not x["dst"].startswith(b["rec"] + "/")]
            gone = []
            for x in b["acts"]:   # a deletion inside the repository is part of the second commit, not left as a change after it
                if x["do"] != "delete" or not x["in_repo"]: continue
                if self_digest(x["src"]) != x["want"]: raise Refusal(f"`{x['rel']}` changed before its deletion; it was not deleted")
                rel_ = os.path.relpath(x["src"], repo); tracked = git(repo, "ls-files", "-z", "--", ":(literal)" + rel_)[1].strip("\0")
                left = []; remove_tree(x["src"], left)
                if left: raise Refusal(f"`{x['rel']}` was deleted only in part: {', '.join(left[:5])} stayed")
                if tracked: gone.append(rel_)
                counts["deleted"] += 1; done.append(x["rel"])
            names += gone
            p = subprocess.run(GIT + no_filters(repo) + ["-C", repo, "--literal-pathspecs", "add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"],
                               input="\0".join(names).encode("utf-8", "surrogateescape"), capture_output=True, timeout=600, env=GIT_ENV)
            if p.returncode != 0: raise Refusal("git add failed: " + (os.fsdecode(p.stderr).strip().splitlines() or ["?"])[-1])
            rc, out = git(repo, "diff", "--cached", "--name-status", "-z")
            parts = out.split("\0"); under = lambda f: any(f == n or f.startswith(n + "/") for n in names)
            bad = [parts[i + 1] for i in range(0, len(parts) - 1, 2) if not (under(parts[i + 1]) and parts[i] in ("A", "M")) and not (parts[i] == "D" and parts[i + 1] in gone)]
            if rc != 0 or bad: raise Refusal("staging the second commit found what apply did not carry in: " + ", ".join(bad[:5] or ["git could not list the staged changes"]))
            n2 = journal_step(project, {"kind": "commit", "undo": False})
            p = subprocess.run(["git"] + no_filters(repo) + ["-C", repo, "commit", "-q", "-m", MSG2], capture_output=True, timeout=900, env=GIT_ENV)   # the project's hooks run (D4)
            if p.returncode != 0: raise Refusal("the second commit failed (" + ((os.fsdecode(p.stderr + p.stdout).strip().splitlines() or ["?"])[-1]) + "); what was carried in is staged")
            rc, sha2 = git(repo, "rev-parse", "HEAD"); committed.append(sha2.strip()); journal_done(project, n2)
        where = "the migration record and the second commit"
        if b["acts"]: record_and_commit()   # only something carried, moved or deleted beside the repository is recorded
        where = "the deletions"
        for x in [x for x in b["acts"] if not (x["do"] == "delete" and x["in_repo"]) and not x.get("sub")]:   # a sub-item goes with its whole
            def one(x=x):
                if self_digest(x["src"]) != x["want"]: raise Refusal(f"`{x['rel']}` changed before its deletion; it was not deleted")
                if x.get("repo_") and unique_work(x["src"]): raise Refusal(f"`{x['rel']}` holds work nothing else has ({'; '.join(unique_work(x['src']))}); it was not deleted")
                if x.get("snapshot") and not in_history(repo, x["src"], reachable_blobs(repo)): raise Refusal(f"`{x['rel']}` holds a file no longer in the repository's history; it was not deleted")
                left = []; remove_tree(x["src"], left)
                if left: raise Refusal(f"`{x['rel']}` was deleted only in part: {', '.join(left[:5])} stayed")
                up = os.path.dirname(x["src"])
                while up != project and within(up, project) and not within(repo, up):   # a folder this emptied goes too; only an empty one
                    try: os.rmdir(up)
                    except OSError: break
                    up = os.path.dirname(up)
                counts["deleted"] += 1
            run_step("delete", x, one)
        where = "the branches"
        for br in b["branches"]:
            def one(br=br):
                rc, now = git(repo, "rev-parse", "--verify", "-q", "refs/heads/" + br["branch"])
                if now.strip() != br["tip"]: raise Refusal(f"branch `{br['branch']}` moved during apply; it was not deleted")
                merged = git(repo, "merge-base", "--is-ancestor", br["tip"], "HEAD")[0] == 0
                if not merged:   # deleted only when every commit on it is on a remote (D3)
                    rc, n = git(repo, "rev-list", "--count", br["tip"], "--not", "--remotes")
                    if rc != 0 or n.strip() != "0": raise Refusal(f"branch `{br['branch']}` has commits on no remote; it was not deleted")
                rc, _, err = git_write(repo, "branch", "-d" if merged else "-D", br["branch"])
                if rc != 0: raise Refusal(f"git could not delete branch `{br['branch']}` ({(err.splitlines() or ['?'])[-1]})")
                counts["branches deleted"] += 1
            run_step("branch", {"rel": "branch " + br["branch"], "e": {}}, one)
    except BaseException as e:
        left = []
        remove_made(made, keep_, left)
        write_applied(project, f"stopped at {where}")
        why = str(e) if isinstance(e, Refusal) else f"{e.__class__.__name__}: {e}"
        kept_out = b["pf"] and any(os.path.lexists(dest(x)) for x in b["acts"] if x["where"] == "pf")
        raise Refusal(f"apply stopped at {where} beside the repository ({why})" + (f"; could not remove {', '.join(left[:5])}" if left else "")
                      + ("; what was moved to the private folder stays there: clear it before apply runs again" if kept_out else "")
                      + f"; done: {len(done)}" + (f" (last: {done[-1]})" if done else "") + f"; committed: {', '.join(x[:12] for x in committed)}; {way_back(project, brec['archive'])}")
    return {"commit_outside": committed[1] if len(committed) > 1 else None, "beside": counts}


STATE = ".rollback-state.json"   # <P>.rollback-state.json, beside the project, never inside it
POINTER = "rollback-pointer.json"   # in the migrated tree's .acp-migration, so a shell left inside it finds the state
# The eval's fault points (unset in use): plain forces the two plain renames, stamp=<s> fixes the names' stamp, and
# <point>=kill or <point>=fail stops a real rollback at created, swapped, aside or kept, as a kill or a failure would;
# <point>=append:<file> changes a file there (copied: after the restored copy is made), as an owner's edit would.
TEST = dict(t.split("=", 1) if "=" in t else (t, "1") for t in os.environ.get("ACP_ROLLBACK_TEST", "").split(",") if t)


def fault(point):
    if TEST.get(point) == "kill": os.kill(os.getpid(), signal.SIGKILL)
    if TEST.get(point) == "fail": raise OSError(errno.EIO, f"failed at {point} (ACP_ROLLBACK_TEST)")
    if TEST.get(point, "").startswith("append:"):
        with open(TEST[point][7:], "a") as f: f.write("x")


def full_sync(fd):
    """Hand the file to the drive, then flush the drive's cache where the system can (F_FULLFSYNC on macOS)."""
    os.fsync(fd)
    if hasattr(fcntl, "F_FULLFSYNC"):
        try: fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
        except OSError: pass


def sync_path(p, full=True):
    fd = os.open(p, os.O_RDONLY)
    try: full_sync(fd) if full else os.fsync(fd)
    finally: os.close(fd)


_LIBC = []


def rename_flag(a, b, swap):
    """An atomic rename where the system has one: swap two names, or rename only onto a free name. True when done,
    False when the system has no such call (the caller falls back); any other failure raises."""
    if "plain" in TEST: return False
    if not _LIBC: _LIBC.append(ctypes.CDLL(None, use_errno=True))
    c = _LIBC[0]
    if sys.platform == "darwin" and hasattr(c, "renamex_np"):
        r = c.renamex_np(os.fsencode(a), os.fsencode(b), ctypes.c_uint(2 if swap else 4))   # RENAME_SWAP, RENAME_EXCL
    elif hasattr(c, "renameat2"):
        r = c.renameat2(-100, os.fsencode(a), -100, os.fsencode(b), ctypes.c_uint(2 if swap else 1))   # EXCHANGE, NOREPLACE
    else: return False
    if r == 0: return True
    e = ctypes.get_errno()
    if e in (errno.ENOSYS, errno.EINVAL, errno.ENOTSUP, errno.EOPNOTSUPP): return False
    raise OSError(e, os.strerror(e), a)


def rename_free(a, b):
    """Rename onto a name that must be free: atomically where possible, else after a last look (a race only)."""
    if rename_flag(a, b, False): return
    if os.path.lexists(b): raise OSError(errno.EEXIST, "exists", b)
    os.rename(a, b)


def ident(p):
    try: st = os.lstat(p)
    except OSError: return None
    return [st.st_dev, st.st_ino]


def read_json(p, limit=1 << 20):
    t = read_small(p, limit)
    if t is None: return None
    try: return json.loads(t)
    except ValueError: return None


def write_state(path, rec, create=False):
    """The state file beside P: created exclusively before the first rename, then replaced whole after each one."""
    text = (json.dumps(rec, indent=1, sort_keys=True) + "\n").encode()
    d = os.path.dirname(path)
    if create:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    else:
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".acp-rollback-state.")
    try: os.write(fd, text); full_sync(fd)
    finally: os.close(fd)
    if not create: os.replace(tmp, path)
    sync_path(d)


def where_trees(st):
    """Which of the three names holds the migrated tree and which the restored one, by device and inode; step is only
    a hint. Returns ({tree: name or None}, {name: what it holds})."""
    names = {"P": st["P"], "R": st["R"], "K": st["K"]}
    at, label = {"migrated": None, "restored": None}, {}
    for k, n in names.items():
        i = ident(n)
        if i is None: label[k] = "missing"
        elif i == st.get("migrated"): at["migrated"] = k; label[k] = "the migrated project"
        elif i == st.get("restored"): at["restored"] = k; label[k] = "the restored project"
        else: label[k] = "something else (not a folder this rollback made or moved)"
    return at, label


def mv_plan(st, at, label, target):
    """The renames, in order, that bring the trees to target, never onto a name that is taken; None if there are none."""
    cur, taken, out = dict(at), {k for k, v in label.items() if v != "missing"}, []
    if None in cur.values(): return None
    def move(t, dest):
        out.append(f"mv {shlex.quote(st[cur[t]])} {shlex.quote(st[dest])}")
        taken.discard(cur[t]); taken.add(dest); cur[t] = dest
    for _ in range(4):
        moved = False
        for t, dest in target.items():
            if cur[t] != dest and dest not in taken: move(t, dest); moved = True
        if not moved and cur != target:   # two trees on each other's names: one steps onto the free third name first
            spare = next((k for k in ("P", "R", "K") if k not in taken and k not in target.values()), None)
            if spare is None: return None
            move(next(t for t in target if cur[t] != target[t]), spare)
    return " && ".join(out) if cur == target and out else (None if cur != target else "nothing to move")


def lock_free(folder):
    """True when no run holds the lock of folder's .acp-migration (a rollback still running holds it)."""
    try: fd = os.open(os.path.join(folder, PLAN_DIR), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError: return True
    try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); return True
    except OSError: return False
    finally: os.close(fd)


def stopped_line(path, st, ours=False):
    """Where a stopped rollback left things, and the moves to finish or undo it. ours: this run holds the lock itself."""
    at, label = where_trees(st)
    m = at["migrated"]
    if m is not None and not ours and not lock_free(st[m]): return f"a rollback is running in {st[m]}; wait for it to finish"
    fin = mv_plan(st, at, label, {"restored": "P", "migrated": "K"})
    und = mv_plan(st, at, label, {"migrated": "P", "restored": "R"})
    q = shlex.quote
    ways = []
    if fin: ways.append("to finish: " + ("" if fin == "nothing to move" else fin + " && ") + f"mv {q(path)} {q(os.path.join(st['K'], PLAN_DIR, 'rollback.json'))}")
    if und: ways.append("to undo: " + ("" if und == "nothing to move" else und + ", then ") + f"remove {q(path)} and {q(os.path.join(st['P'], PLAN_DIR, POINTER))}")
    ways = "   |   ".join(ways) or f"a name the moves need is taken: move one of these folders aside by hand, then look again ({path})"
    return (f"a rollback stopped part-way (it last recorded {st.get('step')}, which can be one rename behind): "
            f"{st['P']} is {label['P']}; {st['R']} is {label['R']}; {st['K']} is {label['K']}; {ways}")


def rollback_guard(project):
    """Run first by every acp migrate command: a rollback that stopped part-way, or still runs, is resolved before
    anything else, wherever the shell was left (in P, in the restored copy, or inside the migrated tree)."""
    parent = os.path.dirname(project)
    found = project + STATE if os.path.lexists(project + STATE) else None
    if found is None:
        me = ident(project)
        for n in listing(parent):
            if n.endswith(STATE):
                st = read_json(os.path.join(parent, n))
                if isinstance(st, dict) and me in (st.get("migrated"), st.get("restored")): found = os.path.join(parent, n); break
    ptr = read_json(os.path.join(project, PLAN_DIR, POINTER))
    if found is None and isinstance(ptr, dict) and os.path.lexists(str(ptr.get("state", ""))): found = ptr["state"]
    if found is not None:
        st = read_json(found)
        if not isinstance(st, dict) or not all(isinstance(st.get(k), str) for k in ("P", "R", "K")):
            raise Refusal(f"{found} records a rollback but cannot be read; look at it and the folders beside it by hand")
        raise Refusal(stopped_line(found, st))
    if isinstance(ptr, dict):
        done = read_json(os.path.join(project, PLAN_DIR, "rollback.json"))
        if isinstance(done, dict):
            raise Refusal(f"this folder is the migrated project a rollback kept on {done.get('stamp')}; the project is at {done.get('P')}")
        raise Refusal(f"a rollback began here but moved nothing: {project} is untouched; remove {os.path.join(project, PLAN_DIR, POINTER)} yourself")


def git_parts(rel): return rel.split(os.sep)


def index_sha(project, rel):
    d = os.path.join(project, os.path.dirname(rel))
    p = subprocess.run(["git", "--git-dir=" + d, "ls-files", "-s", "-z"], capture_output=True, timeout=120,
                       env=dict(GIT_ENV, GIT_OPTIONAL_LOCKS="0"))
    return hashlib.sha256(p.stdout).hexdigest() if p.returncode == 0 else None


def since_apply(project, applied_rows, indexes, rec_git=None):
    """What differs from what apply recorded. A folder changed only when what it holds did (its mtime alone is no
    change). With the git state recorded, each git directory is judged by it (refs, HEAD, config, hooks, info,
    worktrees, reachable objects), so git's own housekeeping is no change; without it, every .git entry is compared,
    an index by what it stages. Returns (what changed in git, other paths)."""
    rows = manifest_of(project, vanish_ok=rec_git is not None)
    moved = []
    if rec_git is not None:
        dirs = git_dirs(applied_rows)
        now = git_states_or_none(project, dirs)
        moved = git_changes(rec_git, now) if now is not None else [f"{', '.join(dirs)}: git cannot read it now"]
        applied_rows, rows, indexes = drop_git(applied_rows, dirs), drop_git(rows, dirs), {}
    a, b = {r["path"]: r for r in applied_rows}, {r["path"]: r for r in rows}
    in_git, other = list(moved), []
    for p in sorted(set(a) | set(b)):
        x, y = a.get(p), b.get(p)
        if x == y: continue
        if x and y and p in indexes and x["type"] == y["type"] == "file" and index_sha(project, p) == indexes[p] is not None: continue
        if x and y and x["type"] == y["type"] == "dir" and dict(x, mtime_ns=0) == dict(y, mtime_ns=0): continue
        (in_git if ".git" in git_parts(p) else other).append(p)
    return in_git, other


def first(paths, n=5):
    return ", ".join(paths[:n]) + (f" (and {len(paths) - n} more)" if len(paths) > n else "")


def in_bare_repo(project, rel):
    parts = git_parts(rel)
    return next((os.sep.join(parts[:i]) for i in range(1, len(parts)) if is_bare(os.path.join(project, *parts[:i]))), None)


def rollback_preflight(project, after_interrupted, accept_repo, archive_arg, keep):
    pd = os.path.join(project, PLAN_DIR)
    ap = os.path.join(pd, "applied.json")
    if not os.path.isdir(pd) or os.path.islink(pd) or not os.path.lexists(ap):
        parent = os.path.dirname(project)
        for n in listing(parent):
            if n.startswith(os.path.basename(project) + ".pre-rollback-"):
                done = read_json(os.path.join(parent, n, PLAN_DIR, "rollback.json"))
                if isinstance(done, dict) and done.get("P") == project:
                    raise Refusal(f"this project is the one a rollback restored on {done.get('stamp')}; the migrated project is kept at {os.path.join(parent, n)}. "
                                  "To migrate again: acp migrate plan, backup, answer, apply")
        raise Refusal("this project was never migrated by acp migrate apply; there is nothing to roll back")
    lock(pd)
    if os.path.islink(ap) or not os.path.isfile(ap): raise Refusal(f"{ap} is a link or not a regular file; it cannot be trusted")
    rec = read_json(ap)
    if not isinstance(rec, dict) or rec.get("format") != 1 or not isinstance(rec.get("outcome"), str):
        raise Refusal(f"{ap} cannot be read; restore from the backup by hand")
    archive = str(rec.get("backup_archive") or "")
    if rec["outcome"] == "started":
        if not after_interrupted:
            if os.path.isfile(archive) and not os.path.islink(archive) and file_sha(archive) == rec.get("backup_archive_sha256"):
                raise Refusal("an apply was interrupted here, so there is no record of what changed after it began. "
                              f"{way_back(project, archive)[0].upper()}{way_back(project, archive)[1:]}; or run: acp migrate rollback --after-interrupted-apply")
            raise Refusal(f"an apply was interrupted here, and the archive apply used ({archive}) is not the one recorded; restore from a copy of it you trust")
        applied_rows = indexes = rec_git = None
    else:
        if after_interrupted: raise Refusal("there is no interrupted apply here; run acp migrate rollback without --after-interrupted-apply")
        mtext = read_small(os.path.join(pd, "applied-manifest.json"), 1 << 30)
        if mtext is None or hashlib.sha256(mtext.encode()).hexdigest() != rec.get("manifest_sha256"):
            raise Refusal("applied-manifest.json is missing or is not the one apply recorded; restore from the backup by hand: " + way_back(project, archive))
        try: applied_rows = json.loads(mtext)["entries"]
        except (ValueError, KeyError, TypeError): raise Refusal("applied-manifest.json cannot be read")
        indexes = rec.get("indexes") if isinstance(rec.get("indexes"), dict) else {}
        rec_git = rec.get("git") if isinstance(rec.get("git"), dict) else None   # an older record, or git unread then: every .git entry compared
    # the backup apply used, whole
    brec = read_json(os.path.join(pd, "backup.json"), 1 << 24)
    btext = read_small(os.path.join(pd, "manifest.json"), 1 << 30)
    if not isinstance(brec, dict) or btext is None: raise Refusal(f"no backup is recorded in {pd}")
    if (brec.get("archive"), brec.get("archive_sha256"), brec.get("manifest_sha256")) != (archive, rec.get("backup_archive_sha256"), rec.get("backup_manifest_sha256")):
        raise Refusal("the backup recorded now is not the one apply used; restore from the archive apply recorded: " + way_back(project, archive))
    if hashlib.sha256(btext.encode()).hexdigest() != brec.get("manifest_sha256"): raise Refusal("manifest.json is not the one the backup recorded")
    try: entries = json.loads(btext)["entries"]
    except (ValueError, KeyError, TypeError): raise Refusal("manifest.json cannot be read")
    try: same_project = os.path.samefile(str(brec.get("project")), project)
    except OSError: same_project = False
    if not same_project or brec.get("entries") != len(entries): raise Refusal("backup.json does not describe this project (another folder, or a copy of it)")
    if archive_arg is not None:
        try: fd = os.open(archive_arg, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError as e: raise Refusal(f"--archive {archive_arg} cannot be opened ({e.strerror}); a link is refused")
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode): raise Refusal(f"--archive {archive_arg} is not a regular file")
            h = hashlib.sha256()
            for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
        if h.hexdigest() != rec.get("backup_archive_sha256"): raise Refusal(f"--archive {archive_arg} is not the archive apply used: its sha256 differs")
        archive = os.path.realpath(archive_arg)
    else:
        if not os.path.isfile(archive) or os.path.islink(archive): raise Refusal(f"the archive {archive} is not there (or is not a regular file); name a copy with --archive <path>")
        if file_sha(archive) != rec.get("backup_archive_sha256"): raise Refusal(f"the archive {archive} is not the one apply used: its sha256 differs")
        if (read_small(archive + ".sha256", 4096) or "") != f"{brec.get('archive_sha256')}  {os.path.basename(archive)}\n" or brec.get("archive_bytes") != os.path.getsize(archive):
            raise Refusal(f"{archive}.sha256 does not match")
    check_archive(archive, entries)
    # nothing changed since apply that rollback cannot account for
    accepted, kept = [], []
    if applied_rows is not None:
        in_git, other = since_apply(project, applied_rows, indexes, rec_git)
        if other and not keep:
            bare = next((b for b in (in_bare_repo(project, p) for p in other) if b), None)
            raise Refusal(f"the project changed after apply: {first(other)}; those changes are not in the backup"
                          + (f" (they are inside the bare repository {bare}, which --accept-repository-changes does not cover)" if bare else "")
                          + ". To roll back and keep them, untouched, in the kept folder: acp migrate rollback --keep-changes; or "
                          + way_back(project, archive))
        kept = other
        if in_git and not accept_repo:
            raise Refusal(f"the repository changed after apply (for example a fetch, a commit, or git's own housekeeping such as gc: {first(in_git)}); "
                          "rollback restores the pre-apply repository, and these changes stay in the kept folder. To go ahead (safe, and the expected "
                          "way after housekeeping): acp migrate rollback --accept-repository-changes")
        accepted = in_git
    # the folders: one device, a writable parent, free names, room
    parent = os.path.dirname(project)
    pst, parst = os.lstat(project), os.lstat(parent)
    if pst.st_dev != parst.st_dev: raise Refusal(f"{project} is a mount point; a rollback renames it, so it must lie on its parent's disk")
    mounts = mounts_in(project, manifest_of(project, vanish_ok=True))   # the folders there now (git may have packed some away)
    if mounts: raise Refusal(f"{first(mounts)} is on another disk than the project (a mount); unmount it first")
    if not os.access(parent, os.W_OK | os.X_OK): raise Refusal(f"{parent} is not writable by you; the restored project is made beside the project")
    if parst.st_mode & stat.S_ISVTX and (pst.st_uid != os.getuid() or parst.st_uid != os.getuid()):
        raise Refusal(f"{parent} is shared (sticky) and you do not own both it and the project")
    stamp = TEST.get("stamp") or datetime.now().strftime("%Y%m%d-%H%M%S")
    R, K, S = f"{project}.restored-{stamp}", f"{project}.pre-rollback-{stamp}", project + STATE
    left = sorted(os.path.join(parent, n) for n in listing(parent) if n.startswith(os.path.basename(project) + ".restored-"))
    for n in (R, K, S):
        if os.path.lexists(n): raise Refusal(f"{n} is there already; move it aside first")
    need = sum(r.get("size", 0) for r in entries) + 4096 * len(entries) + (1 << 20)
    if shutil.disk_usage(parent).free < need: raise Refusal(f"{parent} has less free space than the restore needs ({need} bytes)")
    return dict(archive=archive, entries=entries, stamp=stamp, R=R, K=K, S=S, accepted=accepted, kept=kept, left=left, made=brec.get("made"),
                applied=applied_rows, indexes=indexes, git=rec_git)


def restore_into(R, archive, entries):
    """Extract the archive into R after checking every member, then give every entry its mode and time back."""
    want = {r["path"]: r for r in entries}
    links = {p for p, r in want.items() if r["type"] == "link"}
    with tarfile.open(archive, "r") as tf:
        members, files = tf.getmembers(), set()
        for m in members:
            n = m.name
            if n.startswith("/") or os.path.normpath(n) != n or ".." in n.split("/") or n not in want:
                raise Refusal(f"the archive holds {n!r}, which is not a plain path of the backup's manifest")
            if any("/".join(n.split("/")[:i]) in links for i in range(1, n.count("/") + 1)):
                raise Refusal(f"the archive puts {n!r} under a link")
            if not (m.isdir() or m.isreg() or m.issym() or m.islnk()): raise Refusal(f"{n} is not a folder, file or link in the archive")
            if m.islnk() and (m.linkname not in files or want[m.linkname].get("sha256") != want[n].get("sha256")):
                raise Refusal(f"{n} is a hard link to {m.linkname!r}, which is not an earlier file of the same content")
            if m.isreg(): files.add(n)
        kw = {"filter": "fully_trusted"} if hasattr(tarfile, "fully_trusted_filter") else {}
        tf.extractall(R, members=members, numeric_owner=True, **kw)
    for r in sorted(entries, key=lambda r: r["path"].count("/"), reverse=True):   # deepest first: a folder's time is set after its contents
        p = os.path.join(R, r["path"])
        if r["type"] == "link":
            if os.chmod in os.supports_follow_symlinks:
                try: os.chmod(p, r["mode"], follow_symlinks=False)
                except (OSError, NotImplementedError): pass
        else: os.chmod(p, r["mode"])
        os.utime(p, ns=(r["mtime_ns"], r["mtime_ns"]), follow_symlinks=False)


def sync_tree(top):
    """A plain fsync on every file and folder (links ride on their folder's), then one full flush."""
    for d, dirs, files in os.walk(top):
        for f in files:
            p = os.path.join(d, f)
            if not os.path.islink(p): sync_path(p, full=False)
        sync_path(d, full=False)
    sync_path(top)


def worktrees_named(K, P):
    """Worktrees in K whose .git points into the live project, and K's .git/worktrees twins of worktrees outside it."""
    inside, twins = [], []
    for d, dirs, files in os.walk(K):
        dirs[:] = [x for x in dirs if not os.path.islink(os.path.join(d, x)) and x != ".git"]
        if ".git" in files:
            g = (read_small(os.path.join(d, ".git"), 4096) or "").strip()
            if g.startswith("gitdir: ") and within(os.path.realpath(g[8:]), P): inside.append(d)
    wt = os.path.join(K, ".git", "worktrees")
    for n in listing(wt) if os.path.isdir(wt) else []:
        g = os.path.dirname((read_small(os.path.join(wt, n, "gitdir"), 4096) or "").strip())
        if g and not within(os.path.realpath(g), K) and not within(os.path.realpath(g), P): twins.append(os.path.join(wt, n))
    return inside, twins


def changes_now(project, pf):
    """Changes since apply that preflight did not see (and so neither accepted nor kept)."""
    if pf["applied"] is None: return []
    in_git, other = since_apply(project, pf["applied"], pf["indexes"], pf["git"])
    return sorted(set(in_git + other) - set(pf["accepted"]) - set(pf["kept"]))


def rollback(project, after_interrupted, accept_repo, archive_arg, keep=False):
    pf = rollback_preflight(project, after_interrupted, accept_repo, archive_arg, keep)
    R, K, S, entries = pf["R"], pf["K"], pf["S"], pf["entries"]
    os.mkdir(R, 0o700)
    try:
        restore_into(R, pf["archive"], entries)
        now = manifest_of(R)
        if len(now) != len(entries) or any(dict(a, mtime_ns=0) != dict(b, mtime_ns=0) or abs(a["mtime_ns"] - b["mtime_ns"]) > 1000 for a, b in zip(now, entries)):
            raise Refusal("the restored copy differs from the backup's manifest: " + changed(entries, now))   # every field; a time within 1 µs
    except BaseException as e:
        why = str(e) if isinstance(e, Refusal) else f"{e.__class__.__name__}: {e}"
        raise Refusal(f"the restore stopped before anything was swapped ({why}); {project} is untouched. "
                      f"{R} is a restored copy that was not used; remove it yourself when you no longer need it")
    pst = os.lstat(project)
    os.chmod(R, stat.S_IMODE(pst.st_mode)); os.utime(R, ns=(pst.st_mtime_ns, pst.st_mtime_ns))
    sync_tree(R); fault("copied")
    late = changes_now(project, pf)   # edited while the copy was made: they would go to the kept folder unseen
    if late:
        raise Refusal(f"the project changed while the restored copy was made: {first(late)}; nothing was swapped and {project} is untouched. "
                      f"{R} is a restored copy that was not used; remove it yourself, then run rollback again")
    st = dict(format=1, stamp=pf["stamp"], archive=pf["archive"], P=project, R=R, K=K,
              migrated=ident(project), restored=ident(R), step="restored")
    parent = os.path.dirname(project)
    print(f"acp migrate rollback: swapping {project} for its restored copy; if this stops, {S} says where things stand (run acp migrate rollback again)")
    try:
        write_state(S, st, create=True)
        put(os.path.join(project, PLAN_DIR), POINTER, json.dumps({"format": 1, "state": S, "stamp": pf["stamp"]}, indent=1, sort_keys=True) + "\n")
        fault("created")
        if rename_flag(R, project, True):   # P is never absent: the names swap in one step
            sync_path(parent); write_state(S, dict(st, step="swapped")); fault("swapped")
            rename_free(R, K)
        else:   # two renames: P aside, then the restored copy into its place
            rename_free(project, K); sync_path(parent); write_state(S, dict(st, step="aside")); fault("aside")
            rename_free(R, project)
        sync_path(parent); write_state(S, dict(st, step="kept-named")); fault("kept")
        rename_free(S, os.path.join(K, PLAN_DIR, "rollback.json")); sync_path(parent); sync_path(os.path.join(K, PLAN_DIR))
    except BaseException as e:
        why = str(e) if isinstance(e, Refusal) else f"{e.__class__.__name__}: {e}"
        cur = read_json(S) if os.path.lexists(S) else None
        if not isinstance(cur, dict):
            raise Refusal(f"the swap could not begin ({why}): {project} is untouched; {R} is a restored copy that was not used; remove it yourself")
        raise Refusal(f"the swap stopped ({why}): " + stopped_line(S, cur, ours=True))
    inside, twins = worktrees_named(K, project)
    lines = [f"acp migrate rollback: {project} is back as the backup of {pf['made']} holds it ({len(entries)} entries, archive sha256 {file_sha(pf['archive'])}).",
             f"  The project as it was is kept whole at {K}; nothing was removed.",
             f"  A shell or editor inside {project} is now in the kept folder: cd {project} again.",
             "  The plan, backup and answers stay with the kept folder; to migrate again: acp migrate plan, backup, answer, apply.",
             "  Not carried by a restore: file flags, ACLs, extended attributes; sparse files come back full size."]
    if inside: lines.append(f"  Worktrees in {K} that point at the restored project; do not run git in them: " + ", ".join(inside))
    if twins: lines.append(f"  Their twins in {K}/.git/worktrees, for worktrees outside the project: " + ", ".join(twins))
    if pf["accepted"]: lines.append(f"  Repository changes after apply, accepted, stay in {K}: " + first(pf["accepted"]))
    if pf["kept"]: lines.append(f"  Changes after apply, kept, stay in {K}: " + first(pf["kept"]))
    late = changes_now(K, pf)
    if late: lines.append(f"  Changes made while the rollback ran, not in the restored project, stay in {K}: " + first(late))
    earlier = [x for x in pf["left"] if x != R]
    if earlier: lines.append("  A restored copy an earlier, interrupted rollback left, not used; remove it yourself: " + ", ".join(earlier))
    return lines


CMD = "plan"   # the subcommand running, for the messages


def one_line(s):
    """A message on one line: line breaks and other control characters are shown as \\xNN, never written raw."""
    return re.sub(r"[\x00-\x1f\x7f]", lambda m: f"\\x{ord(m.group()):02x}", shown(s))


def refuse(msg):
    print(f"acp migrate {CMD}: " + one_line(msg), file=sys.stderr); return 1


def main(argv):
    for f in (sys.stdout, sys.stderr): f.reconfigure(errors="backslashreplace")   # any name prints, in any locale
    try: return run(argv)
    except Refusal as e: return refuse(str(e))
    except OSError as e: return refuse(f"{e.filename or 'a file'} cannot be read ({e.strerror})")


def run(argv):
    global CMD
    if not argv or argv[0] not in ("plan", "backup", "answer", "apply", "rollback"):
        print("usage: acp migrate plan|backup|answer|apply|rollback …   (acp help)", file=sys.stderr); return 1
    cmd = CMD = argv[0]
    at = argv.index("--project") + 1 if "--project" in argv else 0   # a rollback stopped part-way is resolved first, by every command
    if at and at < len(argv): rollback_guard(os.path.realpath(argv[at]))   # also when it is gone: a rollback may have moved it aside
    elif not at: rollback_guard(os.path.realpath(os.getcwd()))
    if cmd == "rollback":   # reads the project and its backup; git only to read; no repository needed
        args, project, after, accept, arch, keep = argv[1:], os.getcwd(), False, False, None, False
        while args:
            a = args.pop(0)
            if a in ("--project", "--archive"):
                if not args: return refuse(f"{a} needs a path")
                v = args.pop(0)
                if a == "--project": project = v
                else: arch = v
            elif a == "--after-interrupted-apply": after = True
            elif a == "--accept-repository-changes": accept = True
            elif a == "--keep-changes": keep = True
            else: return refuse(f"unknown argument {a}")
        project = os.path.realpath(project)
        if not os.path.isdir(project): return refuse(f"{project} is not a folder")
        for line in rollback(project, after, accept, arch, keep): print(line)
        return 0
    if cmd == "answer":   # reads and writes only .acp-migration/moves.json: no repository, no git
        args, project, pos, folder = argv[1:], os.getcwd(), [], False
        while args:
            a = args.pop(0)
            if a == "--project":
                if not args: return refuse("--project needs a folder")
                project = args.pop(0)
            elif a == "--folder": folder = True
            elif a.startswith("--"): return refuse(f"unknown argument {a}")
            else: pos.append(a)
        if len(pos) != 2: return refuse("usage: acp migrate answer <n> <option>  |  acp migrate answer <n> --folder <absolute folder>")
        project = os.path.realpath(project)
        if not os.path.isdir(project): return refuse(f"{project} is not a folder")
        was, left = answer(project, pos[0], pos[1], folder)
        print(f"acp migrate answer: question {pos[0]}: {one_line(pos[1])} (was {'unanswered' if was is None else one_line(was)}). {left} question(s) still unanswered.")
        return 0
    args, project, repo, replace, to, check = argv[1:], os.getcwd(), None, False, None, False
    while args:
        a = args.pop(0)
        if a in ("--project", "--repo") or (cmd == "backup" and a == "--to"):
            if not args: return refuse(f"{a} needs a folder")
            v = args.pop(0)
            if a == "--project": project = v
            elif a == "--repo": repo = v
            else: to = v
        elif a == "--replace" and cmd == "plan": replace = True
        elif a == "--check" and cmd == "backup": check = True
        else: return refuse(f"unknown argument {a}")
    v = git_version()
    if v is None: return refuse(f"git not found: the {cmd} reads the repository with git")
    if v < (2, 15): return refuse(f"git 2.15 or newer is required (found {v[0]}.{v[1]})")
    project = os.path.realpath(project)
    if not os.path.isdir(project): return refuse(f"{project} is not a folder")
    if repo is None:
        if is_repo(project): repo = project
        else:
            c = [os.path.join(project, n) for n in listing(project)
                 if os.path.isdir(os.path.join(project, n)) and not os.path.islink(os.path.join(project, n))
                 and is_repo(os.path.join(project, n)) and os.path.isfile(os.path.join(project, n, "pipeline.config.sh"))]
            if len(c) != 1:
                return refuse(f"{'no' if not c else len(c)} repositories holding pipeline.config.sh in {project}; name the one to migrate with --repo")
            repo = c[0]
    repo = os.path.realpath(repo)
    # the project folder itself, or a folder directly inside it: deeper, the folders between would be planned as
    # residue with the repository inside them
    if not (repo == project or os.path.dirname(repo) == project) or not is_repo(repo):
        return refuse(f"{repo} is not a repository that is the project folder or directly inside it")
    cfg = read_small(os.path.join(repo, "pipeline.config.sh"))
    if cfg is None: return refuse(f"{repo} has no pipeline.config.sh (a regular file): there is no pipeline to migrate")
    if cmd == "apply":
        pre, sha = apply(project, repo)
        print(f"acp migrate apply: {len(pre['moves'])} moves, the layout and the install committed as {sha[:12]} ({MSG}), without hooks.")
        if pre["open_orders"]:
            print("  open orders to verify again (wo verify <n>): " + ", ".join(os.path.basename(o["order"]) for o in pre["open_orders"]))
            print(f"  their old manifests are kept in {PLAN_DIR}/journal.jsonl (each edit's before) and in the backup")
        if pre["result"]:
            print(f"  beside the repository: " + ", ".join(f"{v} {k}" for k, v in pre["result"]["beside"].items())
                  + (f"; the record committed as {pre['result']['commit_outside'][:12]} ({MSG2}) in {pre['beside']['rec']}/" if pre["result"]["commit_outside"] else ""))
        if repo != project: print(f"  Left to you: place the repository at the project folder's path ({os.path.relpath(repo, project)} -> the project folder), once the folder beside it is empty.")
        print(f"  The plan, the journal and the record stay in {PLAN_DIR}/; the backup is the way back: {json.load(open(os.path.join(project, PLAN_DIR, 'backup.json')))['archive']}")
        return 0
    if cmd == "backup":
        if check:
            rec = check_backup(project)
            print(f"acp migrate backup: {rec['archive']} is whole: {rec['entries']} entries, sha256 {rec['archive_sha256']}, as recorded."); return 0
        if to is None: return refuse("name the folder outside the project to write the backup into: --to <dir>")
        rec = backup(project, repo, to)
        print(f"acp migrate backup: wrote {rec['archive']} ({rec['entries']} entries, {rec['archive_bytes']} bytes, sha256 {rec['archive_sha256']}) and {PLAN_DIR}/backup.json. Nothing in the project changed.")
        print("  Run nothing but acp migrate in the project until apply: any other git command can change .git, and apply then refuses.")
        if not rec["remote"]["exists"]: print("  the repository has no remote: push it to a private remote before apply")
        return 0
    pd = os.path.join(project, PLAN_DIR)
    for p in [pd] + [os.path.join(pd, n) for n in PLAN_FILES]:   # nothing is ever written through a link
        if os.path.lexists(p) and (os.path.islink(p) or not (os.path.isdir(p) if p == pd else os.path.isfile(p))):
            return refuse(f"{p} is a link or not a {'folder' if p == pd else 'regular file'}; remove it first")
    if os.path.lexists(os.path.join(pd, "moves.json")) and not replace:
        return refuse(f"a plan is already in {pd}; move it aside, or pass --replace (its recorded answers are lost)")
    pl = Plan(project, repo)
    if repo != project:
        pl.ask(f"The repository is `{pl.rel(repo)}` inside the project folder. Keep it as the one repository (history and SHAs unchanged), bring the content beside it into acp/ by the answers below, and after the move place the repository at the project folder's path (a folder rename outside git, the outer folder retired once empty)?",
               ["yes", "another way (say how)"], "yes")
    inside, wod, bgd = plan_repo(pl, cfg)
    plan_outside(pl, inside, wod, bgd)
    cur, head = plan_git(pl)
    plan_ignores(pl, check_suggestions(pl, cfg, cur, head))
    write(pl, cur, head, replace)
    print(f"acp migrate plan: wrote {os.path.join(pd, 'MIGRATION-PLAN.md')} and moves.json: {len(pl.entries)} entries, {len(pl.questions)} question(s), {len(pl.blockers)} blocker(s) before apply. Nothing moved.")
    return 0


if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
