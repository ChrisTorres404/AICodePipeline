#!/usr/bin/env python3
"""
check — the pipeline's rules, run over a set of files, from anywhere.

The session hooks in this directory see one tool call at a time and only run
inside Claude Code. This runs the same rules over a list of paths and runs
under any agent, or none: `wo close` calls it on the work order's changes, a
git pre-commit hook calls it on the staged set, CI calls it on the pull
request, and the session hooks remain the early warning in Claude Code. One
implementation, several moments. The rule tables are imported from the hook
scripts so the two cannot drift apart.

Usage (normally through `acp check`):

  check.py --staged                  the git index
  check.py --since <ref>             git changes since a ref, plus untracked
  check.py --manifest <file>         files changed since a manifest was taken
  check.py --paths <p> [<p>...]      an explicit list
  check.py --root <dir>              project root (default: cwd)
  check.py --strict                  advisory findings block too
  check.py --types                   also type-check (slow; off by default)

Exit 0 when nothing blocks, 2 when something blocks (or an option is refused), 1 when the
checks could not start, 3 when a hook module failed to load or when they broke part-way.
Findings go to stderr.

Strict is --strict, ACP_STRICT=1, or ACP_HOOK_PROFILE=strict. The last is there
because the git hooks are shims that exec this directly and never pass through
run-hook.sh, so without it a project running the strict profile would be strict
in a Claude Code session and merely advisory at commit time.

What blocks under every profile: credential-like values, a lint/format/type
configuration that was weakened, and a closeout resting on verification that is
not an executed pass. Debug logging, stubs, oversized UI files, untraceable
documentation claims, generic-UI drift, and files the project's own formatter
would rewrite warn, and block under --strict. Type errors are asked for
(--types, or ACP_CHECK_TYPES=1) and then warn, and block under --strict: a
whole-project type-check is too slow to put on every commit unasked.
"""
import argparse, hashlib, importlib.util, os, re, subprocess, sys

# Loading the hook modules must not leave bytecode behind in an installed project.
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    """Import a sibling hook script as a module. Their names carry hyphens, so
    the ordinary import statement cannot reach them."""
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


try:
    # A broken sibling hook must not let the checks pass: exit 3, as main does for an error part-way.
    quality = load("quality-gate")
    commit = load("commit-quality")
    config = load("config-protection")
    uisize = load("ui-size-check")
    docs = load("doc-claims-check")
    evidence = load("evidence-gate")
    design = load("design-quality")
    formatting = load("post-edit-format")
    typecheck = load("post-edit-typecheck")
    layout = load("layout")

    # one key list, sanitize's, through the commit hook: one that cannot be read passes nothing
    if commit.KEYS_ERROR: raise RuntimeError(commit.KEYS_ERROR)
    # The per-line fixture exemption comes from the hook too, so a line the commit hook
    # lets through is not refused here, and a change to either spelling moves both.
    ALLOW_SECRET = commit.ALLOW_SECRET
    TEST = commit.TEST
    SOURCE_EXT = frozenset(quality.SOURCE_EXT)   # bound here, so an unusable value stops the checks at load
except (Exception, SystemExit) as e:
    if __name__ != "__main__":
        raise  # imported (kb.py, inventory.py): their own exit codes stand
    import traceback
    traceback.print_exc()
    print(f"check: internal error loading the hook modules ({type(e).__name__}: {e}); the checks did not run, so nothing is passed (exit 3)", file=sys.stderr)
    sys.exit(3)
# .claude holds the installed copies of the pipeline's agents, skills and workflows.
# They are the pipeline's own source, vendored into the project, exactly like the
# pipeline root the session hooks skip; the project did not write them.
SKIP_DIRS = {"node_modules", ".git", "__pycache__", ".venv", "venv", "dist", "build", ".next", ".turbo", "coverage", ".claude"}
# <pipeline>/core/hooks/check.py — two directories up is the installed pipeline.
PIPELINE_DIR = os.path.realpath(os.path.join(HERE, "..", ".."))


# --- the file set -----------------------------------------------------------

def sh(args, cwd):
    try:
        return subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=60).stdout
    except Exception:
        return ""


