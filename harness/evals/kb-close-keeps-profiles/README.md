# kb-close-keeps-profiles

Proves a close never rewrites a profile, and never calls one gone while the paths it covers exist.

Before 1.4.1, `wo close` ran `kb.py scaffold --grow`, which marked a profile orphaned whenever its file name was not one of the
features the scaffold's own grouping found, without checking any path, and wrote `status: orphaned` into it whether the scaffold
or a person had written it. A project whose profiles split one source directory into its packages, named their own way
(`feature: engine-make` in `making.md`), had every such profile rewritten at every close, with "the directory is gone" while
every directory existed, and a profile added for the pipeline's own document folder because a helper script sat there. The close
printed one line and went on.

The evaluation first checks how a profile's paths are read: a citation relative to the profile's folder, a wildcard, a
backslash path, a `./` path and a word that is not a path all count correctly, and a renamed scaffold profile is not orphaned.
It checks that a code folder holding the knowledge base still has its code profiled while the documents folder does not, and
that a profile naming no path is reported through its feature key when its directory moves. It then builds the damaged shape
(hand profiles with names the scaffold would never give, one directory split below the scaffold's grouping, a renamed scaffold
profile, a script kept with the documents) and checks that an explicit scaffold and a real close leave every profile
byte-identical. With a package removed and new code added, the report-only grow names the profile and writes nothing; a close
under the strict profile refuses, names the profile and the missing path, writes no closing record and leaves the knowledge
base unchanged; the override closes, prints every line of the report, and the closing record holds it under its own heading. A
failed grow step is shown and recorded without claiming what it did not check. Last, a scaffold profile whose code is gone is
reported by grow and orphaned only by an explicit scaffold, and a new package nobody covers gets exactly one stub.

Each of the six defects an independent review planted (path check removed, document-folder skip removed, grow allowed to write,
"already covered" check removed, close output cut to one line, strict refusal removed) makes this evaluation fail.
