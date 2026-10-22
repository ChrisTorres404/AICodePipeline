#!/usr/bin/env python3
"""
commit-quality — PreToolUse hook for Bash, on `git commit`.

Before a commit lands: scans the staged content for debug logging, stubs, and
credentials, and runs the project's linter on staged files when one exists.
Credentials block; the rest warns (blocks in strict).

The credential formats live in one place: bin/sanitize's PATTERNS, which a publish
is judged with. A commit is judged with the same rows, so a key sanitize would fail
at publish cannot be committed. If that list cannot be read, the commit is refused.
"""
import importlib.machinery, importlib.util, json, os, re, shlex, shutil, subprocess, sys, time

sys.dont_write_bytecode = True

DEBUG = re.compile(r"^\+.*(\bconsole\.log\s*\(|\bdebugger\b|\bTODO:?\s*implement\b|Not implemented|\bbinding\.pry\b|\bpdb\.set_trace\(\)|\bbreakpoint\(\))")
# Two shapes are the hook's own, stricter at a commit than sanitize is at a publish: a
# database URL with any password, and a credential-named assignment of a long literal. The
# name is taken whole from where it starts ((?=(...))\4 holds it, as Python 3.9 has no atomic
# group), so a long line costs one pass rather than one per character.
# The URL rule keeps sanitize's guards: a password that repeats the user, a placeholder word, or a
# ${VAR}, {{VAR}} or <var> slot is not a credential (postgres://postgres:postgres@db in a compose file).
OWN_SECRET = re.compile(r"\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp|mssql)://(?P<user>[^:/\s@'\"]+):"
                        r"(?!\$\{|\{\{|<|(?P=user)@|(?i:\w*(?:pass|secret|token|changeme|example|placeholder|your|xxx|redacted|pwd)\w*@))[^@\s'\"]{4,}@"
                        r"|(?i:(?<![a-z0-9_-])(?=[a-z0-9_-]*?(?:secret|api[_-]?key|access[_-]?key|private[_-]?key|auth[_-]?token|password|passwd))"
                        r"(?=(?P<name>[a-z0-9_-]*))(?P=name)\s*[:=]\s*['\"][A-Za-z0-9+/=_\-]{16,}['\"])")
# A commit takes sanitize's vendor-shaped rows and key blocks. Left to the publish: a publishable
# key (made to ship in client code) and the generic, name-based rows, which at a commit would block
# ordinary placeholders and local defaults (.env.example, a compose file, apiKey = fromEnv()). The
# credential-named literal above still covers a quoted value at a commit.
NOT_AT_COMMIT = {"secret.pk", "secret.apikey", "secret.dburl", "secret.password"}
# An AWS secret is judged at a commit too, but a placeholder value passes: one character repeated,
# a run of x, or a stand-in word (AWS's own documented example ends in EXAMPLEKEY).
GUARDED = {"secret.awssec"}
PLACEHOLDER = re.compile(r"(?i)x{4,}|your|example|replace|changeme")
SRC = re.compile(r"\.(ts|tsx|js|jsx|mjs|py|go|rb|java|kt|rs|php|cs|swift)$")
# Which files are judged with the whole key list (sanitize's vendor-shaped rows and the hook's own two
# shapes) and which with the vendor rows only: every text file holds real assignments unless it is prose
# or data, where an assignment is an example. One predicate, used by the commit hook and by acp check.
VENDOR_ONLY_EXT = {".md", ".txt", ".rst", ".adoc", ".csv", ".log", ".html", ".htm"}


def full_list(path):
    """True when a file is judged with the whole key list, False (prose and data) with the vendor rows only."""
    return os.path.splitext(os.path.basename(path))[1].lower() not in VENDOR_ONLY_EXT


def text_of(data):
    """A file's text, or None for a binary one (a NUL in its first 8000 bytes, as git decides). A
    UTF-16 file, which has NULs, is known by its byte-order mark and decoded."""
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"): return data.decode("utf-16", "ignore")
    return None if b"\0" in data[:8000] else data.decode("utf-8", "ignore")
TEST = re.compile(r"(^|/)(test|tests|__tests__|spec)/|\.(test|spec)\.")