def sh_z(args, cwd):
    """A git command's -z output: each path as it is, NUL-separated, read as bytes and decoded as
    file names. Without -z git quotes a path holding a space, a non-ASCII letter or a double quote,
    and that path matched no file, so it was never checked; a byte that is not UTF-8 decodes
    without blinding the rest."""
    try:
        return os.fsdecode(subprocess.run(args, cwd=cwd, capture_output=True, timeout=60).stdout).split("\0")
    except Exception:
        return []


def from_git_status_lines(fields):
    """`git diff --name-status -z` fields: a status, then one path, or two for a rename or copy
    (the old path, then the new one, which is the one kept)."""
    out, i = {}, 0
    while i < len(fields):
        st = fields[i][:1]
        if not st: i += 1; continue
        n = 3 if st in ("R", "C") else 2
        path = fields[i + n - 1] if i + n - 1 < len(fields) else ""
        i += n
        if not path or st == "D": continue
        out[path] = "A" if st == "A" else "M"
    return out


def staged(root):
    return from_git_status_lines(sh_z(["git", "diff", "--cached", "--name-status", "-z"], root))


def since(root, ref):
    files = from_git_status_lines(sh_z(["git", "diff", "--name-status", "-z", ref], root))
    for p in sh_z(["git", "ls-files", "-o", "--exclude-standard", "-z"], root):
        if p: files[p] = "A"
    return files


def file_hash(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
    except OSError:
        return ""
    return h.hexdigest()[:16]


def is_linked_worktree(path):
    """A linked git worktree: another checkout of a repository, whose .git is a file naming a git
    directory that holds a commondir (a submodule's does not). Its files are that checkout's, never
    the project's own, so no walk reads them, as git does not."""
    g = os.path.join(path, ".git")
    if not os.path.isfile(g):
        return False
    try:
        with open(g, encoding="utf-8", errors="replace") as f:
            line = f.readline().strip()
    except OSError:
        return False
    if not line.startswith("gitdir:"):
        return False
    gd = line[len("gitdir:"):].strip()
    return os.path.isfile(os.path.join(gd if os.path.isabs(gd) else os.path.join(path, gd), "commondir"))


def walk(root, exclude):
    """Every regular file under root, minus the pipeline's own state and the
    directories no rule should read. Mirrors the driver's fingerprint walk."""
    ex = [os.path.normpath(e) for e in exclude if e]
    for d, dirs, files in os.walk(root):
        rel = os.path.relpath(d, root)
        rel = "" if rel == "." else rel
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS and os.path.normpath(os.path.join(rel, x)) not in ex
                   and not is_linked_worktree(os.path.join(d, x))]
        for f in files:
            p = os.path.join(rel, f) if rel else f
            if os.path.normpath(p) in ex: continue
            yield p


def read_manifest(path):
    out = {}
    try:
        for line in open(path, encoding="utf-8", errors="ignore"):
            line = line.rstrip("\n")
            if not line or line.startswith("#"): continue
            h, _, p = line.partition("\t")
            out[p] = h
    except OSError:
        pass
    return out


def write_manifest(root, path, exclude, only=None):
    """Snapshot the tree: one line per file, hash then path. Taken when a work
    order opens, so its changes can be named later with or without git."""
    with open(path, "w", encoding="utf-8") as f:
        f.write("# acp manifest: sha256[:16]\\tpath — files as they were when the work order opened\n")
        for p in sorted(walk(root, exclude)):
            if only and not any(p == o or p.startswith(o.rstrip("/") + "/") for o in only): continue
            f.write(f"{file_hash(os.path.join(root, p))}\t{p}\n")


def changed_since_manifest(root, manifest, exclude, only=None):
    before = read_manifest(manifest)
    out = {}
    for p in walk(root, exclude):
        if only and not any(p == o or p.startswith(o.rstrip("/") + "/") for o in only): continue
        h = file_hash(os.path.join(root, p))
        if p not in before: out[p] = "A"
        elif before[p] != h: out[p] = "M"
    return out


# --- the rules ---------------------------------------------------------------

def is_source(path):
    return os.path.splitext(path)[1] in SOURCE_EXT


