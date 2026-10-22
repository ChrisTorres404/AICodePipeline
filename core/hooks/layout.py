#!/usr/bin/env python3
"""
layout — what in a repository sits where the project's layout says it should not.

The work lives in the workspace, the code in the code folder, the pipeline in its own
folder, and the repository root holds only the tool wiring. This reads the paths git
lists (tracked, and untracked but not ignored) and names what is out of place:

  work-outside    a work order or bug folder or document outside the workspace
  in-code         inside the code folder: a work document, a workspace (a folder holding the
                  configured Docs/WorkOrders, Docs/Bugs or Docs/KnowledgeBase), pipeline.config.sh,
                  or a plan, handoff or audit document at its top
  duplicate       the same work order or bug number on two folders
  second-kb       a second knowledge base (a folder holding source-index.tsv)
  second-copy     a second copy of the pipeline, installed or built as a plugin
  top-level       a plan, handoff or audit file or folder at the root; and, when the code has a
                  folder of its own (CODE_DIR is not "."), anything at the root the layout does not
                  name. When CODE_DIR is ".", only documents (.md, .txt, no extension) are judged
  not-looked-into a submodule or a nested repository: never classified, check it by hand
  structure       a stray in the work-order and bug folders: a loose file, a folder not named for
                  an order, a file that is not one of the order's own (or names another order), a
                  subfolder other than artifacts/. A stray is a finding under the strict profile
                  (ACP_HOOK_PROFILE=strict or ACP_STRICT=1) and a warning otherwise; editor and system
                  files (*.swp, *~, #*#, .DS_Store) and each folder's own .gitignore are never one.
                  Always a finding: a wo-/bug-NNNN suite whose order has no folder. Warned: a README
                  beside the orders, documents an order's size requires but lacks, a CLOSEOUT beside
                  status=open or status=closed without one, more than a handful of strays (acp migrate
                  files them)
  artifacts       a file git would commit under an order's artifacts/, under every profile: working
                  files never enter git, and the folders' .gitignore (acp install keeps it) says so

It only reports. Moving things is acp migrate's job. Nothing is written, and git runs
with the repository's own fsmonitor and hooks switched off. The index read is the one git
names in GIT_INDEX_FILE, so a check run inside a commit sees what that commit holds.

A project's own root-only names go in LAYOUT_ROOT_EXTRA (space-separated, in pipeline.config.sh).

Usage: layout.py --root <repo>        (the folder pipeline.config.sh is in, or the git top)
       layout.py --order <folder>     what the structure rule will say about one order folder, on disk
Output: one finding per line, "<rule> <path>: <what>"; warnings "warn <rule> <path>: <what>"; notes
start with "note:".
Exit codes: 0 nothing out of place (warnings may be printed; with --order, whatever it said), 1 findings, 3 not a git repository, git failed or the check broke, 4 no
pipeline.config.sh, or a layout folder it sets that is not a plain repository-relative path: the
layout cannot be read, so nothing is judged.
"""
import argparse, os, re, subprocess, sys, unicodedata

sys.dont_write_bytecode = True

DEFAULTS = {"PIPELINE_ROOT": ".aicodepipeline", "WORKSPACE_DIR": "Workspace", "WORKORDERS_DIR": "Workspace/Docs/WorkOrders",
            "BUGS_DIR": "Workspace/Docs/Bugs", "KNOWLEDGE_DIR": "Workspace/Docs/KnowledgeBase", "CODE_DIR": ".",
            "TESTING_DIR": "Workspace/Testing",
            "PLAYBOOKS_DIR": ""}
ORDER = re.compile(r"^(WO|BUG)-([0-9]{4})(-|\.|$)")
PLAN = re.compile(r"(?i)^(handoff|work[-_]?plan|plan|follow[-_]?ups?|audit|journey)([-_. ]|$)|handoff|^next-session--")
DOCS = {".md", ".txt", ""}
ROOT_WIRING = {"pipeline.config.sh", "CLAUDE.md", "AGENTS.md", ".claude", ".mcp.json", ".gitignore", ".gitattributes",
               ".gitmodules", ".github", ".editorconfig", "CODEOWNERS",
               # tools that only work at the repository root
               ".gitlab-ci.yml", ".gitlab", ".pre-commit-config.yaml", ".vscode", ".devcontainer", ".tool-versions", ".idea"}
