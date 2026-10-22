#!/usr/bin/env python3
"""
kb — knowledge-base freshness, bound to source.

A repository analysis produces documents that are true on the day they are
written and quietly stop being true afterwards. Nothing in the documents
themselves records that: a Feature Profile describing a login flow reads
exactly the same whether the flow still works that way or was rewritten last
month. This tool removes the guess. Every claim in a profile already carries a
`<!-- SOURCE: path:L12 -->` comment naming the file and line that proves it
(the convention doc-claims-check.py enforces on write); `bind` records the
content hash of every cited file, and `status` re-hashes them and reports which
profiles still rest on the source they were written from.

The knowledge base is a directory (default Workspace/Docs/KnowledgeBase)
holding the analysis document, `profiles/` with one Feature Profile per
feature, a status matrix, and `source-index.tsv` — the machine-readable
binding this tool writes and reads.

  kb.py scaffold --root <dir> --kb <dir> [--level lite|standard|full]
                 [--pipeline-dir <rel>] [--grow [--check]] [--force]
                                                  build the knowledge base from
                                                  the tree, then bind it
  kb.py bind   --root <dir> --kb <dir>            record a hash per cited file
  kb.py status --root <dir> --kb <dir> [--level …] [--json]
                                                  current / stale / broken, what
                                                  falls short of the level, and
                                                  which source nothing describes
  kb.py impact --root <dir> --kb <dir> --files …  which profiles describe this change

The scaffold exists because the alternative was a step designed to fail: the
intake check asked for a knowledge base that only an agent run could produce, and
nothing started that run. `scaffold` reads the tree — feature units, entry points,
routes, models, the manifest — and writes a survey, one profile per feature with
its structure filled in and its narrative sections left as the prompts they are,
a status matrix, and the binding. No agent, no network, same bytes from the same
tree. What it cannot write is the part worth reading, and it says so in every
document it leaves behind.

Levels are to this step what sizes are to a work order.

  lite      a profile exists per feature, structure filled in from the tree.
            The scaffold produces this on its own, so the step passes on a
            fresh install.
  standard  the narrative sections are written: no more than half the writing
            prompts the scaffold wrote are still standing.
  full      standard, and a second reader has checked the profile against the
            source — frontmatter `validated: true` with a name in `reviewed-by`.

`scaffold` records the chosen level in `<kb>/level`; `status --level` overrides it.

Exit codes — status: 0 every profile current and at the level, 1 something is
stale, 2 something is broken (broken outranks stale), 3 there is no knowledge
base to report on, 4 everything is current but something falls short of the
level. 4 is reported only when nothing is stale or broken; the count of profiles
short of the level is on the summary line either way. impact: 0 nothing
affected, 1 at least one profile describes the change. bind: 0, or 1 when the
directory holds no profiles. scaffold: 0, or 1 when it cannot write; with --grow,
3 when a profile's covered paths are gone (reported, never rewritten).

`wo close` and `acp check` call `impact` to say "this change touched files these
profiles describe". Re-writing the profile is agent work and always was; this
tool only knows, and says, when it is due. `scaffold --grow` is the close-time
form: it adds profiles for features no profile covers, reports any profile none of
whose covered paths exists, changes no existing profile, and re-binds nothing, so a
profile describing code that just changed stays stale until someone updates it. A
profile is judged by the paths it covers (its SOURCE citations and its Covers line,
or its feature key when it names no path), never by whether the scaffold's own
grouping has a feature of that name. `scaffold --grow --check` reports the same and
writes nothing, so `wo close` can refuse before anything is on disk.

The rules it shares with the hooks — the SOURCE comment's spelling, the source
extensions, the directories no rule reads, the hash — are imported from them,
so the engine and the hooks cannot drift apart.
"""
import argparse, glob, hashlib, importlib.util, json, os, re, subprocess, sys
from datetime import date

# Reading a project must not leave bytecode behind in the installed pipeline.
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    """Import a sibling hook script as a module. Their names carry hyphens, so
    the ordinary import statement cannot reach them (check.py does the same)."""
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


docs = load("doc-claims-check")
quality = load("quality-gate")
check = load("check")

SOURCE_RX = docs.SOURCE_RX            # <!-- SOURCE: path:L12 --> / :L12-L20 / :12 / no line
PLACEHOLDER = docs.PLACEHOLDER        # the templates' own example citation is not a claim
file_hash = check.file_hash           # sha256[:16], the same digest the manifest uses
SKIP_DIRS = check.SKIP_DIRS
# SOURCE_RX captures only the first line of a range. A profile citing L12-L20 is
# making a claim about line 20 too, so the end of the range is read back out of
# the matched text and checked as well.
RANGE_END = re.compile(r":L?\d+\s*-\s*L?(\d+)")
# The hooks' source extensions plus the two single-file component formats: a
# profile describes a UI feature as readily as a service, and a .vue or .svelte
# file nobody describes is exactly the gap this reports.
SOURCE_EXT = set(quality.SOURCE_EXT) | {".vue", ".svelte"}

INDEX_NAME = "source-index.tsv"
DEFAULT_KB = os.path.join("Workspace", "Docs", "KnowledgeBase")
HEADER_PREFIX = "# acp kb source-index"


# --- reading the knowledge base ---------------------------------------------

def slash(p):
    """One spelling for a path in output and in the index, on every platform."""
    return p.replace(os.sep, "/")


def rel_to(base, path):
    return slash(os.path.relpath(path, base))


def read(path):
    try:
        return open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return ""


def md_docs(kb):
    """Every markdown document under the knowledge base, in a stable order."""
    for d, dirs, files in os.walk(kb):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for f in sorted(files):
            if f.endswith((".md", ".mdx")):
                yield os.path.join(d, f)


def resolve(ref, doc_path, root):
    """A cited path resolves against the repository root or against the document's
    own directory — the two spellings doc-claims-check accepts, so a citation a
    hook passed is a citation this engine can find."""
    if os.path.isabs(ref):
        cands = [ref]
    else:
        cands = [os.path.join(root, ref), os.path.join(os.path.dirname(doc_path), ref)]
    return next((c for c in cands if os.path.isfile(c)), None)


def citations(doc_path, root):
    """[(ref as written, highest line cited or None, resolved absolute path or None)]
    for one document, deduplicated, in document order."""
    out, seen = [], set()
    for m in SOURCE_RX.finditer(read(doc_path)):
        ref, start = m.group(1), m.group(2)
        if PLACEHOLDER.search(ref): continue
        end = RANGE_END.search(m.group(0))
        hi = max(int(start), int(end.group(1))) if start and end else (int(start) if start else None)
        if (ref, hi) in seen: continue
        seen.add((ref, hi))
        out.append((ref, hi, resolve(ref, doc_path, root)))
    return out


COVERS_RX = re.compile(r"^\*\*Covers:\*\*(.*)$", re.M)
GLOB_CHARS = set("*?[")
PATH_EXT_RX = re.compile(r"\.[A-Za-z0-9]{1,8}$")
NOT_PATH_RX = re.compile(r"[\s(){}=,;\"'<>|]")


def path_spelling(item):
    """One Covers item in the spelling the file system uses: backslashes become slashes, a leading `./` goes, a trailing
    slash goes, and `a/../b` is folded. None for an item that cannot be a path (a function name, a phrase)."""
    c = item.strip().replace("\\", "/")
    if not c or NOT_PATH_RX.search(c):
        return None
    c = slash(os.path.normpath(c)) if not (GLOB_CHARS & set(c)) else re.sub(r"^(\./)+", "", c).rstrip("/")
    return None if c in ("", ".") else c


def locate(p, root, doc_dir):
    """The existing paths, relative to the root, that one spelling names. It is tried against the root and against the
    profile's own folder, the two places `resolve()` tries for a citation; a wildcard counts for every file it matches."""
    bases = [p] if os.path.isabs(p) else [os.path.join(root, p), os.path.join(doc_dir, p)]
    found = []
    for b in bases:
        hits = glob.glob(b, recursive=True) if GLOB_CHARS & set(p) else ([b] if os.path.exists(b) else [])
        found += [rel_to(root, os.path.normpath(h)) for h in hits]
    return sorted(set(found))


def covered_paths(path, root):
    """[(the path as the profile writes it, [the existing paths it names, relative to the root])] for every SOURCE citation
    and every path on the profile's **Covers:** line. A profile is about these. Whether the scaffold's own grouping has a
    feature of the same name says nothing about whether they still exist: a profile written by hand may split a directory
    more finely than the scaffold groups it. A Covers item that is not a path (`run()`, a class name) is skipped; one that
    has no slash and no extension counts only when it exists, since a word cannot be told from a gone directory."""
    doc_dir, out, seen = os.path.dirname(path), [], set()
    for ref, _hi, res in citations(path, root):
        if ref in seen:
            continue
        seen.add(ref)
        if res:
            out.append((ref, [rel_to(root, os.path.normpath(res))]))
        else:
            p = path_spelling(ref)
            out.append((ref, locate(p, root, doc_dir) if p else []))
    m = COVERS_RX.search(read(path))
    for item in re.findall(r"`([^`]+)`", m.group(1)) if m else []:
        p = path_spelling(item)
        if p is None or item in seen:
            continue
        found = locate(p, root, doc_dir)
        if not found and "/" not in p and not PATH_EXT_RX.search(p) and not (GLOB_CHARS & set(p)):
            continue          # a bare word that names nothing here: not a claim about a path
        seen.add(item)
        out.append((item, found))
    return out


def key_slug(rel):
    """The feature key `feature_slug` gives a directory, without the numbering it adds to keep names apart."""
    parts = [p for p in rel.split("/") if p not in (".", "")]
    kept = [p for p in parts if p not in SLUG_NOISE] or parts
    return re.sub(r"[^a-z0-9._-]+", "-", "-".join(kept).lower()).strip("-._")


def key_dirs(root, kb):
    """{feature key: directory} for every directory under the root that feature discovery would walk, so a profile that
    names no path can be checked through its feature key."""
    out = {}
    def walk(d, depth):
        if depth > 8:
            return
        try:
            names = sorted(os.listdir(d))
        except OSError:
            return
        for n in names:
            full = os.path.join(d, n)
            if os.path.isdir(full) and not skip_feature_dir(n, full, kb):
                out.setdefault(key_slug(rel_to(root, full)), rel_to(root, full))
                walk(full, depth + 1)
    walk(root, 0)
    return out