def staged_blobs(root, paths):
    """{path: bytes} of what the index holds for each path, the commit's own copy: the working copy can
    differ, and can be gone. Only regular files count (a link's blob is its target's name). Read by the
    object id of each stage-0 entry, never by a path a name could bend. An entry git cannot read back
    maps to None, which blocks: the commit would carry something nobody looked at."""
    want, oids, skipped = set(paths), {}, set()
    if not want: return {}
    # the whole index, named from the top as the staged changes are, filtered here: a pathspec per
    # staged file would overflow the argument list
    ls = subprocess.run(["git", "-c", "core.precomposeunicode=false", "ls-files", "-s", "-z", "--full-name", "--", ":/"],
                        cwd=root, capture_output=True, timeout=120, env=index_env())
    if ls.returncode != 0:
        raise RuntimeError("git could not list the staged files: %s" % ls.stderr.decode("utf-8", "replace").strip())
    for e in ls.stdout.split(b"\0"):
        head, _, p = e.partition(b"\t")
        f = head.split()
        path = os.fsdecode(p)
        if len(f) != 3 or path not in want: continue
        if f[0] in (b"120000", b"160000") or f[2] != b"0": skipped.add(path)   # a link, a submodule, a conflict
        elif f[0].startswith(b"100"): oids[path] = f[1].decode()
    out = {p: None for p in want - set(oids) - skipped}   # anything else the commit names is not passed unread
    if not oids: return out
    order = sorted(oids)
    r = subprocess.run(["git", "cat-file", "--batch"], cwd=root, input="".join(oids[p] + "\n" for p in order).encode(),
                       capture_output=True, timeout=300, env=index_env())
    if r.returncode != 0:
        raise RuntimeError("git could not read the staged files: %s" % r.stderr.decode("utf-8", "replace").strip())
    data, at = r.stdout, 0
    for p in order:
        nl = data.index(b"\n", at); head = data[at:nl].split()
        if len(head) == 2 and head[1] == b"missing": out[p] = None; at = nl + 1; continue
        if len(head) != 3 or head[1] != b"blob": raise RuntimeError("git gave no blob for %s" % p)
        size = int(head[2]); out[p] = data[nl + 1:nl + 1 + size]; at = nl + 1 + size + 1
    return out


def check_secrets(root, files, blockers, blobs=None):
    """Every text file is read: code, configuration and infrastructure files with the whole key list,
    any other text (a key file, a note) with sanitize's vendor-shaped keys, so a placeholder in prose
    does not block; which is which is the commit hook's own full_list(). With blobs (a staged commit),
    what is read is the commit's own copy."""
    for p in sorted(files):
        if blobs is not None:
            if p in blobs and blobs[p] is None:
                blockers.append(f"{p}: the commit's copy cannot be read back from git, so it cannot be checked"); continue
            data = blobs.get(p)
        else:
            try:
                with open(os.path.join(root, p), "rb") as f: data = f.read()
            except OSError:
                continue
        text = None if data is None else commit.text_of(data)
        if text is None: continue
        judge = commit.secret if commit.full_list(p) else commit.vendor_secret
        for n, line in enumerate(text.splitlines(), 1):
            if judge(line) and not ALLOW_SECRET.search(line):
                blockers.append(f"{p}:{n}: credential-like value — rotate it, or if the line is a "
                                f"fixture that must carry one, mark it 'acp:allow-secret' with a reason")
                break


def check_quality(root, files, warnings):
    for p, st in files.items():
        if not is_source(p) or TEST.search(p): continue
        try:
            lines = open(os.path.join(root, p), encoding="utf-8", errors="ignore").read().splitlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            if line.lstrip().startswith(("//", "#", "*")) and "TODO" not in line and "FIXME" not in line: continue
            for rx, msg in quality.RULES:
                if rx.search(line):
                    warnings.append(f"{p}:{n}: {msg}")
                    break


def check_config(root, files, blockers):
    if os.environ.get("ACP_ALLOW_CONFIG_EDIT") == "1": return
    for p, st in files.items():
        if st != "M": continue          # creating a configuration is allowed; weakening one is not
        if config.PROTECTED.search(p):
            blockers.append(f"{p}: lint, format, or strictness configuration changed (ACP_ALLOW_CONFIG_EDIT=1 in its own commit, with a reason)")


def check_ui_size(root, files, warnings):
    for p in files:
        if not p.endswith(uisize.UI_EXT): continue
        if re.search(r"(^|/)(test|tests|__tests__|spec|stories)/|\.(test|spec|stories)\.", p): continue
        try: n = sum(1 for _ in open(os.path.join(root, p), encoding="utf-8", errors="ignore"))
        except OSError: continue
        for rx, limit, label in uisize.LIMITS:
            if rx.search(p):
                if n > limit: warnings.append(f"{p}: {n} lines; the UI rules cap a {label} at {limit}")
                break