ROOT_PREFIXES = ("README", "LICENSE", "CONTRIBUTING", "SECURITY", "CHANGELOG")
# acp migrate's own folder at the root; the layout eval holds this equal to migrate.py's PLAN_DIR
PLAN_DIR = ".acp-migration"
# a pipeline copy is known by two files together: installed, built as a plugin, or its source
COPIES = (("bin/wo", "core/hooks/check.py"), ("bin/wo", "hooks/scripts/check.py"), ("bin/install.sh", "pipeline.config.example.sh"))


class NoLayout(Exception):
    """No pipeline.config.sh: the layout is not declared, so nothing can be judged against it."""


def config(root):
    """The layout's folders, from pipeline.config.sh, as every driver reads them: export NAME="value"."""
    v, extra = dict(DEFAULTS), ""
    p = os.path.join(root, "pipeline.config.sh")
    if not os.path.isfile(p):
        raise NoLayout("no pipeline.config.sh, so the layout is not declared; not checked")
    with open(p, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r'^export ([A-Z_]+)="([^"]*)"', line)
            if m and m.group(1) == "LAYOUT_ROOT_EXTRA":
                if re.search(r"[$`\\/\x00-\x1f\x7f]", m.group(2)) or any(x in (".", "..") for x in m.group(2).split()):
                    raise NoLayout("pipeline.config.sh sets LAYOUT_ROOT_EXTRA to %s, not plain names at the root; not checked"
                                   % m.group(2))
                extra = m.group(2)
            elif m and m.group(1) in v and m.group(2):
                name, val = m.group(1), m.group(2)
                parts = val.split("/")
                if name == "PLAYBOOKS_DIR":
                    # the forms the drivers accept: under $PROJECT_ROOT, or a folder outside the project,
                    # which holds nothing to judge here, so the default stands
                    val = re.sub(r"^(\$PROJECT_ROOT|\$\{PROJECT_ROOT\})/", "", val)
                    if val.startswith("/") and os.path.realpath(val).startswith(os.path.realpath(root) + os.sep):
                        val = os.path.relpath(os.path.realpath(val), os.path.realpath(root))
                    if "$" in val or val.startswith(("/", "~")) or ".." in val.split("/") or os.path.normpath(val) == ".":
                        continue
                elif name == "TESTING_DIR" and ("$" in val or val.startswith(("/", "~")) or ".." in parts
                                                or os.path.normpath(val) == "."):
                    val = None   # not a plain path: the suites are not judged, the rest of the layout still is
                elif ("$" in val or val.startswith(("/", "~")) or ".." in parts
                      or (name != "CODE_DIR" and os.path.normpath(val) == ".")):
                    raise NoLayout("pipeline.config.sh sets %s to %s, not a plain repository-relative path; not checked"
                                   % (name, val))
                v[name] = val
    v["PLAYBOOKS_DIR"] = v["PLAYBOOKS_DIR"] or v["PIPELINE_ROOT"] + "/playbooks"
    c = {k: (os.path.normpath(x).strip("/") or ".") if x is not None else None for k, x in v.items()}
    c["LAYOUT_ROOT_EXTRA"] = set(extra.split())
    return c


# Every work order and bug keeps everything in its own folder: its documents (named for its own number),
# its two driver files, its verification logs, and one artifacts/ folder for working files, which wo new,
# wo start, wo adopt, bug new and bug adopt make. Its contents are not judged and never enter git: the
# work-order and bug folders' own .gitignore ignores every order's artifacts/ (order-ignore.py keeps it),
# and a file git sees there anyway is a finding under every profile. Required documents by size are
# bin/wo's required_docs(); the order-structure eval holds this table equal to it.
ORDER_FOLDER = {"WO": re.compile(r"^WO-([0-9]{4})-[A-Za-z0-9]+(-[A-Za-z0-9]+)*$"),
                "BUG": re.compile(r"^BUG-([0-9]{4})-[A-Za-z0-9]+(-[A-Za-z0-9]+)*$")}