def describing(unit_files, root, covers):
    """The profile that already covers one of a unit's files (a citation of the file, a directory holding it, or a
    wildcard matching it), or None."""
    rels = [rel_to(root, f) for f in unit_files]
    for slug, items in sorted(covers.items()):
        for _shown, found in items:
            for c in found:
                if any(r == c or r.startswith(c + "/") for r in rels):
                    return slug
    return None


def profiles_of(kb, root):
    """{document path relative to the kb: [citations]} for every document that
    carries at least one. A document with no citation makes no claim this tool
    can check — an index page or a matrix — and is not a profile."""
    out = {}
    for p in sorted(md_docs(kb)):
        cits = citations(p, root)
        if cits: out[rel_to(kb, p)] = (p, cits)
    return out


_hashes, _lines = {}, {}


def hash_of(path):
    """Each cited file is hashed once per run, however many profiles cite it."""
    if path not in _hashes: _hashes[path] = file_hash(path)
    return _hashes[path]


def line_count(path):
    if path not in _lines:
        try: _lines[path] = sum(1 for _ in open(path, encoding="utf-8", errors="ignore"))
        except OSError: _lines[path] = 0
    return _lines[path]


# --- the index ---------------------------------------------------------------

def index_path(kb):
    return os.path.join(kb, INDEX_NAME)


def read_index(kb):
    """{path relative to root: hash}. An unreadable or absent index is an empty
    one: every citation then reads as never bound, which is the truth."""
    out = {}
    try:
        for line in open(index_path(kb), encoding="utf-8", errors="ignore"):
            line = line.rstrip("\n")
            if not line or line.startswith("#"): continue
            parts = line.split("\t")
            if len(parts) >= 2: out[parts[0]] = parts[1]
    except OSError:
        pass
    return out


def write_index(kb, rows):
    """rows: {path relative to root: (hash, {profiles})}. Sorted, no timestamp —
    the same tree binds to the same bytes, so an index in version control only
    changes when the binding changes."""
    body = "".join(f"{p}\t{h}\t{','.join(sorted(profs))}\n" for p, (h, profs) in sorted(rows.items()))
    bound_tree = hashlib.sha256(body.encode("utf-8")).hexdigest()[:16]
    n_profiles = len({x for _, profs in rows.values() for x in profs})
    header = (f"{HEADER_PREFIX} — columns: path, sha256[:16], citing profiles (tab-separated; "
              f"paths relative to the project root, profiles relative to this directory); "
              f"files={len(rows)}; profiles={n_profiles}; bound_tree={bound_tree}\n")
    with open(index_path(kb), "w", encoding="utf-8") as f:
        f.write(header)
        f.write(body)
    return bound_tree


def bound_tree_of(kb):
    head = ""
    try:
        with open(index_path(kb), encoding="utf-8", errors="ignore") as f:
            head = f.readline()
    except OSError:
        return ""
    m = re.search(r"bound_tree=([0-9a-f]+)", head)
    return m.group(1) if m else ""


# --- what nothing describes ---------------------------------------------------

def is_pipeline_dir(path):
    """The installed pipeline is the project's tooling, not its code: nobody is
    expected to write a Feature Profile about it. Detected by what it contains
    rather than by its name, because the install directory is configurable."""
    return os.path.isfile(os.path.join(path, "bin", "wo")) and os.path.isdir(os.path.join(path, "core", "hooks"))


def source_files(root, kb, exts):
    """Every source file under the root, minus the directories no rule reads, the
    knowledge base itself, and any installed pipeline."""
    out = []
    for d, dirs, files in os.walk(root):
        keep = []
        for x in sorted(dirs):
            full = os.path.join(d, x)
            if x in SKIP_DIRS or os.path.realpath(full) == kb or is_pipeline_dir(full): continue
            keep.append(x)
        dirs[:] = keep
        for f in sorted(files):
            if os.path.splitext(f)[1] in exts:
                out.append(rel_to(root, os.path.join(d, f)))
    return sorted(out)


def cluster(paths, limit=10):
    """Uncovered files are reported by the directory they sit in: a count alone
    says how much is undescribed, the directories say which part of the system."""
    by_dir = {}
    for p in paths:
        by_dir.setdefault(slash(os.path.dirname(p)) or ".", []).append(p)
    ordered = sorted(by_dir.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:limit]
    return [{"dir": d, "count": len(fs), "examples": sorted(fs)[:3]} for d, fs in ordered]


# --- levels -------------------------------------------------------------------

LEVELS = ("lite", "standard", "full")
LEVEL_FILE = "level"
# The sections of a Feature Profile a person writes. 4 (How It Works) and 9 (Quick
# Reference) are generated from the tree, so a prompt left in them says nothing
# about whether anyone has described the feature.
NARRATIVE_SECTIONS = (1, 2, 3, 5, 6, 7, 8)
SECTION_RX = re.compile(r"^##\s+(\d+)\.\s")
# `wo close` counts unfilled template prompts exactly this way — square-bracket
# prompts outside fenced code — and the two must agree, or a profile that passes
# one gate fails the other for no reason a reader can see.
BRACKET_RX = re.compile(r"\[[A-Za-z][^\]]{2,}\]")
FM_RX = re.compile(r"\A---\n(.*?)\n---\n", re.S)
BADGES = ("undocumented", "described", "validated")


def frontmatter(text):
    """{key: value} for the document's YAML frontmatter, flat scalars only. The
    keys this tool reads are all scalars; anything else is left to a real parser."""
    m = FM_RX.match(text)
    if not m:
        return {}
    out = {}
    for line in m.group(1).split("\n"):
        k, sep, v = line.partition(":")
        if sep and re.match(r"^[A-Za-z_][\w-]*$", k.strip()):
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def set_frontmatter(text, key, value):
    """Set one frontmatter key in place, adding it before the closing marker when
    it is absent. A document with no frontmatter is returned untouched: inventing
    one would rewrite someone else's file."""
    m = FM_RX.match(text)
    if not m:
        return text
    body, line = m.group(1), f"{key}: {value}"
    if re.search(rf"(?m)^{re.escape(key)}\s*:", body):
        body = re.sub(rf"(?m)^{re.escape(key)}\s*:.*$", line, body, count=1)
    else:
        body = body + "\n" + line
    return "---\n" + body + "\n---\n" + text[m.end():]


def narrative_prompts(text):
    """How many bracketed writing prompts are still unanswered in the sections a
    person writes. Fenced code is skipped, so a prompt quoted in an example does
    not read as one left unwritten."""
    n, cur, code = 0, None, False
    for line in text.split("\n"):
        if line.startswith("```"):
            code = not code
            continue
        if code:
            continue
        if line.startswith("## "):
            m = SECTION_RX.match(line)
            cur = int(m.group(1)) if m else None
            continue
        if cur in NARRATIVE_SECTIONS:
            n += len(BRACKET_RX.findall(line))
    return n


def template_path(name):
    """A template ships beside the engine, at <pipeline>/core/templates/docs/."""
    return os.path.join(HERE, "..", "templates", "docs", name)


def template_budget():
    """The prompt count of the shipped template, for profiles written before the
    scaffold existed and so carrying no `scaffold_prompts`. None when the template
    cannot be read: an unknown budget reports nothing rather than guessing."""
    t = read(template_path("feature-profile.md"))
    return narrative_prompts(t) if t else None


def level_of(kb, override):
    """--level wins; otherwise the level the scaffold recorded; otherwise lite."""
    if override:
        return override
    v = read(os.path.join(kb, LEVEL_FILE)).strip()
    return v if v in LEVELS else "lite"


def badge_of(text, budget):
    """The status matrix's three badges, read off one profile."""
    fm = frontmatter(text)
    if fm.get("validated", "").lower() == "true" and fm.get("reviewed-by", "N/A").strip() not in ("", "N/A"):
        return "validated"
    b = fm.get("scaffold_prompts")
    try:
        b = int(b)
    except (TypeError, ValueError):
        b = budget
    if b is None:
        return "described"
    return "undocumented" if narrative_prompts(text) * 2 > b else "described"


def level_shortfall(name, text, level, budget):
    """Why this document falls short of the level, or None. Only the Feature
    Profiles are judged: the survey and the matrix are generated, and have no
    narrative sections for anyone to leave unwritten."""
    if level == "lite" or not name.startswith("profiles/"):
        return None
    fm = frontmatter(text)
    b = fm.get("scaffold_prompts")
    try:
        b = int(b)
    except (TypeError, ValueError):
        b = budget
    if b is not None:
        left = narrative_prompts(text)
        # More than half the prompts the scaffold wrote still standing: this is
        # the template with a title on it, the same bar `wo close` applies.
        if left * 2 > b:
            return f"{left} of {b} writing prompts unanswered — the narrative is still the scaffold"
    if level == "full":
        if fm.get("validated", "").lower() != "true":
            return "frontmatter says validated: false — nobody has checked it against the source"
        if fm.get("reviewed-by", "N/A").strip() in ("", "N/A"):
            return "frontmatter reviewed-by is N/A — no reviewer is named"
    return None


# --- the scaffold: the knowledge base the tool builds for itself ---------------

FEATURE_CAP = 60
EVIDENCE_CAP = 200
SCAFFOLD_MARK = "<!-- acp:kb-scaffold -->"
UNWRITTEN = "[Unwritten at scaffold — replace this line with what the prompt above asks for.]"
DEFAULT_PIPELINE_DIR = ".aicodepipeline"

# Where a project keeps the code it wrote. The root itself is the fallback for a
# flat repository that uses none of these.
CONVENTIONAL_ROOTS = ("src", "app", "lib", "services", "modules", "features", "pkg", "cmd", "internal")
CONVENTIONAL_NESTED = (("apps", "src"), ("packages", "src"))
# A test states what the code should do; the claim belongs on the code, so tests
# are cited by the profile describing what they test and are not features of their own.
TEST_DIRS = {"test", "tests", "__tests__", "spec", "specs", "e2e", "__mocks__", "fixtures", "testdata"}
# Code this project did not write, or did not write by hand.
GENERATED_DIRS = {"vendor", "third_party", "generated", "gen", "out", "target", "bin", "obj"}
MANIFESTS = ("package.json", "pyproject.toml", "requirements.txt", "go.mod", "Cargo.toml",
             "Gemfile", "composer.json", "pom.xml", "build.gradle", "pubspec.yaml", "Package.swift")

