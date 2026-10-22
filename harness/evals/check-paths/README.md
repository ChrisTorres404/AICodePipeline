# check-paths

Proves: check.py --staged and --since read git's paths with -z, so a work order or configuration whose path holds a space, a non-ASCII letter or a double quote is checked, a rename is followed, and a byte that is not UTF-8 blinds nothing.