DRIVER_FILES = {"WO": (".wo-meta", ".wo-manifest"), "BUG": (".bug-meta", ".bug-manifest")}
ANY_ORDER_NAME = re.compile(r"^(WO|BUG)-([0-9]{4})-", re.I)
REQUIRED_DOCS = {"trivial": ["MAIN"], "small": ["SPEC"],
                 "standard": ["SPEC", "CHECKLIST", "TASK-BREAKDOWN", "Prompt", "REVIEW"],
                 "large": ["SPEC", "CHECKLIST", "TASK-BREAKDOWN", "Prompt", "REVIEW", "sdk-implementation", "ui-implementation"]}
STANDARD_KEYS = ("SPEC", "CHECKLIST", "TASK-BREAKDOWN", "Prompt", "VERIFICATION", "CLOSEOUT", "REVIEW", "sdk-implementation", "ui-implementation")
SUITE = re.compile(r"^(wo|bug)-([0-9]{4})-.+\.sh$")
# editor and system files are nobody's work and never a stray
JUNK = re.compile(r"(\.swp$|~$|^#.*#$|^\.DS_Store$)")
# more strays than this and acp migrate is the way to file them
HANDFUL = 5


def strict_profile():
    """The strict profile, as check.py reads it: ACP_STRICT=1 or ACP_HOOK_PROFILE=strict."""
    return os.environ.get("ACP_STRICT") == "1" or os.environ.get("ACP_HOOK_PROFILE", "").strip().lower() == "strict"


def order_file_allowed(kind, num, name):
    """One of an order's own files: its driver files, a document named for its own number, or a
    verification log the drivers wrote."""
    return (name in DRIVER_FILES[kind]
            or re.match(r"^%s-%s-[A-Za-z0-9][A-Za-z0-9._-]*\.md$" % (kind, num), name) is not None
            or re.match(r"^%s-%s-VERIFICATION-[0-9]{8}-[0-9]{6}(-[0-9]+)?\.log$" % (kind, num), name) is not None)


def order_entry(kind, num, folder_name, inner):
    """What is wrong with one path inside an order folder (inner: its parts below the folder), or None."""
    home = folder_name + "/artifacts/"
    if len(inner) > 1:
        return "a subfolder other than artifacts/ in %s-%s; move it into %s or delete it" % (kind, num, home)
    if order_file_allowed(kind, num, inner[0]):
        return None
    other = ANY_ORDER_NAME.match(inner[0])
    if other and (other.group(1).upper(), other.group(2)) != (kind, num):
        return "a document of %s-%s in %s-%s's folder; move it into %s-%s's folder" % (
            other.group(1).upper(), other.group(2), kind, num, other.group(1).upper(), other.group(2))
    return "not one of %s-%s's files (its documents, driver files, verification logs); move it into %s or delete it" % (kind, num, home)


def has_doc(names, num, key):
    """bin/wo's has_doc(), on a listing."""
    if key == "MAIN":
        return any(re.match(r"(?i)^WO-%s-.*\.md$" % num, n) and not any("-" + k.lower() in n.lower() for k in STANDARD_KEYS) for n in names)
    if key == "REVIEW":
        return any(re.match(r"(?i)^WO-%s-(INDEPENDENT-)?REVIEW\.md$" % num, n) for n in names)
    return any(("WO-%s-%s" % (num, key)).lower() in n.lower() for n in names)


def meta(root, folder, kind):
    """key=value lines of an order's driver meta file, as the drivers read them."""
    out = {}
    try:
        with open(os.path.join(root, folder, DRIVER_FILES[kind][0]), encoding="utf-8", errors="replace") as f:
            for line in f:
                k, eq, v = line.rstrip("\n").partition("=")
                if eq and k not in out: out[k] = v
    except OSError:
        pass
    return out


def order_report(path):
    """What the structure rule will say about one order folder as it stands on disk, every entry
    included: wo adopt and bug adopt keep a folder as it is and say this before they do."""
    name = os.path.basename(os.path.normpath(path))
    kind = "BUG" if name.upper().startswith("BUG-") else "WO"
    out, m = [], ORDER_FOLDER[kind].match(name)
    if m:
        num = m.group(1)
    else:
        out.append("%s: not a %s folder name (%s-NNNN-words)" % (name, kind, kind))
        any_m = ANY_ORDER_NAME.match(name); num = any_m.group(2) if any_m else "0000"
    for e in sorted(os.listdir(path)):
        full = os.path.join(path, e); folder = os.path.isdir(full) and not os.path.islink(full)
        if JUNK.search(e) or (e == "artifacts" and folder):
            continue
        why = order_entry(kind, num, name, [e, ""] if folder else [e])
        if why:
            out.append("%s/%s: %s" % (name, e, why))
    return out