ENDPOINT_RX = re.compile(
    r"@(?:Get|Post|Put|Patch|Delete|Head|Options|All)\s*\("              # Nest, Spring
    r"|@(?:app|router|bp|blueprint)\.(?:route|get|post|put|patch|delete|websocket)\b"  # Flask, FastAPI
    r"|\b(?:router|app|server)\.(?:get|post|put|patch|delete|all)\s*\("  # Express, Koa
    r"|\bhttp\.HandleFunc\s*\("                                          # Go
    r"|\bRoute::[A-Za-z]+"                                               # Laravel
    r"|^\s*(?:get|post|put|patch|delete)\s+['\"]/"                       # Sinatra, Rails
)
ROUTE_PATH_RX = re.compile(r"""['"`](/[^'"`]*)['"`]""")
MODEL_DIRS = {"models", "model", "entities", "entity", "migrations", "migration", "schema", "schemas"}
MODEL_FILE_RX = re.compile(r"(\.entity\.(ts|js|tsx)$|^schema\.prisma$|^models?\.(py|ts|js|rb|go)$)")
DJANGO_MODEL_RX = re.compile(r"^\s*class\s+\w+\s*\(\s*[\w.]*models\.Model\s*\)")
DECL_RX = re.compile(r"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?"
                     r"(?:class|interface|type|struct|model|def|CREATE TABLE|@Entity|@Table)\b", re.I)
SLUG_NOISE = {"src", "app", "apps", "lib", "packages", "pkg", "cmd", "internal", "services", "modules", "features"}


def skip_feature_dir(name, full, kb):
    """The directories feature discovery walks past: the ones no rule reads, the
    tests, the vendored and generated output, the knowledge base, and any
    installed pipeline (detected by what it holds, not by its name)."""
    if name.startswith(".") or name in SKIP_DIRS or name in TEST_DIRS or name in GENERATED_DIRS:
        return True
    if os.path.realpath(full) == kb:
        return True
    # The pipeline's own document folders are its working documents, not a feature, even when a helper script is kept
    # there. A conventional code root stays a candidate whatever it holds, and a code folder that merely contains the
    # knowledge base (server/ for server/docs/kb) is walked: only the folders named below are passed over.
    if os.path.realpath(full) in DOC_DIRS and name not in CONVENTIONAL_ROOTS \
            and name not in {parent for parent, _child in CONVENTIONAL_NESTED}:
        return True
    return is_pipeline_dir(full)


DOC_DIRS = set()
DOC_DIR_SETTINGS = (("WORKSPACE_DIR", "Workspace"), ("DOCS_DIR", "Workspace/Docs"))


def set_doc_dirs(root, kb):
    """The pipeline's own document folders: the folder that holds the knowledge base, and the workspace and documents
    folders the project's pipeline.config.sh names (WORKSPACE_DIR, DOCS_DIR), from the environment, else from that file,
    else the defaults. The project root is never one of them."""
    cfg = read(os.path.join(root, "pipeline.config.sh"))
    dirs = {os.path.dirname(kb)}
    for var, default in DOC_DIR_SETTINGS:
        m = re.search(r'^\s*export\s+' + var + r'="([^"]*)"', cfg, re.M)
        v = os.environ.get(var) or (m.group(1) if m else default)
        if v:
            dirs.add(v if os.path.isabs(v) else os.path.join(root, v))
    DOC_DIRS.clear()
    DOC_DIRS.update(os.path.realpath(d) for d in dirs if os.path.realpath(d) != os.path.realpath(root))


def dir_entries(d, kb):
    """(direct source files, walkable subdirectories) for one directory, sorted."""
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return [], []
    files, dirs = [], []
    for n in names:
        full = os.path.join(d, n)
        if os.path.isdir(full):
            if not skip_feature_dir(n, full, kb):
                dirs.append(n)
        elif os.path.splitext(n)[1] in SOURCE_EXT:
            files.append(n)
    return files, dirs


def source_under(d, kb, depth=0):
    """Every source file under one directory, absolute, sorted, depth-limited so a
    symlink loop cannot become an infinite walk."""
    if depth > 24:
        return []
    files, dirs = dir_entries(d, kb)
    out = [os.path.join(d, f) for f in files]
    for x in dirs:
        out.extend(source_under(os.path.join(d, x), kb, depth + 1))
    return sorted(out)


def grouping_level(d, kb):
    """The first level below a conventional root that groups anything: a directory
    holding two or more source files, or branching into two or more directories
    that do. `src/main/java/com/acme/` is four wrappers around one package, and
    calling each of them a feature would describe the build layout, not the system."""
    for _ in range(12):
        files, dirs = dir_entries(d, kb)
        kids = [x for x in dirs if source_under(os.path.join(d, x), kb)]
        if len(files) >= 2 or len(kids) >= 2 or (files and kids) or not kids:
            return d
        d = os.path.join(d, kids[0])
    return d


def feature_units(root, kb):
    """[(directory, [source files])] — the candidate features, one per directory
    that holds code, grouped at the level that groups. Disjoint by construction:
    a unit owns the files below it, and a unit's own direct files form a unit of
    their own when its children are units too."""
    roots = []
    for name in CONVENTIONAL_ROOTS:
        p = os.path.join(root, name)
        if os.path.isdir(p) and not skip_feature_dir(name, p, kb):
            roots.append(p)
    for parent, child in CONVENTIONAL_NESTED:
        pp = os.path.join(root, parent)
        if not os.path.isdir(pp):
            continue
        try:
            names = sorted(os.listdir(pp))
        except OSError:
            continue
        for x in names:
            q = os.path.join(pp, x, child)
            if os.path.isdir(q) and not skip_feature_dir(x, os.path.join(pp, x), kb):
                roots.append(q)
    if not roots:
        roots = [root]

    units, seen = [], set()
    def add(d, files):
        key = os.path.realpath(d)
        if files and key not in seen:
            seen.add(key)
            units.append((d, sorted(files)))
    for r in roots:
        g = grouping_level(r, kb)
        files, dirs = dir_entries(g, kb)
        kids = [os.path.join(g, x) for x in dirs if source_under(os.path.join(g, x), kb)]
        for k in kids:
            add(k, source_under(k, kb))
        if files:
            add(g, [os.path.join(g, f) for f in files])
    if not units:
        # A tree that fits none of the conventions still has code in it somewhere.
        add(root, source_under(root, kb))
    return units


def feature_slug(root, d, taken):
    """A file name for the profile: the unit's path with the conventional wrappers
    dropped, so `apps/web/src/auth` reads as `web-auth` and `src/auth` as `auth`."""
    rel = rel_to(root, d)
    parts = [p for p in rel.split("/") if p not in (".", "")]
    kept = [p for p in parts if p not in SLUG_NOISE] or parts or [os.path.basename(root) or "root"]
    s = re.sub(r"[^a-z0-9._-]+", "-", "-".join(kept).lower()).strip("-._") or "feature"
    base, n = s, 2
    while s in taken:
        s = f"{base}-{n}"
        n += 1
    taken.add(s)
    return s


def title_of(slug):
    return " ".join(w.capitalize() for w in re.split(r"[-_.]+", slug) if w) or "Feature"


def cite(root, path, line=1):
    """A citation to a line that is there. A citation past the end of the file is
    what `status` calls broken, so the scaffold clamps rather than writes one, and
    an empty file, which has no line to cite, gets a note instead of a citation."""
    rp = rel_to(root, path)
    n = line_count(path)
    if not n:
        return "(an empty file, nothing to cite)"
    return f"<!-- SOURCE: {rp}:L{max(1, min(int(line), n))} -->"


def first_citable(files):
    """The first file with a line in it, so a feature's own citation is never an empty
    package marker; the first file when every one is empty."""
    return next((f for f in files if line_count(f)), files[0])


def first_decl_line(path):
    """The line a reader would open the file at: its first declaration, else 1."""
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            for i, line in enumerate(f, 1):
                if DECL_RX.match(line):
                    return i
                if i > 400:
                    break
    except OSError:
        pass
    return 1


def scan_evidence(root, files):
    """Endpoints and data models, read out of the files themselves. Heuristic by
    construction: it recognises the route and model spellings listed above and
    nothing else, so what it finds is a floor, not an inventory."""
    endpoints, models = [], []
    for path in files:
        rp = rel_to(root, path)
        segs = set(os.path.dirname(rp).split("/"))
        base = os.path.basename(rp)
        model_file = bool(segs & MODEL_DIRS) or bool(MODEL_FILE_RX.search(base))
        django = False
        try:
            with open(path, encoding="utf-8", errors="ignore") as f:
                for i, line in enumerate(f, 1):
                    if len(endpoints) < EVIDENCE_CAP and ENDPOINT_RX.search(line):
                        m = ROUTE_PATH_RX.search(line)
                        endpoints.append({"file": rp, "line": i, "path": m.group(1) if m else "—",
                                          "marker": ENDPOINT_RX.search(line).group(0).strip()})
                    if not django and DJANGO_MODEL_RX.match(line):
                        django = True
                        if len(models) < EVIDENCE_CAP:
                            models.append({"file": rp, "line": i, "why": "Django model class"})
                    if i > 5000:
                        break
        except OSError:
            continue
        if model_file and not django and len(models) < EVIDENCE_CAP:
            why = "schema definition" if base == "schema.prisma" else (
                  "entity declaration" if base.endswith((".entity.ts", ".entity.js")) else
                  "under a models, entities, migrations, or schema directory")
            models.append({"file": rp, "line": first_decl_line(path), "why": why})
    endpoints.sort(key=lambda e: (e["file"], e["line"]))
    models.sort(key=lambda m: (m["file"], m["line"]))
    return endpoints, models


def find_manifest(root):
    for m in MANIFESTS:
        p = os.path.join(root, m)
        if os.path.isfile(p):
            return p
    return None


