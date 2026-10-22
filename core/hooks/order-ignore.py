#!/usr/bin/env python3
"""
order-ignore — every order's artifacts/ holds working files that never enter git.

The rule lives in a .gitignore inside the work-order and bug folders themselves, which are the
pipeline's own: "/*/artifacts/" there ignores the artifacts/ folder of every order below it. The file is
committed, so a clone and an order's worktree carry it, and a folder made by hand is covered too.

For each folder named: no .gitignore, one is made holding the rule; a .gitignore with other content gets
the rule in a block between two marker lines, and the rest of the file is left as it is; a block already
there is brought up to date. A .gitignore that is a link, a file or folder that cannot be written, or a
marker without its pair is refused, and then nothing is written for any folder. Line endings are kept.
A file is never rewritten in place: the new text goes to a temporary file beside it (the old file's mode
kept), is flushed to disk and then renamed over it, so a write that fails (a full disk) leaves the file
exactly as it was.

Usage: order-ignore.py <folder>... [--dry-run]
Output: one line per folder it writes (or, with --dry-run, would write): "<file>: made", "...: rule added",
"...: rule updated". Nothing for a folder already right.
Exit codes: 0 done (or nothing to do), 1 refused (the reason on stderr; nothing was written), 2 usage,
3 a write failed (the reason on stderr; that file is as it was, and any folder named after it untouched).
"""
import os, stat, sys, tempfile

RULE = "/*/artifacts/"
BEGIN = "# >>> AICodePipeline: order working files (the pipeline keeps this block) >>>"
END = "# <<< AICodePipeline <<<"


class Refused(Exception):
    pass


def plan(folder):
    """(path, new text, what) for one folder, or None when it is already right."""
    p = os.path.join(folder, ".gitignore")
    if os.path.islink(folder) or os.path.islink(p):
        raise Refused("%s is a link; the rule is written into the pipeline's own folder only" % (folder if os.path.islink(folder) else p))
    if os.path.exists(folder) and not os.path.isdir(folder):
        raise Refused("%s is not a folder" % folder)
    if not os.path.exists(p):
        parent = folder
        while not os.path.exists(parent):
            parent = os.path.dirname(parent) or "."
        if not os.access(parent, os.W_OK):
            raise Refused("%s cannot be written" % parent)
        return p, RULE + "\n", "made"
    if not os.path.isfile(p):
        raise Refused("%s is not a file" % p)
    if not os.access(p, os.R_OK | os.W_OK):
        raise Refused("%s cannot be read and written" % p)
    with open(p, encoding="utf-8", errors="surrogateescape", newline="") as f:
        text = f.read()
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines()
    if lines == [RULE]:
        return None   # the file the pipeline made
    nb, ne = lines.count(BEGIN), lines.count(END)
    if (nb, ne) not in ((0, 0), (1, 1)) or (nb and lines.index(BEGIN) > lines.index(END)):
        raise Refused("%s has an AICodePipeline marker without its pair; fix the block by hand" % p)
    block = [BEGIN, RULE, END]
    if nb:
        i, j = lines.index(BEGIN), lines.index(END)
        if lines[i:j + 1] == block:
            return None
        lines[i:j + 1] = block
        what = "rule updated"
    else:
        lines += ([""] if lines and lines[-1] != "" else []) + block
        what = "rule added"
    return p, nl.join(lines) + nl, what


def write(p, text):
    """text into p by a temporary file beside it, renamed over p once it is on disk; p is as it was on any failure."""
    d = os.path.dirname(p) or "."
    os.makedirs(d, exist_ok=True)
    if os.path.exists(p):
        mode = stat.S_IMODE(os.stat(p).st_mode)
    else:
        mask = os.umask(0); os.umask(mask); mode = 0o666 & ~mask
    fd, tmp = tempfile.mkstemp(prefix=".gitignore.", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
            f.write(text); f.flush(); os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, p)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def main(argv):
    dry = "--dry-run" in argv
    folders = [a for a in argv if a != "--dry-run"]
    if not folders or any(a.startswith("-") for a in folders):
        print("usage: order-ignore.py <folder>... [--dry-run]", file=sys.stderr)
        return 2
    try:
        todo = [x for x in (plan(f) for f in folders) if x]
    except Refused as e:
        print("order-ignore: %s; nothing was written" % e, file=sys.stderr)
        return 1
    for p, text, what in todo:
        if not dry:
            try:
                write(p, text)
            except OSError as e:
                print("order-ignore: %s could not be written (%s); it is as it was" % (p, e.strerror or e), file=sys.stderr)
                return 3
        print("%s%s: %s" % ("would write " if dry else "", p, what))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