def structure(root, c, files, strict):
    """(fails, warns) for the work-order and bug folders and the suites folder; each is a list of
    (rule, anchor, covered paths, message). A stray (in an order folder, or among them) is a failure
    under the strict profile and a warning otherwise; a suite whose order has no folder always fails."""
    fails, warns, strays, numbers, seen = [], [], [], {"WO": set(), "BUG": set()}, set()
    for kind, key in (("WO", "WORKORDERS_DIR"), ("BUG", "BUGS_DIR")):
        top = c[key]
        if top == ".": continue
        seen.add(kind)
        orders = {}
        for p in sorted(files):
            if not p.startswith(top + "/"): continue
            parts = p[len(top) + 1:].split("/")
            if JUNK.search(parts[-1]): continue
            if len(parts) == 1:
                if parts[0] == ".gitignore":
                    continue   # the folder's own, which keeps every order's artifacts/ out of git
                if parts[0].upper().startswith("README"):
                    warns.append(("structure", p, [p], "a README beside the %s folders; everything for an order lives in its folder" % kind))
                else:
                    strays.append(("structure", p, [p], "a loose file among the %s folders; move it into its order's folder" % kind))
                continue
            folder = top + "/" + parts[0]
            m = ORDER_FOLDER[kind].match(parts[0])
            if not m:
                strays.append(("structure", folder, [p], "not a %s folder name (%s-NNNN-words); rename it, or move its files into their order's folder" % (kind, kind)))
                continue
            num = m.group(1); numbers[kind].add(num)
            orders.setdefault(folder, (num, []))[1].append(p)
            if parts[1] == "artifacts" and len(parts) > 2:
                fails.append(("artifacts", folder + "/artifacts", [p], "working files git would commit; they never enter git. "
                              "%s/.gitignore holds /*/artifacts/ for that: restore it with  acp install <project>, and unstage "
                              "them (git rm --cached)" % top))
                continue
            why = order_entry(kind, num, parts[0], parts[1:])
            if why:
                anchor = folder + "/" + parts[1] if len(parts) > 2 else p
                strays.append(("structure", anchor, [p], why))
        for folder, (num, paths) in sorted(orders.items()):
            names = [p.rsplit("/", 1)[1] for p in paths if p.count("/") == folder.count("/") + 1]
            info = meta(root, folder, kind)
            closed = any(re.match(r"(?i)^%s-%s-.*CLOSEOUT\.md$" % (kind, num), n) for n in names)
            status = info.get("status", "")
            # wo close and bug close write status=closed; a CLOSEOUT beside status=in-progress or blocked is what
            # 1.4 left behind (its close did not touch the status), and the CLOSEOUT decides, as the drivers read it
            if closed and status == "open":
                warns.append(("structure", folder, paths, "%s-%s has a CLOSEOUT but its meta says status=open" % (kind, num)))
            elif status == "closed" and not closed:
                warns.append(("structure", folder, paths, "%s-%s's meta says status=closed but it has no CLOSEOUT" % (kind, num)))
            if kind == "WO":
                size = info.get("size") or "standard"
                missing = [k for k in REQUIRED_DOCS.get(size, REQUIRED_DOCS["standard"]) if not has_doc(names, num, k)]
                if missing:
                    warns.append(("structure", folder, paths, "WO-%s (%s) lacks %s" % (num, size, ", ".join(missing))))
    (fails if strict else warns).extend(strays)
    if len(strays) > HANDFUL:
        cov = sorted({q for _, _, cv, _ in strays for q in cv})
        warns.append(("structure", c["WORKORDERS_DIR"] if "WO" in seen else c["BUGS_DIR"], cov,
                      "%d strays in the work-order and bug folders; acp migrate plan files them into their orders (then backup and apply)" % len(strays)))
    if c["TESTING_DIR"] is not None:
        suites = c["TESTING_DIR"] + "/suites"
        for p in sorted(files):
            if not p.startswith(suites + "/"): continue
            m = SUITE.match(p[len(suites) + 1:])
            if m and m.group(1).upper() in seen and m.group(2) not in numbers[m.group(1).upper()]:
                fails.append(("structure", p, [p], "a suite for %s-%s, which has no folder; delete it or restore the order"
                              % (m.group(1).upper(), m.group(2))))
    return fails, warns