def manifest_line(path, key):
    """The line a key is declared on, so a claim read out of a manifest cites the
    place it was read from rather than the top of the file."""
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            for i, line in enumerate(f, 1):
                if re.search(r'["\']?' + re.escape(key) + r'["\']?\s*[:=]', line):
                    return i
    except OSError:
        pass
    return 1


def detect_stack(root, pipeline_dir):
    """detect-stack already knows how to read a project; asking it keeps one answer
    to 'what is this built with'. Its absence is a null, not a failure."""
    for exe in (os.path.join(root, pipeline_dir, "bin", "detect-stack"),
                os.path.join(HERE, "..", "..", "bin", "detect-stack")):
        if not os.path.isfile(exe):
            continue
        try:
            r = subprocess.run([sys.executable, exe, root, "--json"],
                               capture_output=True, text=True, timeout=120)
            if r.returncode == 0:
                return json.loads(r.stdout)
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
    return {}


def tree_hash(root, pipeline_dir, files):
    """The driver's own fingerprint when the pipeline is installed here, so the
    survey and a work order's evidence name the same tree; otherwise a hash of the
    file list, which at least changes when the layout does."""
    exe = os.path.join(root, pipeline_dir, "bin", "wo")
    if os.path.isfile(exe):
        try:
            r = subprocess.run([exe, "fingerprint"], cwd=root, capture_output=True, text=True, timeout=180)
            v = (r.stdout or "").strip().splitlines()
            if r.returncode == 0 and v and re.match(r"^[0-9a-f]{12,64}$", v[-1]):
                return v[-1]
        except (OSError, subprocess.SubprocessError):
            pass
    return hashlib.sha256("\n".join(sorted(files)).encode("utf-8")).hexdigest()[:16]


def entry_points(root):
    """[(what, how it is declared, path, line)] — the ways into the program."""
    out = []
    pkg = os.path.join(root, "package.json")
    if os.path.isfile(pkg):
        try:
            data = json.loads(read(pkg))
        except ValueError:
            data = {}
        if isinstance(data.get("main"), str):
            out.append(("main", f"`{data['main']}`", pkg, manifest_line(pkg, "main")))
        b = data.get("bin")
        if isinstance(b, str):
            out.append(("bin", f"`{b}`", pkg, manifest_line(pkg, "bin")))
        elif isinstance(b, dict):
            for k in sorted(b):
                out.append((f"bin {k}", f"`{b[k]}`", pkg, manifest_line(pkg, k)))
        s = data.get("scripts")
        if isinstance(s, dict):
            for k in sorted(s):
                out.append((f"script `{k}`", f"`{str(s[k])[:80]}`", pkg, manifest_line(pkg, k)))
    for name in ("main.go", "__main__.py", "main.py", "manage.py", "index.js", "index.ts", "app.py", "Program.cs"):
        for d in (root, os.path.join(root, "src"), os.path.join(root, "cmd"), os.path.join(root, "app")):
            p = os.path.join(d, name)
            if os.path.isfile(p):
                out.append((f"`{rel_to(root, p)}`", "program entry file", p, first_decl_line(p)))
    return out[:60]


def dependencies(root, manifest):
    """[(name, version, path, line)] straight out of the manifest, in its own order."""
    if not manifest:
        return []
    base, out = os.path.basename(manifest), []
    text = read(manifest)
    if base == "package.json":
        try:
            data = json.loads(text)
        except ValueError:
            data = {}
        for section in ("dependencies", "devDependencies"):
            for k in sorted((data.get(section) or {}) if isinstance(data.get(section), dict) else {}):
                out.append((k, str(data[section][k]), manifest, manifest_line(manifest, k)))
    elif base == "requirements.txt":
        for i, line in enumerate(text.split("\n"), 1):
            s = line.strip()
            if s and not s.startswith("#"):
                m = re.match(r"^([A-Za-z0-9._-]+)\s*(.*)$", s)
                if m:
                    out.append((m.group(1), m.group(2) or "unpinned", manifest, i))
    elif base == "go.mod":
        for i, line in enumerate(text.split("\n"), 1):
            m = re.match(r"^\s*(?:require\s+)?([a-z0-9][\w./-]*\.[\w./-]+)\s+(v\S+)", line)
            if m:
                out.append((m.group(1), m.group(2), manifest, i))
    elif base in ("Cargo.toml", "pyproject.toml"):
        section = ""
        for i, line in enumerate(text.split("\n"), 1):
            s = line.strip()
            if s.startswith("["):
                section = s
                continue
            if "dependencies" in section:
                m = re.match(r'^([A-Za-z0-9._-]+)\s*=\s*(.+)$', s)
                if m:
                    out.append((m.group(1), m.group(2)[:60], manifest, i))
    else:
        out.append((base, "manifest on file", manifest, 1))
    return out[:80]


# --- the documents the scaffold writes ----------------------------------------

def fm_block(fields):
    return "---\n" + "".join(f"{k}: {v}\n" for k, v in fields) + "---\n"


def split_sections(text):
    """(everything before section 1, {number: [lines of that section, heading first]})
    for a template written as `## 1. Heading`."""
    head, sections, cur = [], {}, None
    for line in text.split("\n"):
        m = SECTION_RX.match(line) if line.startswith("## ") else None
        if m:
            cur = int(m.group(1))
            sections[cur] = [line]
            continue
        (sections[cur] if cur is not None else head).append(line)
    return "\n".join(head), sections


def strip_rule(lines):
    """Drop a section's trailing horizontal rule, so generated content lands inside
    the section rather than after the line that ends it."""
    out = list(lines)
    while out and (out[-1].strip() == "" or out[-1].strip() == "---"):
        out.pop()
    return out


def insert_prompt(section_lines):
    """Put the scaffold's own bracketed prompt directly after the section's writing
    prompt, so what is unwritten is visible in the document and countable from it."""
    out, placed = [], False
    for i, line in enumerate(section_lines):
        out.append(line)
        if not placed and line.rstrip().endswith("-->"):
            out.append("")
            out.append(UNWRITTEN)
            placed = True
    if not placed:
        out = [section_lines[0], "", UNWRITTEN] + section_lines[1:]
    return out


def build_profile(root, tpl, slug, unit_dir, files, endpoints, models, today):
    """One Feature Profile: the template's nine sections, with 4 and 9 filled in
    from the tree and the rest left as the prompts they are until someone writes
    them. Everything generated carries the file and line it was read from."""
    name, rel_dir = title_of(slug), rel_to(root, unit_dir)
    first = first_citable(files)
    head, sections = split_sections(tpl)
    # `src/billing` belongs to Billing, not to src: the wrapper directory names the
    # layout, and only a multi-part slug (apps/web/src/auth) carries a real grouping.
    parts = slug.split("-")
    domain = title_of(parts[0]) if len(parts) > 1 else name

    head = head.replace('title: "[Feature name] — Feature Profile"', f'title: "{name} — Feature Profile"')
    head = head.replace("# [Feature name] — Feature Profile", f"# {name} — Feature Profile")
    head = head.replace("**Capability domain:** [domain this feature belongs to]",
                        f"**Capability domain:** {domain}")
    head = head.replace("**Status:** [badge from the feature status matrix]", "**Status:** `undocumented`")
    head = re.sub(r"\A---\n.*?\n---\n", "", head, flags=re.S)
    head = head.replace("\n**Capability domain:**", f"\n**Scaffolded from:** `{rel_dir}` — "
                        f"{len(files)} source file(s). {cite(root, first, 1)}\n**Capability domain:**", 1)

    chunks = []
    for n in sorted(sections):
        lines = sections[n]
        if n in NARRATIVE_SECTIONS:
            lines = insert_prompt(lines)
        elif n == 4:
            lines = strip_rule(lines) + ["", "### Files in this feature — read by the scaffold", "",
                             "| File | Lines | Source |", "|---|---|---|"]
            for f in files[:80]:
                lines.append(f"| `{rel_to(root, f)}` | {line_count(f)} | {cite(root, f, 1)} |")
            if len(files) > 80:
                lines.append(f"| … and {len(files) - 80} more under `{rel_dir}` | | {cite(root, first, 1)} |")
            lines += ["", "### Endpoints under this feature", ""]
            mine = [e for e in endpoints if e["file"].startswith(rel_dir + "/") or e["file"] == rel_dir]
            if mine:
                lines += ["| Marker | Path | Source |", "|---|---|---|"]
                for e in mine[:60]:
                    lines.append(f"| `{e['marker']}` | `{e['path']}` | "
                                 f"{cite(root, os.path.join(root, e['file']), e['line'])} |")
            else:
                lines.append("The scaffold's route patterns matched nothing under this directory.")
            lines += ["", "### Data models under this feature", ""]
            mym = [m for m in models if m["file"].startswith(rel_dir + "/") or m["file"] == rel_dir]
            if mym:
                lines += ["| File | Why it reads as a model | Source |", "|---|---|---|"]
                for m in mym[:60]:
                    lines.append(f"| `{m['file']}` | {m['why']} | {cite(root, os.path.join(root, m['file']), m['line'])} |")
            else:
                lines.append("The scaffold's model patterns matched nothing under this directory.")
            lines += ["", "---"]
        elif n == 9:
            paths = ", ".join(f"`{rel_to(root, f)}`" for f in files[:8])
            if len(files) > 8:
                paths += f", and {len(files) - 8} more"
            lines = [lines[0], "", "| Item | Value |", "|---|---|",
                     f"| Module | `{rel_dir}` |",
                     f"| Source paths | {paths} |",
                     "| Configuration keys | Not read by the scaffold; fill this in when the narrative is written |",
                     "| Dependencies | Declared in the manifest; see the survey's dependency table |",
                     f"| Administrative surface | {len(mine_count(endpoints, rel_dir))} endpoint(s), "
                     f"{len(mine_count(models, rel_dir))} data model file(s) |",
                     "| Status | `undocumented` |", "",
                     "<!-- Every source path here must also appear in the work order's",
                     "     source-reference index. -->"]
        chunks.append("\n".join(lines).strip("\n"))

    text = (SCAFFOLD_MARK + "\n\n" + head.strip("\n") + "\n\n"
            + "\n\n".join(chunks).rstrip("\n") + "\n")
    prompts = narrative_prompts(text)
    fm = fm_block([("wo", "N/A"), ("title", f'"{name} — Feature Profile"'), ("version", "1.0"),
                   ("status", "SCAFFOLD"), ("created", today), ("last-modified", today),
                   ("reviewed-by", "N/A"), ("feature", slug), ("level", "lite"),
                   ("scaffolded", today), ("scaffold_prompts", str(prompts)), ("validated", "false")])
    return fm + "\n" + text