def check_docs(root, files, warnings):
    for p in files:
        if not p.endswith((".md", ".mdx")): continue
        full = os.path.join(root, p)
        try: text = open(full, encoding="utf-8", errors="ignore").read()
        except OSError: continue
        if not (re.search(r"(?m)^(wo|status):", text[:600]) or "<!-- SOURCE:" in text): continue
        seen = set()
        for m in docs.SOURCE_RX.finditer(text):
            ref, line_no = m.group(1), m.group(2)
            if docs.PLACEHOLDER.search(ref) or (ref, line_no) in seen: continue
            seen.add((ref, line_no))
            cands = [ref] if os.path.isabs(ref) else [os.path.join(root, ref), os.path.join(os.path.dirname(full), ref)]
            found = next((c for c in cands if os.path.isfile(c)), None)
            if not found:
                warnings.append(f"{p}: SOURCE points at a file that does not exist: {ref}")


def index_env():
    """The environment for reading the index literally: git refuses --literal-pathspecs beside a
    GIT_*_PATHSPECS setting, and the listing must not come back empty because of one."""
    return {k: v for k, v in os.environ.items() if not (k.startswith("GIT_") and k.endswith("_PATHSPECS"))}


def staged_status(root, path):
    """The status of the VERIFICATION document as the index holds it (the commit's copy), read the
    way the drivers read it. Only a regular file counts: a symbolic link's blob is its target's name,
    which could read as a status line. The blob is read by the object id of that same index entry
    (stage 0, this exact path): `:<path>` would let a path starting `0:` name another file."""
    try:
        ls = subprocess.run(["git", "-c", "core.precomposeunicode=false", "--literal-pathspecs", "ls-files", "-s", "-z", "--", path], cwd=root, capture_output=True, timeout=60, env=index_env())
        if ls.returncode != 0: return "none"
        oid = ""
        for e in ls.stdout.split(b"\0"):
            head, _, p = e.partition(b"\t")
            f = head.split()
            if len(f) == 3 and f[0].startswith(b"100") and f[2] == b"0" and os.fsdecode(p) == path: oid = f[1].decode()
        if not oid: return "none"
        r = subprocess.run(["git", "cat-file", "blob", oid], cwd=root, capture_output=True, timeout=60)
    except Exception:
        return "none"
    if r.returncode != 0: return "none"
    import tempfile
    fd, tmp = tempfile.mkstemp(suffix=".md")
    try:
        with os.fdopen(fd, "wb") as f: f.write(r.stdout)
        return evidence.latest_status(tmp)
    finally:
        os.unlink(tmp)


def check_evidence(root, files, blockers, staged=False):
    """A closeout in the changed set must rest on an executed pass, read the way
    the drivers read it. For --staged, the folder's files and its VERIFICATION
    document are read from the index, as the commit will hold them, not from the
    working copy."""
    folders = set()
    for p in files:
        m = re.search(r"(^|/)((WO|BUG)-\d{3,}-[^/]+)(/|$)", p)
        if m: folders.add(p[: m.end(2)])
    for d in sorted(folders):
        full = os.path.join(root, d)
        if staged:
            # the folder exactly as the index spells it (on macOS git would compose a decomposed name in
            # the pathspec, and an order staged that way, from a branch made on Linux, matched nothing);
            # a listing git refuses blocks: it is never an empty folder
            try:
                ls = subprocess.run(["git", "-c", "core.precomposeunicode=false", "--literal-pathspecs", "ls-files", "-z", "--", d + "/"], cwd=root, capture_output=True, timeout=60, env=index_env())
            except Exception:
                ls = None
            if ls is None or ls.returncode != 0:
                blockers.append(f"{d}: git could not list the folder in the index; its closeout was not checked"); continue
            names = [p[len(d) + 1:] for p in os.fsdecode(ls.stdout).split("\0") if p.startswith(d + "/") and "/" not in p[len(d) + 1:]]
        else:
            if not os.path.isdir(full): continue
            names = os.listdir(full)
        if not any("CLOSEOUT" in n.upper() for n in names): continue
        # Only the document itself, <ID>-VERIFICATION.md, as wo close reads it.
        idm = re.match(r"(WO|BUG)-\d{3,}", os.path.basename(d))
        ver = [n for n in names if idm and n == idm.group(0) + "-VERIFICATION.md"]
        if not ver:
            blockers.append(f"{d}: CLOSEOUT present, no VERIFICATION document"); continue
        if staged: st = staged_status(root, d + "/" + ver[0])
        else: st = next((s for s in (evidence.latest_status(os.path.join(full, v)) for v in ver) if s != "none"), "none")
        if st == "PASS": continue
        why = {"FAIL": "the latest verification run failed", "RUNNING": "the last verification never finished",
               "PRECOND": "the last verification could not run (a precondition failed); nothing was asserted",
               "PLAN": "verification is NOT EXECUTED — PLAN ONLY"}.get(st, "VERIFICATION has no authoritative status line")
        blockers.append(f"{d}: CLOSEOUT present but {why}")