def is_doc(name):
    return os.path.splitext(name)[1].lower() in DOCS


def under(path, folder):
    return folder == "." or path == folder or path.startswith(folder + "/")


def git_paths(root):
    """(files, odd): every path a commit could carry, and the submodules and nested repositories,
    which are reported and never looked into."""
    base = ["git", "-C", root, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.quotepath=false"]
    # GIT_INDEX_FILE stays: inside a commit it names the index that commit holds
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") or k == "GIT_INDEX_FILE"}
    env.update(GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
    def run(*args):
        r = subprocess.run(base + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.decode("utf-8", "replace").strip() or "git %s failed" % args[0])
        return [os.fsdecode(x) for x in r.stdout.split(b"\0") if x]
    files, odd = set(), set()
    for e in run("ls-files", "-z", "--stage"):
        meta, path = e.split("\t", 1)
        (odd if meta.startswith("160000") else files).add(path)
    for path in run("ls-files", "-z", "--others", "--exclude-standard"):
        # git lists a nested repository as its folder, "name/", and does not look inside
        if path.endswith("/"):
            odd.add(path.rstrip("/"))
        else:
            files.add(path)
    return files, odd


def findings(root, strict=None):
    c = config(root)
    files, odd = git_paths(root)
    out, notes = [], []   # out: (rule, anchor, covered paths, message)
    pipe, ws, code, books = c["PIPELINE_ROOT"], c["WORKSPACE_DIR"], c["CODE_DIR"], c["PLAYBOOKS_DIR"]
    kept = lambda p: under(p, pipe) or under(p, books)   # the pipeline, and the playbooks it keeps on purpose
    for p in sorted(odd):
        out.append(("not-looked-into", p, [p], "a submodule or nested repository; not looked into, check it by hand"))
    # Work orders and bugs: where each folder or document is, and every folder each number names.
    places = {}
    for p in sorted(files):
        parts = p.split("/")
        i = next((n for n, s in enumerate(parts) if ORDER.match(s)), None)
        if i is None or kept(p):
            continue
        anchor = "/".join(parts[:i + 1])
        m = ORDER.match(parts[i])
        if i < len(parts) - 1:
            places.setdefault((m.group(1), m.group(2)), set()).add(unicodedata.normalize("NFC", anchor))
        if code != "." and under(p, code):
            out.append(("in-code", anchor, [p], "a work order or bug inside the code folder %s/" % code))
        elif not under(p, ws):
            out.append(("work-outside", anchor, [p], "a work order or bug outside the workspace %s/" % ws))
    nfc = lambda x: unicodedata.normalize("NFC", x)   # one folder in two spellings is one place
    for (kind, num), anchors in sorted(places.items()):
        if len(anchors) > 1:
            cov = [p for p in files if any(nfc(p) == a or nfc(p).startswith(a + "/") for a in anchors)]
            stray = sorted(anchors, key=lambda a: (under(a, ws), a))[0]   # name a copy outside the workspace first
            out.append(("duplicate", stray, cov, "%s-%s is in %d places: %s" % (kind, num, len(anchors), ", ".join(sorted(anchors)))))
    # A workspace, the config, or a plan document inside the code folder. A workspace is known by
    # its structure, the configured folders under it, never by its name: app/src/Workspace/ is code.
    if code != ".":
        tails = [c[k][len(ws) + 1:].split("/") for k in ("WORKORDERS_DIR", "BUGS_DIR", "KNOWLEDGE_DIR")
                 if ws != "." and c[k].startswith(ws + "/")]
        for p in sorted(files):
            if not under(p, code) or under(p, ws) or kept(p):
                continue
            parts = p.split("/")
            i = next((n for n in range(len(parts)) for t in tails if parts[n:n + len(t)] == t and n + len(t) < len(parts)), None)
            if i is not None:
                out.append(("in-code", "/".join(parts[:i]), [p], "a workspace inside the code folder %s/" % code))
            elif parts[-1] == "pipeline.config.sh":
                out.append(("in-code", p, [p], "pipeline material inside the code folder %s/" % code))
            elif os.path.dirname(p) == code and is_doc(parts[-1]) and PLAN.search(parts[-1]):
                out.append(("in-code", p, [p], "a plan, handoff or audit file in the code folder %s/; it belongs in the workspace" % code))
    # A second knowledge base, a second pipeline copy.
    for p in sorted(files):
        if os.path.basename(p) == "source-index.tsv":
            d = os.path.dirname(p) or "."
            if d != c["KNOWLEDGE_DIR"] and not kept(d):
                out.append(("second-kb", d, [p], "a second knowledge base; the project's is %s/" % c["KNOWLEDGE_DIR"]))
    for p in sorted(files):
        for tail, pair in COPIES:
            if p == tail or p.endswith("/" + tail):
                d = p[: len(p) - len(tail)].rstrip("/") or "."
                if (pair if d == "." else d + "/" + pair) in files and d != pipe:
                    cov = [q for q in files if under(q, d)] if d != "." else [p]
                    out.append(("second-copy", d, cov, "a second copy of the pipeline; the project's is %s/" % pipe))
    # The root.
    tops = sorted({p.split("/")[0] for p in files})
    allowed = ROOT_WIRING | c["LAYOUT_ROOT_EXTRA"] | {PLAN_DIR, code.split("/")[0], pipe.split("/")[0], ws.split("/")[0]}
    for t in tops:
        cov = [p for p in files if p == t or p.startswith(t + "/")]
        # with the code at the root, a folder or a source file named plan or audit is the project's own;
        # a folder named handoff never is
        judged = code != "." or (t in files and is_doc(t)) or (t not in files and t.lower() in ("handoff", "handoffs"))
        if judged and PLAN.search(t):
            out.append(("top-level", t, cov, "a plan, handoff or audit file at the root; it belongs in the workspace"))
        elif code != "." and t not in allowed and not t.startswith(ROOT_PREFIXES):
            out.append(("top-level", t, cov, "not part of the layout at the root; move it into %s/ (the code) or %s/ (the work)"
                        % (code, ws.split("/")[0])))
    if code == ".":
        notes.append("CODE_DIR is ., so the code is the whole project and at the root only plan and handoff documents are judged")
    if c["TESTING_DIR"] is None:
        notes.append("TESTING_DIR is not a plain repository-relative path, so the suites are not judged")
    fails, warns = structure(root, c, files, strict_profile() if strict is None else strict)
    out += fails
    # one finding per rule and place, however many files it covers
    def merge(found):
        merged = {}
        for rule, anchor, cov, msg in found:
            k = (rule, anchor, msg)
            merged[k] = merged.get(k, set()) | set(cov)
        return [(r, a, sorted(cv), m) for (r, a, m), cv in sorted(merged.items())]
    return merge(out), notes, merge(warns)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--root")
    g.add_argument("--order", help="one order folder: what the structure rule will say about it, as it stands on disk")
    a = ap.parse_args()
    sys.stdout.reconfigure(errors="backslashreplace")   # a path git hands back undecoded still prints
    esc = lambda s: "".join("\\x%02x" % ord(ch) if ord(ch) < 32 or ord(ch) == 127 else ch for ch in s)
    if a.order is not None:
        try:
            for line in order_report(a.order):
                print("structure " + esc(line))
        except OSError as e:
            print("layout: %s" % esc(str(e)), file=sys.stderr)
            return 3
        return 0
    try:
        out, notes, warns = findings(os.path.realpath(a.root))
    except NoLayout as e:
        print("note: %s" % esc(str(e)))
        return 4
    except Exception as e:
        print("layout: %s" % esc("%s: %s" % (type(e).__name__, e)), file=sys.stderr)
        return 3
    for rule, anchor, _, msg in out:
        print("%s %s: %s" % (rule, esc(anchor), esc(msg)))
    for rule, anchor, _, msg in warns:
        print("warn %s %s: %s" % (rule, esc(anchor), esc(msg)))
    for n in notes:
        print("note: " + n)
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main())