def mine_count(items, rel_dir):
    return [x for x in items if x["file"].startswith(rel_dir + "/") or x["file"] == rel_dir]


def build_analysis(root, today, level, ctx):
    """The structural survey: prose and tables, every factual line ending in the
    file and line it was read from."""
    name = os.path.basename(root) or "This repository"
    stack, manifest, units = ctx["stack"], ctx["manifest"], ctx["units"]
    man_rel = rel_to(root, manifest) if manifest else None
    L = []
    w = L.append
    w(fm_block([("wo", "N/A"), ("title", f'"{name} — Repository Analysis"'), ("version", "1.0"),
                ("status", "SCAFFOLD"), ("created", today), ("last-modified", today),
                ("reviewed-by", "N/A"), ("level", level), ("scaffolded", today)]))
    w(SCAFFOLD_MARK)
    w("")
    w(f"# {name} — Repository Analysis")
    w("")
    w("This is the structural survey the knowledge-base scaffold reads out of the tree: what is")
    w("here, where it lives, and which file and line each line below was read from. It is the")
    w("floor the description stands on, not the description — the Feature Profiles under")
    w("`profiles/` carry that, and while their narrative sections are unwritten the status matrix")
    w("shows them as `undocumented`.")
    w("")
    w("---")
    w("")
    w("## 1. Stack and package manager")
    w("")
    if manifest:
        langs = ", ".join(stack.get("languages") or []) or "none the detector recognised"
        fws = ", ".join(stack.get("frameworks") or []) or "none the detector recognised"
        pm = stack.get("package_manager") or "none the detector recognised"
        w(f"- Languages: {langs}. {cite(root, manifest, 1)}")
        w(f"- Frameworks: {fws}. {cite(root, manifest, 1)}")
        w(f"- Package manager: {pm}. {cite(root, manifest, 1)}")
        w(f"- Package manifest: `{man_rel}`, {line_count(manifest)} line(s). {cite(root, manifest, 1)}")
    else:
        first = first_citable(units[0]["files"]) if units else None
        w(f"- No package manifest of a shape the detector reads sits at the root, so the stack below is")
        w(f"  read from the file extensions alone." + (f" {cite(root, first, 1)}" if first else ""))
        if stack.get("languages"):
            w(f"- Languages: {', '.join(stack['languages'])}." + (f" {cite(root, first, 1)}" if first else ""))
    w("")
    w("---")
    w("")
    w("## 2. Layout — the feature units")
    w("")
    w(f"A feature unit is a directory holding source files under a conventional root. "
      f"{len(units)} were found, each with a profile under `profiles/`.")
    if ctx["capped"]:
        w("")
        w(f"The scaffold caps discovery at {FEATURE_CAP} feature units and {ctx['found']} were found, so the "
          f"{FEATURE_CAP} holding the most source files are profiled here and the rest are not. Raise the "
          f"grouping by describing a parent directory, or profile the remainder by hand.")
    w("")
    w("| Feature | Directory | Source files | Lines | Profile | Source |")
    w("|---|---|---|---|---|---|")
    for u in units:
        w(f"| {title_of(u['slug'])} | `{rel_to(root, u['dir'])}` | {len(u['files'])} | "
          f"{sum(line_count(f) for f in u['files'])} | `profiles/{u['slug']}.md` | {cite(root, first_citable(u['files']), 1)} |")
    w("")
    w("---")
    w("")
    w("## 3. Entry points")
    w("")
    if ctx["entries"]:
        w("| Entry point | Declared as | Source |")
        w("|---|---|---|")
        for what, how, path, line in ctx["entries"]:
            w(f"| {what} | {how} | {cite(root, path, line)} |")
    else:
        w("No manifest entry point, `main.go`, `__main__.py`, or root index file was found by the scaffold.")
    w("")
    w("---")
    w("")
    w("## 4. Endpoints")
    w("")
    w(f"Read by matching route decorators and handler registrations, so this is a floor rather than "
      f"a complete API surface: {len(ctx['endpoints'])} found"
      f"{f', capped at {EVIDENCE_CAP}' if len(ctx['endpoints']) >= EVIDENCE_CAP else ''}.")
    w("")
    if ctx["endpoints"]:
        w("| Marker | Path | File | Source |")
        w("|---|---|---|---|")
        for e in ctx["endpoints"]:
            w(f"| `{e['marker']}` | `{e['path']}` | `{e['file']}` | {cite(root, os.path.join(root, e['file']), e['line'])} |")
    else:
        w("None of the route patterns the scaffold knows matched anything in this tree.")
    w("")
    w("---")
    w("")
    w("## 5. Data models")
    w("")
    w(f"Read by directory convention, file naming, and declaration shape: {len(ctx['models'])} found"
      f"{f', capped at {EVIDENCE_CAP}' if len(ctx['models']) >= EVIDENCE_CAP else ''}.")
    w("")
    if ctx["models"]:
        w("| File | Why it reads as a model | Source |")
        w("|---|---|---|")
        for m in ctx["models"]:
            w(f"| `{m['file']}` | {m['why']} | {cite(root, os.path.join(root, m['file']), m['line'])} |")
    else:
        w("None of the model patterns the scaffold knows matched anything in this tree.")
    w("")
    w("---")
    w("")
    w("## 6. Dependencies")
    w("")
    if ctx["deps"]:
        w(f"Declared in `{man_rel}`, as written there.")
        w("")
        w("| Dependency | Version | Source |")
        w("|---|---|---|")
        for n_, v_, p_, l_ in ctx["deps"]:
            w(f"| `{n_}` | `{v_}` | {cite(root, p_, l_)} |")
    else:
        w("No dependency declaration of a shape the scaffold reads was found.")
    w("")
    w("---")
    w("")
    w("## 7. What was not read, and why")
    w("")
    for cat, example in ctx["skipped"]:
        w(f"- {cat} {cite(root, example, 1)}")
    w("- Directories the rules skip everywhere — vendored dependencies, build output, virtual")
    w("  environments, and any installed copy of the pipeline — hold code this project did not")
    w("  write, so nothing in them is a feature of this repository.")
    w("- Test directories are cited by the profile describing the code under test rather than")
    w("  profiled themselves: a test says what the code should do, and that claim belongs on the code.")
    w("")
    w("---")
    w("")
    w("## 8. Provenance")
    w("")
    w("| Field | Value |")
    w("|---|---|")
    w(f"| Scaffold level | `{level}` |")
    w(f"| Generated | {today} |")
    w(f"| Tree hash | `{ctx['tree']}` |")
    w(f"| Feature units | {len(units)} |")
    w(f"| Endpoints | {len(ctx['endpoints'])} |")
    w(f"| Data models | {len(ctx['models'])} |")
    w("")
    w(f"This survey was generated by the knowledge-base scaffold at level `{level}` on {today} against "
      f"tree hash `{ctx['tree']}`.")
    return "\n".join(L).rstrip("\n") + "\n"


def build_empty_analysis(root, today, level):
    """A tree with no source in it yet. Saying so plainly is a true description;
    failing for the absence of profiles would make the step one nobody can pass."""
    name = os.path.basename(root) or "This repository"
    return (fm_block([("wo", "N/A"), ("title", f'"{name} — Repository Analysis"'), ("version", "1.0"),
                      ("status", "SCAFFOLD"), ("created", today), ("last-modified", today),
                      ("reviewed-by", "N/A"), ("level", level), ("scaffolded", today)])
            + f"\n{SCAFFOLD_MARK}\n<!-- acp:kb-scaffold empty -->\n\n"
            + f"# {name} — Repository Analysis\n\n"
            + "There is no source yet: the scaffold walked the tree and found no source file outside\n"
              "the directories the rules skip, so there is nothing here to describe.\n\n"
              "The knowledge base grows as work orders close. Each closing work order adds the\n"
              "profiles for the code it introduced, and re-running `acp kb scaffold` picks up every\n"
              "feature unit that exists by then. Nothing needs to be written by hand first.\n\n"
              "---\n\n## Provenance\n\n| Field | Value |\n|---|---|\n"
            + f"| Scaffold level | `{level}` |\n| Generated | {today} |\n| Feature units | 0 |\n\n"
            + f"This survey was generated by the knowledge-base scaffold at level `{level}` on {today}; "
              "the tree held no source to survey.\n")


def build_matrix(root, today, level, units, badges):
    name = os.path.basename(root) or "This repository"
    L = [fm_block([("wo", "N/A"), ("title", f'"{name} — Feature Status Matrix"'), ("version", "1.0"),
                   ("status", "SCAFFOLD"), ("created", today), ("last-modified", today),
                   ("reviewed-by", "N/A"), ("level", level), ("scaffolded", today)]),
         SCAFFOLD_MARK, "",
         f"# {name} — Feature Status Matrix", "",
         "**Scope:** every feature unit the knowledge-base scaffold found in this tree, one row each.",
         f"**Total features assessed:** {len(units)}", "", "---", "", "## Status Legend", "",
         "| Badge | Status | Definition |", "|---|---|---|",
         "| `undocumented` | Scaffolded, not described | A profile exists and its structure is filled in "
         "from the tree; more than half the scaffold's writing prompts are still standing, so the "
         "narrative has not been written |",
         "| `described` | Narrative written | The writing prompts have been answered; no second reader "
         "has checked the profile against the source |",
         "| `validated` | Reviewed against source | The profile's frontmatter carries `validated: true` "
         "and names a reviewer in `reviewed-by` |", "",
         "<!-- The badge is read off each profile, not set by hand: a badge typed into this table would",
         "     say whatever its typist believed on the day. Re-run  acp kb scaffold  to refresh it. -->",
         "", "---", "", "## Domain: every feature unit", "",
         "| Feature | Status | Profile | Source files | Source |", "|---|---|---|---|---|"]
    for u in units:
        L.append(f"| {title_of(u['slug'])} | `{badges.get(u['slug'], 'undocumented')}` | "
                 f"`profiles/{u['slug']}.md` | {len(u['files'])} | {cite(root, first_citable(u['files']), 1)} |")
    if not units:
        L.append("| — | — | — | 0 | — |")
        L.append("")
        L.append("No feature unit exists yet. The knowledge base grows as work orders close.")
    counts = {b: sum(1 for u in units if badges.get(u["slug"], "undocumented") == b) for b in BADGES}
    total = len(units) or 1
    L += ["", "---", "", "## Summary Statistics", "", "| Status | Count | Percentage |", "|---|---|---|"]
    for b in BADGES:
        L.append(f"| `{b}` | {counts[b]} | {round(counts[b] * 100 / total)}% |")
    L += ["", "---", "", "## Readiness Assessment", "",
          "| Audience | Readiness | Justification |", "|---|---|---|",
          f"| A session that needs context | {'Scaffold only' if counts['undocumented'] else 'Described'} | "
          f"{counts['undocumented']} of {len(units)} profiles still carry the scaffold's writing prompts |",
          f"| A reader acting on a claim | {'Unvalidated' if counts['validated'] < len(units) else 'Validated'} | "
          f"{counts['validated']} of {len(units)} profiles name a reviewer |", ""]
    return "\n".join(L).rstrip("\n") + "\n"