def check_kb(root, files, warnings, kb):
    """A change to a file a Feature Profile cites makes that profile a claim about
    code that no longer exists. The engine lives beside this script; when it is
    absent, or there is no knowledge base, there is nothing to say."""
    kb = kb or os.path.join(root, "Workspace", "Docs", "KnowledgeBase")
    engine = os.path.join(HERE, "kb.py")
    if not os.path.isdir(kb) or not os.path.isfile(engine) or not files: return
    try:
        r = subprocess.run([sys.executable, engine, "impact", "--root", root, "--kb", kb, "--stdin"],
                           input="\n".join(sorted(files)) + "\n", capture_output=True, text=True, timeout=60)
    except Exception:
        return
    if r.returncode == 1:
        for line in r.stdout.splitlines():
            if line.strip() and not line.startswith(("uncovered:", "impact:")) and "\t" in line:
                prof, cited = line.split("\t", 1)
                warnings.append(f"{prof}: describes changed code ({cited}); update it, then run acp kb bind")


def check_layout(root, files, blockers, warnings, notes, strict):
    """Work, code, pipeline and the root where the project's layout puts them. Only what this set of files
    touches is reported, so a mess already committed does not stop an unrelated commit; acp doctor reports
    all of it. Advisory, blocking under strict, like the other judgement rules; a stray in the order folders
    is a finding only under strict, and otherwise a note. An order's working files (artifacts/) about to
    enter git block under every profile: that is a leak, not a judgement."""
    try:
        found, _, warned = layout.findings(root, True if strict else None)
    except (layout.NoLayout, RuntimeError, OSError, ValueError) as e:
        notes.append("layout not checked: %s" % e)
        return
    live = {p for p, st in files.items() if st != "D"}   # removing a misplaced file is never held against a commit
    for rule, anchor, covered, msg in found:
        if any(p in live for p in covered):
            (blockers if rule == "artifacts" else warnings).append("layout: %s %s: %s" % (rule, anchor, msg))
    for rule, anchor, covered, msg in warned:   # what is only worth a word never blocks, strict or not
        if any(p in live for p in covered):
            notes.append("layout: %s %s: %s" % (rule, anchor, msg))


# --- the rules the session hooks ran alone ------------------------------------
# Three rules below existed only as PostToolUse hooks, which means they only ever
# ran inside Claude Code. An agent that is not Claude Code, or a person at a
# terminal, saw none of them. They run here too now, over the same file set and
# with the same exclusions as every other rule, so git and CI enforce them under
# any agent. Their tables and their decisions are imported from those hooks
# rather than restated, for the reason stated at the top of this file.

FORMAT_TIMEOUT = 60      # a formatter on a changed set; long enough for a cold start
TYPES_TIMEOUT = 120      # a whole-project tsc, the same bound the post-edit hook uses


class _Ask:
    """Stands in for `subprocess` inside a post-edit hook while the hook is asked
    which command it would run for a file. Those hooks decide, then act; check
    time needs the decision without the action — nothing on disk may change while
    someone is part-way through a commit — so calls are recorded and none are
    executed. `git rev-parse` is answered instead of recorded: it is the hook's
    own containment guard, not the command being asked about, and an empty answer
    switches that guard off for a path we have already resolved ourselves."""

    def __init__(self): self.calls = []

    def run(self, args, **kw):
        args = list(args)
        if args[:2] != ["git", "rev-parse"]: self.calls.append((args, kw))
        return subprocess.CompletedProcess(args, 0, "", "")