# A fixture has to be able to carry a credential-shaped string: a test that asserts
# the value is never rendered, a parser's sample input. Exempting test files
# wholesale would not do — a fixture is where a real credential hides best — so the
# exemption is per line, visible to every reader and to review.
ALLOW_SECRET = re.compile(r"acp:allow-secret")

# The installed pipeline is vendored into the project it serves, with this script at
# <pipeline>/core/hooks/. Its own rule tables quote the literals these rules look
# for, and its shipped scripts log to the console for real, so a scan that reads the
# pipeline reports the pipeline instead of the project — under strict, on every
# commit, forever. Same for the agent and skill copies under .claude/.
PIPELINE_DIR = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CLAUDE_DIR = re.compile(r"(^|/)\.claude/")


def vendored(path, base):
    """True when this path is the pipeline's own installed source rather than the
    project's code. Kept in step with the same rule in quality-gate.py and with the
    --exclude check.py derives; a change here belongs in all three.

    The pipeline root is skipped only when it sits inside the project. A checkout of
    the pipeline itself is the project, and skipping it there would switch the rule
    off in the one repository that must keep it on."""
    if CLAUDE_DIR.search(path): return True
    base = os.path.realpath(base)
    if base == PIPELINE_DIR: return False
    full = os.path.realpath(os.path.join(base, path))
    return full == PIPELINE_DIR or full.startswith(PIPELINE_DIR + os.sep)

def load_keys():
    """sanitize's secret rows, as (rows, None), or (None, why they cannot be read).
    The installed copy and the plugin both keep bin/ two levels above this file."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin", "sanitize")
    try:
        loader = importlib.machinery.SourceFileLoader("acp_sanitize", path)
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("acp_sanitize", loader))
        loader.exec_module(mod)
        rows = [(pid, rx) for pid, sev, rx, label in mod.PATTERNS if pid.startswith("secret.") and pid not in NOT_AT_COMMIT]
    except (Exception, SystemExit) as e:
        return None, "the key list in %s cannot be read (%s)" % (os.path.normpath(path), type(e).__name__)
    if not rows or not all(hasattr(rx, "finditer") for pid, rx in rows):
        return None, "the key list in %s holds no secret patterns" % os.path.normpath(path)
    return rows, None


KEYS, KEYS_ERROR = load_keys()


def placeholder(match):
    value = re.sub(r"^.*?[:=]\s*['\"]?", "", match, count=1)   # what follows the name and its = or :
    return len(set(value)) <= 1 or bool(PLACEHOLDER.search(value))


def secret(line):
    """True when this line of code or configuration carries a credential. Callers check KEYS_ERROR first."""
    return bool(OWN_SECRET.search(line)) or vendor_secret(line)


def vendor_secret(line):
    """True when this line of any text holds a vendor-shaped key or a key block from sanitize's list."""
    for pid, rx in KEYS:
        if pid in GUARDED:
            if any(not placeholder(m.group(0)) for m in rx.finditer(line)): return True
        elif rx.search(line): return True
    return False


# Claude Code gives the hook 30 s; git gets at most 12 s a call and 24 s in all, so a slow repository
# is refused by the hook rather than the hook being stopped and the commit let through.
DEADLINE = [None]
OUT_OF_TIME = "the check ran out of time"


def git(where, *a, stdin=None, raw=False):
    """(exit code, output, errors) of git run where the commit runs; output keeps bytes that are not
    UTF-8. A git that cannot run or runs out of time is (None, "", why)."""
    left = min(12.0, DEADLINE[0] - time.monotonic())
    if left <= 0: return None, "", OUT_OF_TIME
    env = {k: v for k, v in os.environ.items() if k not in FOLDER_VARS}   # each place is judged on its own
    env["LC_ALL"] = "C"
    try: r = subprocess.run(["git", *where, *a], capture_output=True, timeout=left, env=env, input=stdin)
    except subprocess.TimeoutExpired: return None, "", OUT_OF_TIME
    except Exception as e: return None, "", type(e).__name__
    out = r.stdout if raw else r.stdout.decode("utf-8", "surrogateescape")
    return r.returncode, out, r.stderr.decode("utf-8", "replace")