# --- the scaffold command -------------------------------------------------------

def read_index_rows(kb):
    """{path relative to root: (hash, {citing profiles})} — the index as write_index
    wants it back, so a row can be carried forward unchanged."""
    out = {}
    try:
        for line in open(index_path(kb), encoding="utf-8", errors="ignore"):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 2:
                out[parts[0]] = (parts[1], set(x for x in (parts[2].split(",") if len(parts) > 2 else []) if x))
    except OSError:
        pass
    return out


def cited_rows(kb, root, names):
    """{path: (hash, {profiles})} for a set of profile documents."""
    rows = {}
    for name in names:
        path = os.path.join(kb, name.replace("/", os.sep))
        for _ref, _hi, found in citations(path, root):
            if not found:
                continue
            key = rel_to(root, os.path.realpath(found))
            rows.setdefault(key, [hash_of(found), set()])[1].add(name)
    return {p: (h, s) for p, (h, s) in rows.items()}


def is_empty_kb(kb):
    """A knowledge base the scaffold wrote for a tree that had nothing in it: the
    index exists with no rows, and the survey says as much. Distinct from no
    knowledge base at all, which is what exit 3 reports."""
    if not os.path.isfile(index_path(kb)) or read_index(kb):
        return False
    return any("<!-- acp:kb-scaffold empty -->" in read(p) for p in md_docs(kb))


def scan_skipped(root, kb):
    """[(sentence, example file)] for the skipped categories actually present in
    this tree, so section 7 cites what it passed over instead of reciting a policy.
    One example per category is enough, and the category is pruned once found — a
    walk through node_modules to collect a second example would cost minutes."""
    found, cats = {}, ("tests", "vendored, generated, or build output")
    for d, dirs, files in os.walk(root):
        base = os.path.basename(d)
        if base == ".git" or os.path.realpath(d) == kb or is_pipeline_dir(d):
            dirs[:] = []
            continue
        cat = (cats[0] if base in TEST_DIRS else
               cats[1] if (base in GENERATED_DIRS or base in SKIP_DIRS) else None)
        if cat is None:
            dirs[:] = sorted(dirs)
            continue
        dirs[:] = []
        if cat in found:
            continue
        ex = next((os.path.join(d, f) for f in sorted(files) if os.path.splitext(f)[1] in SOURCE_EXT), None)
        if ex:
            found[cat] = (f"`{rel_to(root, d)}` was passed over as {cat}: it is cited by the profile "
                          f"describing the code it covers rather than profiled as a feature itself.", ex)
    return [found[k] for k in cats if k in found]


def discover(root, kb, pipeline_dir):
    """Everything the scaffold reads before it writes anything."""
    raw = feature_units(root, kb)
    found = len(raw)
    capped = found > FEATURE_CAP
    if capped:
        raw = sorted(raw, key=lambda u: (-len(u[1]), u[0]))[:FEATURE_CAP]
    raw.sort(key=lambda u: u[0])
    taken, units = set(), []
    for d, files in raw:
        units.append({"dir": d, "files": files, "slug": feature_slug(root, d, taken)})
    all_files = [f for u in units for f in u["files"]]
    endpoints, models = scan_evidence(root, all_files)
    manifest = find_manifest(root)
    return {"units": units, "found": found, "capped": capped,
            "endpoints": endpoints, "models": models,
            "manifest": manifest, "deps": dependencies(root, manifest),
            "entries": entry_points(root), "skipped": scan_skipped(root, kb),
            "stack": detect_stack(root, pipeline_dir),
            "tree": tree_hash(root, pipeline_dir, [rel_to(root, f) for f in all_files])}


def scaffold_view(text):
    """The document as the scaffold judges it: its own hash line left out, and the orphaned mark
    the scaffold writes on a profile whose code is gone read as the status it replaced. Neither
    is an edit."""
    m = FM_RX.match(text)
    if not m:
        return text
    body = [ln for ln in m.group(1).split("\n") if not re.match(r"scaffold_sha256\s*:", ln)]
    body = ["status: SCAFFOLD" if ln == "status: orphaned" else ln for ln in body]
    return "---\n" + "\n".join(body) + "\n---\n" + text[m.end():]


def seal(text):
    """The document with the hash of what the scaffold wrote as its last frontmatter key, so a
    later run can tell whether anyone has changed it since."""
    return set_frontmatter(text, "scaffold_sha256",
                           hashlib.sha256(scaffold_view(text).encode("utf-8")).hexdigest())


def same_but_stamps(old, new, stamps):
    """True when old is new line for line, apart from the stamps every run writes afresh: where
    new carries one ((value, pattern) pairs: today's date, the tree hash), old may carry any
    value of that shape."""
    o, n = old.split("\n"), new.split("\n")
    if len(o) != len(n):
        return False
    for x, y in zip(o, n):
        if x == y:
            continue
        rx = re.escape(y)
        for value, pattern in stamps:
            if value:
                rx = rx.replace(re.escape(value), pattern)
        if rx == re.escape(y) or not re.fullmatch(rx, x):
            return False
    return True


def kept_why(old, new, legacy_ok, stamps):
    """None when the scaffold may replace its own document `old` with `new`; otherwise why it
    keeps it. A document carrying the scaffold's hash is replaced only while its text still
    matches that hash. One an older scaffold wrote carries no hash: it is replaced only on a run
    that allows it (`acp kb scaffold`, never install or intake), and only when it is exactly
    what the scaffold writes today apart from its stamps (the date, the tree hash), so nobody
    edited it."""
    h = frontmatter(old).get("scaffold_sha256")
    if h is not None:
        return None if h == hashlib.sha256(scaffold_view(old).encode("utf-8")).hexdigest() else "edited"
    if legacy_ok and same_but_stamps(scaffold_view(old), new, stamps):
        return None
    return "legacy-changed" if legacy_ok else "legacy"


def print_kept(held):
    """One line for each scaffold document kept that the scaffold would once have rebuilt."""
    for rel, why in held:
        print(f"scaffold: kept {rel}: " + {
            "edited": "it was edited after the scaffold wrote it; delete it to regenerate",
            "legacy": "an older scaffold wrote it; acp kb scaffold replaces it if nobody edited it, "
                      "or delete it to regenerate",
            "legacy-changed": "an older scaffold wrote it and it is not what the scaffold writes "
                              "today; delete it to regenerate"}[why])


def write_if_scaffold(path, text, force, legacy_ok, stamps):
    """Write, sealed with its hash, unless the file on disk is someone's own writing or was
    changed after the scaffold wrote it. A document the scaffold wrote carries its marker; one
    without it was written by an agent or a person, and overwriting it would destroy the very
    thing this exists to produce. None when written; otherwise why the file was kept."""
    if os.path.isfile(path) and not force:
        old = read(path)
        if SCAFFOLD_MARK not in old:
            return "own"
        why = kept_why(old, text, legacy_ok, stamps)
        if why:
            return why
    with open(path, "w", encoding="utf-8") as f:
        f.write(seal(text))
    return None


def profile_state(kb, slug, budget):
    """(exists, still at scaffold state, text) for one feature's profile."""
    path = os.path.join(kb, "profiles", slug + ".md")
    if not os.path.isfile(path):
        return False, False, ""
    text = read(path)
    fm = frontmatter(text)
    b = fm.get("scaffold_prompts")
    try:
        b = int(b)
    except (TypeError, ValueError):
        # No scaffold_prompts means nobody scaffolded this: it is someone's own
        # profile, and the scaffold does not touch it.
        return True, False, text
    return True, narrative_prompts(text) >= b, text


