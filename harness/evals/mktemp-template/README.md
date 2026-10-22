# mktemp-template

Proves: the portability check reports a mktemp -d with no template (macOS then ignores TMPDIR), and the pipeline's own scripts pass one, so bin/eval's scratch folders land under TMPDIR.