def hook_command(mod, path):
    """The command `mod` would run for `path`, without running it.

    Asking the hook beats copying its table here: the formatter a project has
    configured, and the tsconfig nearest a file, are decisions with real detail
    in them, and a second copy of that detail is a copy that goes stale. The
    module's own `subprocess` and `json` names are swapped for the duration and
    put back, so nothing outside this call is affected."""
    ask = _Ask()
    payload = {"tool_name": "Edit", "tool_input": {"file_path": path}}
    saved = mod.subprocess, mod.json
    mod.subprocess = ask
    mod.json = type("_payload", (), {"load": staticmethod(lambda _stream: payload)})
    try:
        mod.main()
    except Exception:
        return None
    finally:
        mod.subprocess, mod.json = saved
    return ask.calls[0] if ask.calls else None


def check_ui_drift(root, files, warnings):
    """design-quality's signals over the changed frontend files. The hook sees one
    edit as it happens; this sees the set that is about to be committed. Advisory
    under every profile, blocking under strict — the signals are judgement calls
    (a rendered list may legitimately have no empty state), and a rule that is
    right most of the time belongs in front of a person, not across a gate."""
    for p in sorted(files):
        if not design.FRONTEND.search(p): continue
        try: text = open(os.path.join(root, p), encoding="utf-8", errors="ignore").read()
        except OSError: continue
        for rx, msg in design.SIGNALS:
            m = rx.search(text)          # one report per signal per file, as the hook does
            if not m: continue
            line = text.count("\n", 0, m.start()) + 1
            warnings.append(f"{p}:{line}: `{m.group(0)[:40].strip()}` — {msg}")


def read_only_form(prefix):
    """A formatter's write invocation turned into the one that only reports.

    `prefix` is the command the post-edit hook would run with the file name
    removed. Everything the pipeline knows about *which* formatter a project uses
    comes from that hook; what is known here, and only here, is how each formatter
    is asked the question instead of told to act. Returns None when a formatter
    has no read-only form, which is reported as a note and never as a finding."""
    if not prefix: return None
    prog = os.path.basename(prefix[0])
    if prog == "prettier": return [prefix[0], "--check"]
    if prog == "biome":    return [prefix[0], "format"]            # without --write it only reports
    if prog == "ruff":     return [prefix[0], "format", "--check"] # no -q: the names are the answer
    if prog == "black":    return [prefix[0], "--check"]
    if prog == "gofmt":    return [prefix[0], "-l"]
    if prog == "rustfmt":  return list(prefix) + ["--check"]
    return None


def check_format(root, files, warnings, notes):
    """Files the project's own formatter would rewrite. Never rewrites them: at
    check time the working tree belongs to whoever is committing. Advisory,
    blocking under strict. A formatter that is not installed, or fails, is a note
    and never a failure — the pipeline does not own the project's toolchain, and
    a missing dependency is not a finding about the code."""
    groups = {}
    here = os.getcwd()
    try:
        # The hook detects the project's formatter by relative path (a prettier
        # config, node_modules/.bin/prettier), so the question has to be asked
        # from the project root for the answer to be about this project.
        os.chdir(root)
        for p in sorted(files):
            if not is_source(p): continue
            got = hook_command(formatting, os.path.join(root, p))
            if not got: continue
            args = got[0]
            mode = read_only_form(args[:-1])      # the hook always puts the file last
            if mode is None:
                notes.append(f"{os.path.basename(args[0])} has no read-only form here; formatting not checked")
                continue
            groups.setdefault(tuple(mode), []).append(p)
        for mode, paths in sorted(groups.items()):
            prog = os.path.basename(mode[0])
            try:
                r = subprocess.run(list(mode) + paths, cwd=root, capture_output=True, text=True, timeout=FORMAT_TIMEOUT)
            except Exception:
                notes.append(f"{prog} is configured but could not be run here; formatting not checked")
                continue
            out = (r.stdout or "") + (r.stderr or "")
            # Every one of these names the files it would change; gofmt -l names them
            # and still exits 0, so the names are read rather than the status.
            hit = [p for p in paths if p in out or os.path.join(root, p) in out]
            for p in hit:
                warnings.append(f"{p}: {prog} would reformat this file; run the project's formatter, then stage it")
            if not hit and r.returncode != 0:
                notes.append(f"{prog} reported a problem it did not attribute to a file; formatting not checked")
    finally:
        os.chdir(here)