def cmd_scaffold(a, root, kb):
    level = a.level if a.level in LEVELS else "lite"
    today = date.today().isoformat()
    legacy_ok = bool(getattr(a, "legacy_rebuild", False))
    stamps = [(today, r"\d{4}-\d{2}-\d{2}")]
    tpl = read(template_path("feature-profile.md"))
    if not tpl:
        print(f"kb scaffold: the Feature Profile template is missing "
              f"({slash(os.path.relpath(template_path('feature-profile.md'), root))}) — "
              f"re-run the installer with a version that ships it", file=sys.stderr)
        return 1
    pipeline_dir = a.pipeline_dir or DEFAULT_PIPELINE_DIR
    if a.grow and not os.path.isdir(kb):
        # --grow is called at close time, on every work order. Conjuring a knowledge
        # base out of one closing work order would leave profiles with no survey
        # around them, and it is not what the caller asked for.
        print(f"grow: no knowledge base at {slash(os.path.relpath(kb, root))} — nothing to grow; "
              f"`kb.py scaffold` builds one")
        return 0
    check_only = bool(getattr(a, "check", False))
    if check_only and not a.grow:
        print("kb scaffold: --check reports what --grow would do; it is used with --grow", file=sys.stderr)
        return 2
    if not check_only:
        os.makedirs(os.path.join(kb, "profiles"), exist_ok=True)
    ctx = discover(root, kb, pipeline_dir)
    stamps.append((ctx["tree"], r"[0-9a-f]{12,64}"))
    units = ctx["units"]
    budget = narrative_prompts(tpl)

    # --- a tree with nothing in it yet -----------------------------------------
    if not units and not a.grow:
        held = []
        for name, doc in (("analysis.md", build_empty_analysis(root, today, level)),
                          ("status-matrix.md", build_matrix(root, today, level, [], {}))):
            why = write_if_scaffold(os.path.join(kb, name), doc, a.force, legacy_ok, stamps)
            if why and why != "own":
                held.append((name, why))
        with open(os.path.join(kb, LEVEL_FILE), "w", encoding="utf-8") as f:
            f.write(level + "\n")
        write_index(kb, {})
        print_kept(held)
        print("scaffold: nothing to describe yet (0 features) — the knowledge base grows as work orders close")
        return 0

    # --- the profiles ------------------------------------------------------------
    written, kept, badges, held = [], [], {}, []
    profdir = os.path.join(kb, "profiles")
    prof_files = sorted(f for f in os.listdir(profdir) if f.endswith(".md")) if os.path.isdir(profdir) else []
    covers = {f[:-3]: covered_paths(os.path.join(profdir, f), root) for f in prof_files}
    for u in units:
        path = os.path.join(kb, "profiles", u["slug"] + ".md")
        exists, at_scaffold, text = profile_state(kb, u["slug"], budget)
        # --grow adds; it does not regenerate. Otherwise a profile someone has
        # written is left alone, and one still at scaffold state is refreshed.
        if exists and not a.grow and "scaffold_prompts" in frontmatter(text) \
                and frontmatter(text).get("status") == "orphaned":
            # Its code is back, so the orphaned mark the scaffold wrote no longer holds; the seal does not
            # count that line, so a kept profile stays kept.
            text = set_frontmatter(text, "status", "SCAFFOLD")
            with open(os.path.join(kb, "profiles", u["slug"] + ".md"), "w", encoding="utf-8") as fh:
                fh.write(text)
        if exists and (a.grow or (not at_scaffold and not a.force)):
            kept.append(u["slug"])
            badges[u["slug"]] = badge_of(text, budget)
            continue
        # A feature whose files another profile already covers is described: a stub of its own would duplicate that profile.
        by = None if exists else describing(u["files"], root, covers)
        if by:
            kept.append(u["slug"])
            badges[u["slug"]] = badge_of(read(os.path.join(profdir, by + ".md")), budget)
            continue
        if not check_only:
            doc = build_profile(root, tpl, u["slug"], u["dir"], u["files"],
                                ctx["endpoints"], ctx["models"], today)
            # Still at scaffold state, but edited since (a section added), or written by an
            # older scaffold: kept, and said so.
            why = kept_why(text, doc, legacy_ok, stamps) if exists and not a.force else None
            if why:
                kept.append(u["slug"])
                badges[u["slug"]] = badge_of(text, budget)
                held.append((f"profiles/{u['slug']}.md", why))
                continue
            with open(path, "w", encoding="utf-8") as f:
                f.write(seal(doc))
        written.append(u["slug"])
        badges[u["slug"]] = "undocumented"

    # --- features that are gone --------------------------------------------------
    # A profile is gone only when none of the paths it covers exists, checked, never inferred from the scaffold's own grouping.
    # A profile that names no path at all is checked through its feature key: gone when no directory has that key.
    # Grow (the close) reports and changes no existing profile; an explicit scaffold marks a profile it wrote orphaned, and a
    # profile a person wrote (no scaffold_prompts) is reported and left as it is.
    live = {u["slug"] for u in units}
    orphaned, gone, by_key = [], [], set()
    keys = None
    for f in prof_files:
        slug = f[:-3]
        if slug in live:
            continue
        path = os.path.join(profdir, f)
        text = read(path)
        fm = frontmatter(text)
        if "feature" not in fm:
            continue          # not the scaffold's to judge
        items = covers.get(slug, [])
        if items:
            missing = [shown for shown, found in items if not found]
            if len(missing) < len(items):
                continue      # something it covers is still there: not gone
            shown = ", ".join(missing[:3]) + (", ..." if len(missing) > 3 else "")
            why = f"profiles/{f} covers paths that no longer exist ({shown})"
        else:
            if keys is None:
                keys = key_dirs(root, kb)
            key = fm.get("feature", "").strip()
            if key in keys:
                continue      # its feature key names a directory that is there
            why = f"profiles/{f} names no path, and no directory has its feature key `{key}`"
            by_key.add(slug)
        by_scaffold = "scaffold_prompts" in fm
        if a.grow or not by_scaffold:
            gone.append((slug, why, by_scaffold))
            continue
        orphaned.append(slug)
        if fm.get("status") != "orphaned":
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(set_frontmatter(text, "status", "orphaned"))

    # --- grow: add what is new, disturb nothing else ------------------------------
    # Exit 3 when a profile's code is gone, so a caller decides on the exit code rather than on the wording; --check
    # reports the same and writes nothing.
    if a.grow:
        added = sorted(written)
        if added and not check_only:
            rows = read_index_rows(kb)
            for p, (h, s) in cited_rows(kb, root, [f"profiles/{s_}.md" for s_ in added]).items():
                if p in rows:
                    continue          # an existing row stays as it was bound
                rows[p] = (h, s)
            write_index(kb, rows)
        for slug, why, by_scaffold in gone:
            what = ("the scaffold wrote it: update it, or run `acp kb scaffold` to mark it orphaned" if by_scaffold
                    else "a person wrote it: update it or retire it by hand")
            print(f"grow: {why}; the profile was left as it is; {what}")
        if added:
            print(f"grow: {len(added)} profiles {'would be added' if check_only else 'added'} ({', '.join(added)})")
        elif not gone:
            print("grow: nothing new")
        return 3 if gone else 0

    # --- the survey, the matrix, the level, the binding ---------------------------
    wrote = {f"profiles/{s}.md" for s in written}
    for name, doc in (("analysis.md", build_analysis(root, today, level, ctx)),
                      ("status-matrix.md", build_matrix(root, today, level, units, badges))):
        why = write_if_scaffold(os.path.join(kb, name), doc, a.force, legacy_ok, stamps)
        if why is None:
            wrote.add(name)
        elif why != "own":
            held.append((name, why))
    with open(os.path.join(kb, LEVEL_FILE), "w", encoding="utf-8") as f:
        f.write(level + "\n")
    if a.force:
        print("scaffold: --force — every scaffolded document was regenerated, including profiles "
              "whose narrative had been written")
    if ctx["capped"]:
        print(f"scaffold: {ctx['found']} candidate feature(s) found; capped at {FEATURE_CAP}, "
              f"the ones holding the most source files")
    by_path = [o for o in orphaned if o not in by_key]
    if by_path:
        print(f"scaffold: orphaned (none of the paths it covers exists; the profile is kept): {', '.join(by_path)}")
    if len(by_path) < len(orphaned):
        print(f"scaffold: orphaned (it names no path and no directory has its feature key; the profile is kept): "
              f"{', '.join(o for o in orphaned if o in by_key)}")
    for slug, why, _by_scaffold in gone:
        print(f"scaffold: not marked, a person wrote it: {why}; update or retire it")
    print_kept(held)
    rc = cmd_bind(a, root, kb, wrote)
    # The summary goes last so a caller reading one line of output reads this one
    # rather than the binding's.
    print(f"scaffold: {len(units)} feature(s), {len(written)} profile(s) written, {len(kept)} kept, "
          f"{len(orphaned)} orphaned, {len(ctx['endpoints'])} endpoint(s), {len(ctx['models'])} model(s) "
          f"— level {level}, tree {ctx['tree']}")
    return rc

# --- subcommands ----------------------------------------------------------------

def cmd_bind(a, root, kb, wrote=None):
    """Bind every document's citations. The scaffold passes the documents it wrote this run
    (`wrote`), and a source file keeps the hash it was bound at unless a document written this run
    cites it and no other document does, the survey and the matrix aside (they cite every file): a
    profile the scaffold kept, or a person's own document, is not marked current against code it
    no longer describes, and a run that wrote nothing changes no row."""
    profs = profiles_of(kb, root) if os.path.isdir(kb) else {}
    old = read_index_rows(kb) if wrote is not None else {}
    if not profs:
        print(f"kb bind: no profiles under {slash(os.path.relpath(kb, root))} — a profile is a markdown "
              f"document carrying <!-- SOURCE: path:L12 --> citations", file=sys.stderr)
        return 1
    rows, unresolved = {}, []
    for name, (path, cits) in profs.items():
        for ref, _hi, found in cits:
            if not found:
                unresolved.append(f"{name}: {ref}")
                continue
            key = rel_to(root, os.path.realpath(found))
            entry = rows.setdefault(key, [hash_of(found), set()])
            entry[1].add(name)
    for key, entry in list(rows.items()):
        if wrote is None:
            continue
        held = [c for c in entry[1] if c not in wrote and c not in ("analysis.md", "status-matrix.md")]
        if key in old and (held or not any(c in wrote for c in entry[1])):
            entry[0] = old[key][0]
        elif key not in old and held:
            # never bound, or dropped while the code was gone: a document this run did not write is not
            # bound at today's code by the scaffold; `kb bind` does that
            del rows[key]
    rows = {p: (h, profs_set) for p, (h, profs_set) in rows.items()}
    bound_tree = write_index(kb, rows)
    print(f"kb bind: {len(rows)} source file(s) cited by {len(profs)} profile(s) — "
          f"{slash(os.path.relpath(index_path(kb), root))}, bound_tree={bound_tree}")
    if unresolved:
        # Not a failure here: these citations are reported as broken by `status`,
        # which is where a profile's state belongs.
        print(f"kb bind: {len(unresolved)} citation(s) point at nothing and are not in the index:", file=sys.stderr)
        for u in unresolved[:10]: print(f"  {u}", file=sys.stderr)
    return 0