# the diff as git prints it by default, whatever the user's diff settings
DIFF = ("-c", "core.quotepath=false", "diff", "--cached", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/")
FOLDER_OPTS = ("-C", "--git-dir", "--work-tree")
FOLDER_VARS = ("GIT_DIR", "GIT_WORK_TREE")
MAX_PLACES = 32


class Unknown(Exception):
    """A folder named in the command that cannot be worked out from the text."""


HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
NAMES_A_FOLDER = re.compile(r"\b(cd|pushd)\b|(^|\s)(-C|--git-dir|--work-tree)(\s|=)|\bGIT_(DIR|WORK_TREE)=")
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
SEPARATORS = set("();|&\n")
is_op = lambda t: bool(t) and set(t) <= SEPARATORS   # &&, ;, ||, |, &, (, ), a new line, or several together


def passed_whole(toks, i):
    """Is toks[i] a command a shell will run: the argument of sh/bash/zsh/dash/ksh -c, or of eval."""
    if i >= 1 and toks[i - 1] == "eval": return True
    return (i >= 2 and re.match(r"^-[A-Za-z]*c$", toks[i - 1]) is not None
            and os.path.basename(toks[i - 2]) in ("sh", "bash", "zsh", "dash", "ksh"))


def without_heredocs(text):
    """The command with every here-document's body taken out: a body is data, not shell, and a quote
    in it would swallow the commands after it."""
    out, ends = [], []
    for line in text.split("\n"):
        if ends:
            if (line.lstrip("\t") if ends[0][0] else line) == ends[0][1]: ends.pop(0)
            continue
        out.append(line)
        ends += [(m.group(1) == "-", m.group(3)) for m in HEREDOC.finditer(line)]
    return "\n".join(out)


def commit_candidates(cmd, cwd):
    """(commits, places): whether the command makes any git commit, and every place it could be made
    in. Shell scoping is not followed: subshells, conditions and pipes make the folder of a commit a
    guess, so every folder the command names counts (each cd and pushd, git's -C, --git-dir and
    --work-tree, GIT_DIR and GIT_WORK_TREE however set, inside quotes too), each relative one taken
    against every place before it, beside the session's folder; cd - and popd only return to one
    already counted. A place is ("dir", path) or ("git-dir", path). A folder that cannot be told, or
    a commit run through xargs, find -exec or submodule foreach, raises Unknown, but only for a
    command that commits: any other is let be."""
    folders, gitdirs, commits, unknown, names = [cwd], [], [False], [], {}
    for k in FOLDER_VARS:   # set for the session itself
        if os.environ.get(k): (gitdirs if k == "GIT_DIR" else folders).append(os.path.abspath(os.environ[k]))
    def expand(d):
        # the folder the command is in (or its repository's top) is a place already counted
        d = re.sub(r"^(\$\(\s*(pwd|git\s+rev-parse\s+--show-toplevel)\s*\)|\$\{?PWD\}?)(?=/|$)", ".", d)
        d = re.sub(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", lambda m: names.get(m.group(1), m.group(0)), d)
        return os.path.expanduser(os.path.expandvars(d))
    def resolve(d, why):
        d = expand(d)
        if "$" in d or "`" in d or d == "-" or d.startswith("~") or not d:
            why.append("the folder %s cannot be told from the command" % d); return []
        return [os.path.normpath(d)] if os.path.isabs(d) else [os.path.normpath(os.path.join(f, d)) for f in list(folders)]
    def add(dst, places):   # each place that exists, once (one that does not can hold no staged change)
        dst.extend(x for x in dict.fromkeys(places) if x not in dst and os.path.isdir(x))
        if len(folders) + len(gitdirs) > MAX_PLACES: unknown.append("the command names more folders than can be checked"); del dst[MAX_PLACES:]
    def scan(text, indirect=False):
        if time.monotonic() > DEADLINE[0]: unknown.append(OUT_OF_TIME); return
        try:
            lx = shlex.shlex(without_heredocs(text), posix=True, punctuation_chars="();<>|&\n")
            lx.whitespace, lx.whitespace_split = " \t\r", True   # a new line separates commands, as ; does
            toks = list(lx)
        except ValueError:
            unknown.append("the command cannot be read")
            if re.search(r"\bgit\b.*\bcommit\b", text): commits[0] = True
            return
        i, through = 0, indirect   # through: this part of the command runs what follows for something else
        while i < len(toks):
            t = toks[i]
            if is_op(t): through = indirect; i += 1; continue
            if t in ("xargs", "-exec", "-execdir"): through = True; i += 1; continue
            assign = ASSIGN.match(t)
            if assign and assign.group(1) in FOLDER_VARS:   # GIT_DIR=x git commit, export GIT_DIR=x, env GIT_DIR=x
                add(gitdirs if assign.group(1) == "GIT_DIR" else folders, resolve(assign.group(2), unknown))
            elif assign:
                names[assign.group(1)] = expand(assign.group(2))   # REPO=/x; cd "$REPO"
            elif t in ("cd", "pushd"):
                j = i + 1
                while j < len(toks) and toks[j].startswith("-") and toks[j] != "-": j += 1   # cd -P, cd -L, cd --
                nxt = toks[j] if j < len(toks) else ""
                if is_op(nxt) or nxt in ("", "<", ">"): add(folders, [os.path.expanduser("~")])
                elif nxt == "-" or nxt.startswith("+"): j += 1   # back to a place already counted
                else: add(folders, resolve(nxt, unknown)); j += 1
                i = j; continue
            elif os.path.basename(t) == "git":
                j, pending, why = i + 1, [], []
                while j < len(toks):
                    o = toks[j]; k, eq2, v = o.partition("=")
                    if o in ("-c", "--namespace") and j + 1 < len(toks): j += 2; continue
                    if k in FOLDER_OPTS and (eq2 or j + 1 < len(toks)):
                        pending.append((gitdirs if k == "--git-dir" else folders, resolve(v if eq2 else toks[j + 1], why)))
                        j += 1 if eq2 else 2; continue
                    if o.startswith("-"): j += 1; continue   # any other option git takes before its command
                    break
                for dst, places in pending: add(dst, places)
                sub = toks[j] if j < len(toks) else ""
                if sub == "commit":
                    commits[0] = True
                    unknown.extend(why)   # an untellable -C matters only where the commit is
                    if through: unknown.append("the commit is run through xargs or find -exec")
                    while j < len(toks) and not is_op(toks[j]): j += 1   # its arguments, a message among them, are not shell
                elif sub == "submodule" and j + 1 < len(toks) and toks[j + 1] == "foreach":
                    j += 2; rest = []
                    while j < len(toks) and not is_op(toks[j]): rest.append(toks[j]); j += 1
                    if re.search(r"\bgit\b.*\bcommit\b", " ".join(rest)):
                        commits[0] = True; unknown.append("the commit is run in each submodule")
                i = j; continue
            elif t != text and (re.search(r"\bgit\b.*\bcommit\b", t) or (passed_whole(toks, i) and NAMES_A_FOLDER.search(t))):
                scan(t, through)   # quoted text holding a commit, however it is run; a folder only in sh -c or eval
            i += 1
    scan(cmd)
    if commits[0] and unknown: raise Unknown(unknown[0])
    places = [("dir", f) for f in folders if os.path.isdir(f)] + [("git-dir", g) for g in gitdirs]
    return commits[0], places


def judge(place, cwd):
    """Judge one place's staged changes: ("not a repository", ...), ("refused", why), or
    ("judged", top, staged paths, secrets, debug, git folder)."""
    kind, path = place
    where = ["-C", path] if kind == "dir" else ["-C", cwd, "--git-dir", path]
    rc, gitdir, err = git(where, "rev-parse", "--absolute-git-dir")
    if rc is not None and rc != 0 and "not a git repository" in err: return ("not a repository",)
    if rc is None and err == OUT_OF_TIME: return ("refused", "%s at %s" % (OUT_OF_TIME, path))
    if rc != 0: return ("refused", "git could not find the repository at %s (%s)" % (path, err.strip() or "no answer"))
    rc, top, err = git(where, "rev-parse", "--show-toplevel")
    base = os.path.realpath(top.strip()) if rc == 0 and top.strip() else os.path.realpath(path)
    rc, names, err = git(where, *DIFF, "--name-only", "-z")
    if rc != 0: return ("refused", "%s at %s" % (OUT_OF_TIME, base) if err == OUT_OF_TIME else "git could not list the staged files at %s" % base)
    staged = [f for f in names.split("\0") if f and not vendored(f, base)]
    gitdir = os.path.realpath(gitdir.strip())
    if not staged: return ("judged", base, [], [], [], gitdir)
    rc, diff, err = git(where, *DIFF, "--unified=0")
    if rc != 0: return ("refused", "%s at %s" % (OUT_OF_TIME, base) if err == OUT_OF_TIME else "the staged changes at %s could not be read" % base)
    debug, secrets, cur, skip, code, full, seen = [], [], "", True, True, True, 0
    for line in diff.split("\n"):
        # decided once per file rather than once per line: a large diff would pay
        # for resolving the same path thousands of times
        if line.startswith("+++ "):
            name = line[4:].rstrip("\t")   # git ends a name holding a space with a tab
            if name.startswith("b/"): cur = name[2:]; skip = vendored(cur, base); code = bool(SRC.search(cur)); full = full_list(cur)
            else: cur, skip, code, full = name, False, True, True   # any other header (/dev/null, a name git had to quote): judged as code
            seen += 1
            if seen % 64 == 0 and time.monotonic() > DEADLINE[0]: return ("refused", "%s at %s" % (OUT_OF_TIME, base))
            continue
        if not cur or skip: continue
        if not code:   # configuration takes the whole list, prose the vendor rows; neither has debug rules
            if line.startswith("+") and (secret if full else vendor_secret)(line[1:]) and not ALLOW_SECRET.search(line): secrets.append(f"{cur}: {line[1:80].strip()}…")
            continue
        if line.startswith("+") and secret(line[1:]) and not ALLOW_SECRET.search(line): secrets.append(f"{cur}: {line[1:80].strip()}…")
        elif DEBUG.search(line) and not TEST.search(cur): debug.append(f"{cur}: {line[1:80].strip()}")
    # A file git shows as "Binary files differ" (by content or by a .gitattributes) is read from the index:
    # text with a binary attribute, or UTF-16, would otherwise never be seen.
    rc, nums, err = git(where, "-c", "core.quotepath=false", "diff", "--cached", "--numstat", "-z", "--no-renames", "--diff-filter=d")
    if rc != 0: return ("refused", "git could not list the staged files at %s" % base)
    binary = [f for f in (x.split("\t", 2) for x in nums.split("\0") if x) if len(f) == 3 and f[0] == "-" and not vendored(f[2], base)]
    if binary:
        rc, idx, err = git(where, "ls-files", "-s", "-z", "--full-name", "--", ":/")   # named from the top, as the diff names them
        if rc != 0: return ("refused", "git could not list the staged files at %s" % base)
        oid, other = {}, set()
        for e in idx.split("\0"):
            head, _, p = e.partition("\t")
            h = head.split()
            if len(h) != 3: continue
            if h[0] in ("120000", "160000") or h[2] != "0": other.add(p)   # now a link, a submodule or a conflict: no file content
            elif h[0].startswith("100"): oid[p] = h[1]
        binary = [f for f in binary if f[2] not in other]
        lost = [f[2] for f in binary if f[2] not in oid]
        if lost: return ("refused", "the staged copy of %s at %s could not be found in the index" % (lost[0], base))
        want = [f[2] for f in binary]
        if want:
            rc, blobs, err = git(where, "cat-file", "--batch", stdin="".join(oid[p] + "\n" for p in want).encode(), raw=True)
            if rc != 0: return ("refused", "the staged changes at %s could not be read" % base)
            at = 0
            for p in want:
                nl = blobs.index(b"\n", at); h = blobs[at:nl].split()
                if len(h) != 3: return ("refused", "the staged copy of %s at %s could not be read" % (p, base))
                size = int(h[2]); text = text_of(blobs[nl + 1:nl + 1 + size]); at = nl + 1 + size + 1
                if text is None: continue
                judge_line = secret if full_list(p) else vendor_secret
                for line in text.splitlines():
                    if judge_line(line) and not ALLOW_SECRET.search(line): secrets.append(f"{p}: {line[:79].strip()}…"); break
    return ("judged", base, staged, secrets, debug, gitdir)


COMMAND = [""]   # the command being judged, for the refusal should the check itself break


def main():
    try: payload = json.load(sys.stdin)
    except Exception: return 0
    tool = payload.get("tool_input") if isinstance(payload, dict) else None
    cmd = tool.get("command") if isinstance(tool, dict) else None
    if not isinstance(cmd, str): return 0   # no command text: nothing commits
    COMMAND[0] = cmd
    if "--amend" in cmd and "-m" not in cmd: return 0
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) and os.path.isabs(payload.get("cwd") or "") else os.getcwd()
    DEADLINE[0] = time.monotonic() + 24   # the reading of the command, and every git call, inside Claude Code's 30 s
    try: commits, places = commit_candidates(cmd, cwd)
    except Unknown as e:
        print("Commit blocked — %s, so the repository this commit is in cannot be told; run the commit from inside it." % e, file=sys.stderr)
        return 2
    if not commits: return 0
    if KEYS_ERROR:
        print("Commit blocked — %s, so credentials cannot be checked. Restore the pipeline's bin/sanitize." % KEYS_ERROR, file=sys.stderr)
        return 2
    results = [judge(p, cwd) for p in places]
    for r in results:
        if r[0] == "refused":
            print("Commit blocked — %s, so credentials cannot be checked." % r[1], file=sys.stderr)
            return 2
    judged = list({r[5]: r for r in reversed([r for r in results if r[0] == "judged"])}.values())[::-1]   # one repository once
    if not judged: return 0   # no place the command names is a repository: git cannot commit there either
    many = len(judged) > 1
    label = lambda r, s: ("%s: %s" % (r[1], s)) if many else s
    holding = [r for r in judged if r[3]]
    secrets = [s for r in judged for s in r[3]]
    debug = [label(r, d) for r in judged for d in r[4]]
    # the linters run on the repository the hook itself runs in, as before
    here = os.path.realpath(os.getcwd())
    staged = next((r[2] for r in judged if r[1] == here), [])
    if secrets:   # reported before any linter runs, so a slow linter cannot outlast the hook and lose them
        print("\n".join([line for r in holding for line in   # which repository holds each key, so the person can act there
                          ["Commit blocked — credential-like values in staged changes in %s:" % r[1]] + [f"  {s}" for s in r[3][:5]]] + [
            "  Rotate the value and take it out of the change. If the line is a fixture that",
            "  has to carry a credential-shaped string, mark that line and say why:",
            "    // acp:allow-secret — fixture, asserted never to be emitted"]
            + (["Debug logging or stubs in staged source:"] + [f"  {d}" for d in debug[:10]] if debug else [])), file=sys.stderr)
        return 2
    lint_out = ""
    if any(f.endswith((".ts", ".tsx", ".js", ".jsx")) for f in staged) and os.path.exists("node_modules/.bin/eslint"):
        files = [f for f in staged if f.endswith((".ts", ".tsx", ".js", ".jsx")) and os.path.exists(f)]
        if files: lint_out = subprocess.run(["node_modules/.bin/eslint", "--max-warnings", "0", *files], capture_output=True, text=True).stdout.strip()
    elif any(f.endswith(".py") for f in staged):
        files = [f for f in staged if f.endswith(".py") and os.path.exists(f)]
        if files and shutil.which("ruff") and (os.path.exists(".ruff.toml") or os.path.exists("ruff.toml") or os.path.exists("pyproject.toml")):
            try:
                r = subprocess.run(["ruff", "check", *files], capture_output=True, text=True, timeout=60); lint_out = r.stdout.strip() if r.returncode else ""
            except Exception: lint_out = ""
    if not (debug or lint_out): return 0
    out = []
    if debug: out += ["Debug logging or stubs in staged source:"] + [f"  {d}" for d in debug[:10]]
    if lint_out: out += ["Linter findings on staged files:"] + [f"  {l}" for l in lint_out.splitlines()[:15]]
    print("\n".join(out), file=sys.stderr)
    return 2 if debug and os.environ.get("ACP_STRICT") == "1" else 0

if __name__ == "__main__":
    # A hook that breaks is let through by Claude Code; for anything that could be a commit, a break refuses.
    try: sys.exit(main())
    except SystemExit: raise
    except BaseException as e:
        if not re.search(r"\bgit\b.*\bcommit\b", COMMAND[0], re.S): sys.exit(0)   # nothing that commits was being judged
        print("Commit blocked — the commit check broke (%s: %s), so credentials could not be checked." % (type(e).__name__, e), file=sys.stderr)
        sys.exit(2)
