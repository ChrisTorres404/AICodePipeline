# plan-labels

Proves: bin/lint fails on a plan label (ACP, a dash and three digits, in either case) in any file or folder name or text under core, harness, bin and docs, sanitize-ignored files and any suffix included; it does not read the generated reports in harness/evals/results; a file it cannot read is an error; an installed copy, whose files hold the project's own path, is not held to it; and the shipped tree carries none.