DIAGNOSTIC = re.compile(r"^(.+?)\((\d+),\d+\): (error TS\d+: .*)$")


def check_types(root, files, warnings, notes):
    """The nearest-tsconfig `tsc --noEmit` the post-edit hook runs, reporting only
    the errors in the changed files. Asked for rather than always on: a whole
    project type-check costs seconds to minutes, and a commit hook that does that
    unbidden is a commit hook people remove. Once asked for it is advisory, and
    blocking under strict."""
    runs = {}
    for p in sorted(files):
        if not p.endswith((".ts", ".tsx")): continue
        got = hook_command(typecheck, os.path.join(root, p))
        if not got: continue
        args, kw = got
        # The command is per-tsconfig, not per-file, so files sharing one project
        # share one run. -p names the project; the file itself is not an argument.
        runs.setdefault((tuple(args), kw.get("cwd") or root), []).append(p)
    for (args, cwd), _paths in sorted(runs.items()):
        try:
            r = subprocess.run(list(args), cwd=cwd, capture_output=True, text=True, timeout=TYPES_TIMEOUT)
        except Exception:
            notes.append("tsc is not available here; type errors not checked"); continue
        seen = 0
        for line in (r.stdout or "").splitlines():
            m = DIAGNOSTIC.match(line)
            if not m: continue
            seen += 1
            rel = os.path.relpath(os.path.join(cwd, m.group(1)), root)
            if rel in files: warnings.append(f"{rel}:{m.group(2)}: {m.group(3)}")
        if not seen and r.returncode != 0:
            notes.append("tsc could not run (is TypeScript installed?); type errors not checked")


# --- main ----------------------------------------------------------------------