def classify(profs, root, index):
    """Per profile: orphaned when the feature it describes is gone and the profile
    was kept as a record; else broken if a citation points at a file or a line that
    is not there; else stale if a cited file's content no longer matches the binding
    (or was never bound); else current.

    Orphaned is checked first and stops there. Its citations dangle by definition —
    the code they named was deleted — and reporting that as broken on every run
    would turn a deliberate record into a step nobody can pass again."""
    out = []
    for name, (path, cits) in profs.items():
        if frontmatter(read(path)).get("status") == "orphaned":
            out.append({"profile": name, "state": "orphaned", "citations": len(cits),
                        "reason": "the directory this described is gone; the profile is kept as a record",
                        "broken": [], "stale": []})
            continue
        broken, stale = [], []
        for ref, hi, found in cits:
            if not found:
                broken.append(f"{ref} — cited file does not exist")
                continue
            rp = rel_to(root, os.path.realpath(found))
            n = line_count(found)
            if hi is not None and hi > n:
                broken.append(f"{rp}:L{hi} — past the end of the file ({n} lines)")
                continue
            if rp not in index:
                stale.append(f"{rp} — not in the index; bind has not run since this citation was written")
            elif index[rp] != hash_of(found):
                stale.append(f"{rp} — changed since bind")
        state = "broken" if broken else ("stale" if stale else "current")
        out.append({"profile": name, "state": state, "citations": len(cits),
                    "reason": (broken + stale)[0] if (broken or stale) else None,
                    "broken": broken, "stale": stale})
    return out


def cmd_status(a, root, kb):
    profs = profiles_of(kb, root) if os.path.isdir(kb) else {}
    lvl = level_of(kb, getattr(a, "level", None))
    if not profs:
        # A knowledge base the scaffold wrote for a tree with no source in it is a
        # true and complete description of that tree. Exit 3 is for the case it
        # was meant for: no knowledge base at all.
        if os.path.isdir(kb) and is_empty_kb(kb):
            print(f"kb: 0 profiles — nothing to describe yet")
            return 0
        print(f"no knowledge base at {slash(os.path.relpath(kb, root))}")
        return 3
    index = read_index(kb)
    bound = os.path.isfile(index_path(kb))
    rows = classify(profs, root, index)
    counts = {s: sum(1 for r in rows if r["state"] == s) for s in ("current", "stale", "broken")}
    orphaned = sum(1 for r in rows if r["state"] == "orphaned")

    exts = {("." + e.lstrip(".")).lower() for e in a.source_ext.split(",") if e.strip()} if a.source_ext else SOURCE_EXT
    cited = {rel_to(root, os.path.realpath(f)) for _n, (_p, cits) in profs.items() for _r, _h, f in cits if f}
    uncovered = [p for p in source_files(root, kb, exts) if p not in cited]

    budget = template_budget()
    shorts = []
    for r in rows:
        why = None if r["state"] == "orphaned" else \
            level_shortfall(r["profile"], read(profs[r["profile"]][0]), lvl, budget)
        r["short"] = bool(why)
        r["short_reason"] = why
        if why: shorts.append((r["profile"], why))

    # Freshness outranks completeness: a stale profile is wrong, an unwritten one
    # is only unwritten, and the count of both is on the summary line either way.
    rc = 2 if counts["broken"] else (1 if counts["stale"] else (4 if shorts else 0))
    summary = (f"kb: {len(rows)} profiles{f' ({orphaned} orphaned)' if orphaned else ''} — "
               f"{counts['current']} current, {counts['stale']} stale, "
               f"{counts['broken']} broken; {len(uncovered)} uncovered source files; "
               f"{len(shorts)} short of {lvl}")

    if a.json:
        print(json.dumps({
            "kb": slash(os.path.relpath(kb, root)),
            "bound": bound,
            "bound_tree": bound_tree_of(kb),
            "profiles": rows,
            "counts": {"profiles": len(rows), **counts},
            "orphaned": orphaned,
            "uncovered": {"count": len(uncovered), "clusters": cluster(uncovered),
                          "files": uncovered[:100], "files_truncated": len(uncovered) > 100},
            "level": lvl,
            "short": {"level": lvl, "count": len(shorts),
                      "profiles": [{"profile": n, "reason": why} for n, why in shorts]},
            "summary": summary,
            "exit": rc,
        }, indent=2, sort_keys=True))
        return rc

    print(f"index: bound, {len(index)} file(s), bound_tree={bound_tree_of(kb)}" if bound
          else "index: not bound — no source-index.tsv; run `kb.py bind` (every profile reads as stale until then)")
    w = max([len(r["profile"]) for r in rows] + [7])
    print(f"{'profile'.ljust(w)}  state      first problem")
    order = {"broken": 0, "stale": 1, "current": 2, "orphaned": 3}
    for r in sorted(rows, key=lambda r: (order[r["state"]], r["profile"])):
        print(f"{r['profile'].ljust(w)}  {r['state'].ljust(9)}  {r['reason'] or '-'}")
    if uncovered:
        print(f"\nuncovered: {len(uncovered)} source file(s) no profile cites")
        for c in cluster(uncovered):
            print(f"  {c['dir'].ljust(w)}  {str(c['count']).rjust(5)}  {', '.join(c['examples'])}")
    else:
        print("\nuncovered: none — every source file is cited by a profile")
    if shorts:
        print(f"\nshort of {lvl}: {len(shorts)} profile(s)")
        for n, why in shorts:
            print(f"  {n.ljust(w)}  {why}")
    else:
        print(f"\nshort of {lvl}: none")
    print(f"\n{summary}")
    return rc


def cmd_impact(a, root, kb):
    changed = list(a.files or [])
    if a.stdin:
        changed += [l.strip() for l in sys.stdin.read().splitlines() if l.strip()]
    # The caller names paths relative to the root; an absolute path is accepted and
    # brought back to the same spelling, so git output and driver output both work.
    norm = []
    for p in changed:
        full = p if os.path.isabs(p) else os.path.join(root, p)
        rp = rel_to(root, os.path.realpath(full))
        if rp not in norm: norm.append(rp)

    profs = profiles_of(kb, root) if os.path.isdir(kb) else {}
    if not profs:
        # No knowledge base is not an error for a driver mid-change: there is
        # simply nothing that describes this yet.
        print(f"no knowledge base at {slash(os.path.relpath(kb, root))}")
        return 0

    changed_set = set(norm)
    # A profile is affected by a change only while the change is unaccounted for:
    # once the profile has been updated and re-bound, the index hash matches the
    # file again and the same change is no longer a reason to name it.
    index = read_index(kb) if os.path.isfile(os.path.join(kb, INDEX_NAME)) else {}
    def indexed_hash(rp):
        v = index.get(rp)
        if v is None: return None
        if isinstance(v, dict): return v.get("hash") or v.get("sha")
        if isinstance(v, (tuple, list)): return v[0]
        return v
    def unaccounted(rp):
        full = os.path.join(root, rp)
        if not os.path.isfile(full): return True
        h = indexed_hash(rp)
        return h is None or h != file_hash(full)
    affected, cited_all = {}, set()
    for name, (_path, cits) in profs.items():
        cited = {rel_to(root, os.path.realpath(f)) for _r, _h, f in cits if f}
        cited_all |= cited
        hit = sorted(p for p in (cited & changed_set) if unaccounted(p))
        if hit: affected[name] = hit

    for name in sorted(affected):
        print(f"{name}\t{','.join(affected[name])}")
    print(f"kb impact: {len(affected)} profile(s) describe {len(changed_set & cited_all)} of {len(norm)} changed file(s)")

    uncovered = [p for p in norm if p not in cited_all and os.path.splitext(p)[1] in SOURCE_EXT]
    print("uncovered:")
    for p in uncovered: print(f"  {p}")
    if not uncovered: print("  none")
    return 1 if affected else 0


def main():
    ap = argparse.ArgumentParser(prog="kb.py", description="knowledge-base freshness, bound to source")
    sub = ap.add_subparsers(dest="cmd")
    for name, help_text in (("scaffold", "build the knowledge base from the tree, deterministically"),
                            ("bind", "record a content hash per cited source file"),
                            ("status", "report which profiles are current, stale, broken, or short of the level"),
                            ("impact", "report which profiles describe a set of changed files")):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--root", default=os.getcwd())
        p.add_argument("--kb", default=None)
        if name in ("scaffold", "status"):
            p.add_argument("--level", choices=LEVELS, default=None,
                           help="lite: a profile per feature; standard: its narrative written; full: validated")
        if name == "scaffold":
            p.add_argument("--pipeline-dir", default=None,
                           help=f"where the pipeline is installed, relative to the root (default {DEFAULT_PIPELINE_DIR})")
            p.add_argument("--grow", action="store_true",
                           help="add profiles for features no profile covers; report profiles whose covered paths are gone "
                                "(exit 3); change no existing profile; re-bind nothing")
            p.add_argument("--check", action="store_true",
                           help="with --grow: report what grow would add and which profiles' paths are gone; write nothing")
            p.add_argument("--force", action="store_true",
                           help="regenerate every scaffolded document, including profiles already written")
            p.add_argument("--legacy-rebuild", action="store_true",
                           help="also replace a document an older scaffold wrote (it carries no hash) when it is "
                                "exactly what the scaffold writes today apart from its date and tree hash; acp kb scaffold "
                                "passes this, install and intake do not")
        if name == "status":
            p.add_argument("--json", action="store_true")
            p.add_argument("--source-ext", default=None, help="comma-separated extensions to count as source")
        if name == "impact":
            p.add_argument("--files", nargs="*", default=[])
            p.add_argument("--stdin", action="store_true", help="read changed paths from stdin, one per line")
    a = ap.parse_args()
    if not a.cmd:
        ap.print_help()
        return 2
    # realpath, not abspath: on macOS the temp directory is a symlink, and a root
    # spelled one way with paths spelled the other resolves to nothing.
    root = os.path.realpath(a.root)
    kb = os.path.realpath(a.kb) if a.kb else os.path.join(root, DEFAULT_KB)
    set_doc_dirs(root, kb)
    return {"scaffold": cmd_scaffold, "bind": cmd_bind,
            "status": cmd_status, "impact": cmd_impact}[a.cmd](a, root, kb)


if __name__ == "__main__":
    sys.exit(main())