def main():
    # Exit codes: 0 nothing blocks; 1 the checks could not start (no manifest, not a repository);
    # 2 a blocking finding, or an option argparse refused; 3 the checks broke part-way, so they did
    # not run to the end and nothing may be taken as passed (callers must treat 3 as a refusal).
    try:
        ap = argparse.ArgumentParser(add_help=True)
        g = ap.add_mutually_exclusive_group()
        g.add_argument("--staged", action="store_true")
        g.add_argument("--since")
        g.add_argument("--manifest")
        g.add_argument("--paths", nargs="+")
        ap.add_argument("--root", default=os.getcwd())
        ap.add_argument("--exclude", nargs="*", default=[])
        ap.add_argument("--only", nargs="*", default=None, help="scope for manifest mode: paths the work order declared")
        ap.add_argument("--strict", action="store_true")
        ap.add_argument("--types", action="store_true", help="also run the project's tsc over the changed TypeScript (slow; ACP_CHECK_TYPES=1 does the same)")
        ap.add_argument("--kb", default=None, help="knowledge-base directory (default: Workspace/Docs/KnowledgeBase under root)")
        ap.add_argument("--no-kb", action="store_true", help="skip the knowledge-base rule (the drivers run their own at close)")
        ap.add_argument("--quiet", action="store_true")
        ap.add_argument("--write-manifest", help="take a snapshot of the tree to this file and exit")
        ap.add_argument("--list", action="store_true", help="print the file set one path per line and exit; no rules run")
        a = ap.parse_args()
        # realpath, not abspath: on macOS the temp directory is a symlink, and a root
        # spelled one way with paths spelled the other resolves to nothing.
        root = os.path.realpath(a.root)

        if a.write_manifest:
            write_manifest(root, a.write_manifest, a.exclude, a.only)
            return 0

        if a.staged:
            files = staged(root); how = "the staged changes"
        elif a.since:
            files = since(root, a.since); how = f"changes since {a.since}"
        elif a.manifest:
            if not os.path.isfile(a.manifest):
                print(f"check: no manifest at {a.manifest}; nothing to compare against", file=sys.stderr); return 1
            files = changed_since_manifest(root, a.manifest, a.exclude, a.only); how = "changes since the work order opened"
        elif a.paths:
            files = {os.path.relpath(os.path.realpath(p), root): "M" for p in a.paths}; how = f"{len(a.paths)} named path(s)"
        else:
            if sh(["git", "rev-parse", "--show-toplevel"], root).strip():
                files = since(root, "HEAD"); how = "changes since HEAD"
            else:
                print("check: not a git repository; give --paths, --manifest, or --staged", file=sys.stderr); return 1

        # With --staged the commit's own paths decide the evidence rule, whether or not the working copy
        # still has them, deletions included (a rename's old path too): a staged CLOSEOUT or VERIFICATION
        # removed from disk, or a VERIFICATION deleted or moved away in the commit, is still the commit's.
        commit_paths = None
        if a.staged:
            commit_paths = dict(files)
            for p in sh_z(["git", "diff", "--cached", "--no-renames", "--name-only", "-z", "--diff-filter=D"], root):
                if p: commit_paths[p] = "D"
        files = {p: s for p, s in files.items() if os.path.isfile(os.path.join(root, p))}
        if a.list:
            for p in sorted(files): print(p)
            return 0
        # The excluded directories are excluded in every mode. The installed pipeline
        # carries example credentials and template configurations by design, and the
        # work-order folders are the pipeline's own state; a staged set that includes
        # them is not evidence of anything about the project.
        ex = [os.path.normpath(e) for e in a.exclude if e]
        # acp check names the pipeline root; a direct invocation does not, so derive it
        # the way the session hooks do and agree with them either way. Only when it sits
        # inside the project: a checkout of the pipeline itself is the project.
        if PIPELINE_DIR.startswith(root + os.sep):
            ex.append(os.path.normpath(os.path.relpath(PIPELINE_DIR, root)))
        def excluded(p):
            q = os.path.normpath(p)
            return any(q == e or q.startswith(e + os.sep) for e in ex) or any(part in SKIP_DIRS for part in q.split(os.sep))
        # The evidence rule is the exception: it is about the work-order folders, which
        # the other rules are told to skip. It sees everything that was named.
        evidence_files = dict(commit_paths) if commit_paths is not None else dict(files)
        files = {p: s for p, s in files.items() if not excluded(p)}
        if not files and not evidence_files:
            if not a.quiet: print(f"check: nothing to check in {how}")
            return 0

        blockers, warnings, notes = [], [], []
        if a.staged:   # the commit's own copy of every path it adds or changes, on disk or not
            staged_paths = [p for p, st in commit_paths.items() if st != "D" and not excluded(p)]
            check_secrets(root, staged_paths, blockers, blobs=staged_blobs(root, staged_paths))
        else:
            check_secrets(root, files, blockers)
        check_config(root, files, blockers)
        check_evidence(root, evidence_files, blockers, staged=a.staged)
        check_quality(root, files, warnings)
        check_ui_size(root, files, warnings)
        check_docs(root, files, warnings)
        check_ui_drift(root, files, warnings)
        check_format(root, files, warnings, notes)
        if a.types or os.environ.get("ACP_CHECK_TYPES") == "1": check_types(root, files, warnings, notes)
        if not a.no_kb: check_kb(root, files, warnings, a.kb)
        check_layout(root, evidence_files, blockers, warnings, notes, a.strict)

        # The git hooks are shims that exec this directly; run-hook.sh, which is what
        # turns the strict profile into ACP_STRICT, is only in the Claude Code path.
        # Reading the profile here is what makes strict mean the same thing at a
        # commit, in CI, and in a session.
        strict = (a.strict or os.environ.get("ACP_STRICT") == "1"
                  or os.environ.get("ACP_HOOK_PROFILE", "").strip().lower() == "strict")
        notes = list(dict.fromkeys(notes))       # one line per reason, however many files hit it
        if not blockers and not warnings:
            if not a.quiet:
                print(f"check: {len(evidence_files)} file(s) in {how}, nothing found")
                for n in notes: print(f"  note: {n}")
            return 0
        out = [f"check — {how}, {len(files)} file(s):"]
        if blockers:
            out.append("  blocking:")
            out += [f"    {b}" for b in blockers[:20]]
        if warnings:
            out.append("  advisory:" if not strict else "  blocking under strict:")
            out += [f"    {w}" for w in warnings[:30]]
        if notes:
            out.append("  note:")
            out += [f"    {n}" for n in notes]
        print("\n".join(out), file=sys.stderr)
        return 2 if blockers or (strict and warnings) else 0
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"check: internal error ({type(e).__name__}: {e}); the checks did not run to the end, so nothing is passed (exit 3)", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
