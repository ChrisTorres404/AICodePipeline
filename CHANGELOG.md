# Changelog

### 1.5.0

A layout release. A project can keep its code in app/ and the pipeline in acp/, new projects can
start that way, and `acp migrate` moves an existing one: a plan that moves nothing, a checked
backup, your answers, and one commit that makes the move. acp doctor and acp check name what sits
outside the layout, hold every order folder to one structure, and warn when .gitignore lets secret
files into git; each order gets an artifacts/ folder that never enters git, and the evaluation
suite grew from 109 to 131. After upgrading, run `acp doctor`, then `wo verify` again on each open
order. See `docs/releases/1.5.0.md`.

### 1.4.2

A hardening release: fifty-one fixes found by reviewing 1.4.1 line by line. Closing a work
order holds more strictly to evidence that matches the code, the drivers refuse bad input
instead of writing broken or half-made documents, and titles, paths and settings are treated
as plain text everywhere; the evaluation suite grew from 58 to 109. After upgrading, run
`wo verify` again on each open order. See `docs/releases/1.4.2.md`.

### 1.4.1

- `wo close` no longer damages the knowledge base. Its grow step marked a profile
  orphaned whenever the file name was not one of the features the scaffold's own
  grouping found, without checking a path, and rewrote it whether the scaffold or a
  person had written it; a project whose profiles split a directory into packages
  lost every one of them at every close. Now a profile is judged by the paths it
  covers: its SOURCE citations (read from the root or from the profile's own
  folder) and its Covers line (wildcards expanded, backslashes read as slashes, a
  leading `./` dropped, words that are not paths skipped), or, when it names no
  path, its feature key mapped to a directory. Grow adds profiles only for features
  no profile covers, reports a profile whose covered paths are all gone, changes no
  existing profile, and exits 3 when it reports one; `scaffold --grow --check`
  reports the same and writes nothing. An explicit `acp kb scaffold` marks a
  profile it wrote orphaned only when its covered paths are gone, and reports one a
  person wrote. The pipeline's own document folders (the folder holding the
  knowledge base, `WORKSPACE_DIR`, `DOCS_DIR`) are never a feature; a code folder
  that holds the knowledge base still is. The close shows every line grow prints,
  keeps its errors, and records the report, or the failure, in the closeout under
  "Knowledge base changes at close". Under the strict profile it runs the
  report-only check first and refuses, with nothing written, while a profile
  covers paths that are gone; `ACP_SKIP_KB=1` overrides, with a reason in the
  closeout (`kb-close-keeps-profiles`)
- `acp doctor` and `bin/lint`, when PyYAML is not installed, accepted frontmatter
  that YAML rejects: a `key: value` line indented under a plain value. They now
  reject it, so `acp doctor` reports such a skill as not parsing on every machine;
  none of the definitions the pipeline ships changes (`baseline-and-doctor`)

### 1.4.0

- `packs/` is now `playbooks/` and `bin/pack` is `bin/playbook`; skill packs
  are skill sets (`SKILL_SETS`, `--skill-set`) and agent packs are agent sets
  (`AGENT_SETS`, `--agent-set`); the old names are still accepted and install
  migrates an existing `packs/` directory
- the knowledge base has levels, set at install with `KNOWLEDGE_LEVEL` or
  `new-project --kb-level`. `acp kb scaffold` builds the `lite` level from the
  source tree: an analysis, one profile per feature with every citation
  resolving to a file and line, the status matrix, and the bound source index.
  Re-running it adds new features, marks vanished ones orphaned, and never
  overwrites narrative someone wrote. `standard` requires the narrative
  written and `full` requires it validated; `acp kb status` exits 4 and lists
  the profiles short of the level (`kb-levels`)
- intake runs the scaffold, so the knowledge-base step passes on a fresh
  install; `wo close` runs it in grow mode so a new feature gets a profile stub
  when the work order that added it closes
- on a project with no source yet, the baseline, suites, and knowledge-base
  intake steps pass with a note; `detect-stack` reports an empty tree
  (`intake-work-orders`)
- `acp check` runs three rules that were only session hooks: UI drift,
  formatting (report only, never writes), and type errors with `--types` or
  `ACP_CHECK_TYPES=1`. Strict is `--strict`, `ACP_STRICT=1`, or
  `ACP_HOOK_PROFILE=strict`, so a strict project is strict at commit time too
  (`parity-without-claude`)
- install writes a git `pre-push` hook that refuses a force push to, or
  deletion of, `main`, `master`, `develop`, `production`, or `release/*`;
  `ACP_ALLOW_FORCE_PUSH=1` overrides; the minimal profile installs none;
  doctor reports it
- `acp commands`, `acp command <name>`, `acp skills`, and `acp skill <name>`
  print the slash commands and skills as text; `AGENTS.md` has a section on
  working under any agent (`reach-without-claude`)
- README: a table of every rule and where it runs under Claude Code and under
  any other agent
- doctor reports a knowledge base short of its level and the pre-push hook
- agent definitions restored to the full source versions, checked section by
  section: activation triggers on 34 agents, 54 agents extended with the
  sections that had been dropped, `scalar-expert` added. The two identity SDK
  agents use the configured placeholders instead of fixed paths
- the work-order comment standard is the header block from the source
  (`WO-####`, `DATE`, `WHAT`, `WHY`, `DATA`, `IMPACT`), with a one-line form
  for small files and a dated tag for changed regions; the validators accept
  the three forms and nothing else. Two validators regained checklist items
  that had been dropped (strict mode, typed functions and props, constrained
  generics, import order, migration error handling)
- methodology documents restored to the full source versions, section by
  section, code blocks and worked examples included, and extended where the
  product had added something:
  `MANDATORY-TESTING-METHODOLOGY.md` (behavioural tests against the running
  system instead of end-to-end tests with mocks, the four phases, evidence
  requirements, both CI recipes, the state-only verification mode, and one
  status vocabulary: PASS, FAIL, PLAN ONLY, PRECONDITION FAILED, RUNNING),
  `MANDATORY-WO-METHODOLOGY.md` (folder rules, workflow, finding work orders,
  the series rule, the code comment standard, the size policy stated
  plainly), `PROJECT-RULES.md` (implementation order, code quality checklists,
  component extraction, import rules, forbidden database operations)
- new methodology documents: `SYSTEMATIC-TEST-FIXING-METHODOLOGY.md`,
  `AGENT-OUTPUT-STANDARDS.md`, `DATABASE-GOLD-STANDARD-METHODOLOGY.md`,
  `TEST-INVENTORY-AND-GAP-ANALYSIS.md`, and `core/methodology/README.md` as
  the index
- `core/instructions/` completed: `00-test-fixing-quick-start.md`,
  `01-create-work-orders.md`, `02-next-session-rules.md`,
  `05-reusable-test-fixing-prompts.md` added; `03`, `04`, and the README
  restored to their full form with every command and worked example
- `core/rules/ui/`: the 100-line extraction trigger is a mandatory checklist
  row again beside the hard limits (page 150, component 200, modal 50, form
  80, table 100); structure rules gain the read-first and examples sections;
  `coding-style.md` and `work-orders.md` gain the import and folder rules
- templates: `WO-TEMPLATE-MASTER.md` (the full work-order template in one
  document); File(s), Assignee, and Evidence columns; the four-row
  behavioural testing phase; manual verification scenarios and the closure
  checklist; bug and testing READMEs index every file; bug number ranges have
  upper bounds; `NEXT-SESSION-TEMPLATE.md`; `DESIGN-SYSTEM-INSTRUCTIONS.md`
  and `DESIGN-SYSTEM-MIGRATION-GUIDE.md` as fill-in templates
- `core/templates/reference/`: incident postmortem, QA smoke test, port
  allocation standard, database normalization audit, test accounts registry,
  and documentation index templates
- seven skills added or extended from the source guides: `react-patterns`,
  `nextjs-patterns`, `nestjs-patterns`, `sdk-standards`, `database-seeding`
  (with a reference seeder implementation), `project-setup`,
  `typeorm-patterns`, `database-backup` (with `backup.sh`),
  `guard-application-order`
- `docs/patterns/`: behavioural suites in CI with a results dashboard, and
  the rationale for the four-layer validation design
- harness: `harness/lib/test-env.sh` holds the shared environment functions
  (health check, pool release and recovery, cache flush, known-state reset);
  `test-helpers.sh` gains the 32 helpers the source suites use (CSRF,
  register, login, refresh with rotation, logout, authenticated requests,
  lockout, response parsing, assertions, `test_start`/`test_pass`/
  `print_summary`), every endpoint and header name configurable in
  `test-config.env`; the runner recovers the connection pool and resets state
  between every tier; `--stop-fail` stops the run; `test-runner.sh --suite`
  runs one suite with timestamped evidence; `run-behavioral-tests.sh` accepts
  the runner's flags and keeps full per-check evidence;
  `harness/runners/test-cli.sh` is the interactive CLI
- `bin/sanitize` accepts more than one directory
- `KNOWLEDGE_DIR` is rendered at install like the other directory variables

### 1.3.0

Install now opens six intake work orders, and the knowledge base is built from the
project's own code.

- `acp install` and `new-project` open six intake work orders, each with a
  shipped spec that is complete prose and a shipped suite that proves the step:
  source state established, instructions reconciled, baseline recorded, record
  brought in, suites wired, knowledge base built. `wo verify --run` records the
  evidence, `wo close` refuses without it, and `acp intake status` and doctor
  say whether the project is operational (`intake-work-orders`)
- `acp intake inventory` classifies the repository before anything is adopted:
  git state, stack, instruction files, hooks, CI, and the shape of its record —
  pipeline work orders, numbered documents, ADRs, loose documentation, or
  nothing — with a document index and ready-to-run `wo adopt` commands where the
  shape allows it. Loose documentation is indexed, never adopted unless chosen
  (`intake-inventory`)
- the knowledge base is the repository-analysis engine run against the
  project's own code, under `KNOWLEDGE_DIR` (default
  `Workspace/Docs/KnowledgeBase`): the analysis, one Feature Profile per
  feature, the status matrix, and a source index recording a content hash per
  cited file. `acp kb status` reports every profile as current, stale, or
  broken, and which source no profile describes; `acp kb bind` refreshes the
  index after profiles are updated (`kb-freshness`)
- freshness is enforced where code changes: `wo close` names the profiles that
  describe files the work order changed and writes them into the closeout, and
  refuses under the strict profile; `acp check` carries the same rule into the
  pre-commit hook and CI; doctor reports the counts (`kb-close-impact`)
- the knowledge directory is excluded from the evidence fingerprint, so
  describing the code does not stale evidence about it

### 1.2.0

Under a coding agent other than Claude Code, the session hooks, agents, and skills were
not used; the drivers, templates, and git hook did the work. The rules now run in places
every tool reaches, and the Claude Code hooks are an early warning rather than the
enforcement:

- `acp check` runs the rule set over the staged changes, changes since a ref, an
  explicit list of paths, or what a work order has changed since it opened; it
  imports its rule tables from the hook scripts so the two cannot drift
  (`portable-check`). Blocking under every profile: credentials, a modified lint,
  format or strictness configuration, a closeout without an executed pass
- `wo close` and `bug close` run it over the work's own changes, with or without
  git, from a manifest taken at `wo new` (`no-git-lifecycle`)
- install writes a git `pre-commit` hook that runs it on every commit, under any
  agent; an existing hook is left alone, the minimal profile installs none, and
  doctor reports it (`precommit-backstop`). `acp ci github` adds a workflow that
  runs it on every pull request
- standard and large work orders refuse to close without a filled-in review by
  someone who did not implement them; `WO-####-REVIEW.md` is scaffolded at
  `wo new`; `ACP_SKIP_REVIEW=1` overrides with a warning (`review-required`)
- the routed specialists are written into the work order's own prompt with the
  path to each definition, so whatever tool does the work reads them; `acp agent`
  and `acp agents --area` reach the catalog from a shell
- install writes `AGENTS.md`, read by Codex, Cursor and most agents, and a short
  `CLAUDE.md` that imports it; a project's own copies are never touched and
  `detect-stack --write` refreshes whichever carries the stack lines
  (`instructions-for-every-tool`)
- `wo new --paths` binds a work order's evidence to part of a monorepo
  (`wo-paths-scope`)
- a project with no git repository is given the command to create one, by install
  and by doctor. The work-order checks run without it

Fixes from installing the pipeline into an existing monorepo and migrating its record.
Each defect has a regression evaluation:

- the fingerprint binds to file content whether or not git tracks the file yet, so
  committing between verify and close no longer stales the evidence; the suite that
  ran is bound on its own, so writing the next suite no longer stales the last pass
  (`evidence-binding`)
- exit 77 records `NOT EXECUTED — PRECONDITION FAILED`, never a failure, and the
  count a runner printed is kept beside the verdict and shown by `wo list`
  (`verify-results`)
- `wo adopt` and `bug adopt` bring an existing record in as history with no
  verification; `wo list`, `wo stats` and `bug list` read one definition of state;
  adopted items stay out of cycle-time statistics; a bug's category lives in its
  metadata (`adopt-existing-record`)
- `wo suite --wrap` and `SUITE_COMMAND` keep the runner a project already has
  (`suite-wrap`)
- `wo promote` carries the suites the verification names into the pack and marks
  references that did not travel; `pack lint` reports placeholder pitfalls
  (`pack-carries-evidence`)
- `acp baseline` runs the project's own tests once and records the first
  measurement; doctor asks for it, opens every agent and skill it counts, notices a
  repository with no commits and instructions pointing at a moved workspace; the
  installer names a moved workspace instead of orphaning it and ends with lint
  (`baseline-and-doctor`)
- a credential-shaped test fixture commits with `acp:allow-secret` on its line; the
  hooks skip the pipeline's own vendored source; a commit message may quote a
  work order that does not exist with an `Acp-Allow-Reference` trailer
  (`hook-secret-fixture-pragma`, `hooks-skip-vendored-pipeline`,
  `wo-reference-allow-trailer`)
- verification and closeout templates for UI work, a verification template of the
  bug's own, one results directory for every runner, a type axis in the suite
  manifest, the sanitizer notices internal hostnames, and a fresh install passes
  its own linter (`verification-templates`, `harness-results-path`,
  `manifest-suite-types`, `sanitize-hostname`, `install-lint-clean`)
- the drivers resolve their roots physically, so a project under a symlinked
  path fingerprints the same tree from every entry point

### 1.1.4

The 1.1.3 tree, prepared for a public repository:

- README rewritten for first-time readers
- inline references to other projects removed from three skills and agents; the
  notices file is the one place another project is named
- an example key in the release-sanitizer agent's teaching table rewritten so it
  no longer matches a real credential's shape
- release assets: a source archive and the Claude Code plugin, with checksums

### 1.1.3

Fixes from a recovery run on an existing codebase and two rounds of independent
review, each with a regression evaluation under `harness/evals/`:

- **Upgrading: re-run `acp install <project>` in each project you maintain.**
  It is the only migration path. It replaces the pipeline's own hooks by their
  `acp:` identity and keeps everything of yours. `acp doctor` only reports; it
  never edits git hooks, so a project installed before this release will not be
  told what it is missing until the installer has run there.
- traceability is enforced by a git `commit-msg` hook as well as the tool hook,
  so a citation of a work order nobody opened is refused whether the message
  came from `-m`, `-F`, stdin or an editor (`commit-msg-traceability`). A
  `commit-msg` hook you already have is left alone; chain the check into it to
  get the same guarantee, as the README shows
- `new-project` initialises the repository before installing, so scaffolded
  projects get the hook; previously there was no repository to wire it into
- in an installed copy, evaluations needing source-repository
  fixtures skip with a reason instead of failing, and two checks that scanned
  directories an install does not ship were scoping their scan wrong
- `acp doctor` opens, verifies and closes a throwaway work order in the layout
  it is pointed at, then removes it. It runs inside the target: doctoring one
  project never writes into another (`fresh-install-day-one`)
- `wo close` and `bug close` refuse a verification document that is still
  mostly the shipped template, measured against the template itself
  (`ALLOW_PLACEHOLDERS=1` when the prompts genuinely do not apply)
- external commands run under a bound that survives a malformed setting, so a
  third-party tool that hangs fails the run instead of holding it open forever
  (`bounded-external-commands`)
- the database-URL rule keys its exemption off the password rather than the
  username, so documentation examples stop reading as critical findings

Fixes from an independent review of 23 scenarios against a frozen build:

- work-order and bug identities are reserved atomically, so simultaneous
  creators no longer all receive the same number, and a number carried by two
  folders is reported rather than resolved by picking one (`concurrent-identity`).
  The same change exposed an older defect: a bug series is a band, not a prefix,
  and matching it as a prefix handed the second bug in a category a number that
  already existed
- verification refuses to record a pass when the source changed while the suite
  ran, marks a run before it starts so an interrupted rerun cannot leave an
  older pass standing, and the Stop hook now reads the authoritative status the
  same way the drivers do (`evidence-integrity`). `ALLOW_TREE_DRIFT=1` is there
  for suites that write into the tree by design
- the git hook is installed where git actually looks: a linked worktree keeps
  its hooks in the shared directory, and `core.hooksPath` moves them again
  (`worktree-hook`). doctor reports a hook that is present but not executable
- the traceability hook reads the authored message as written, comment lines
  included, because `--cleanup=verbatim` records them and the hook cannot see
  the command line that chose it
- the minimal profile installs no git hook, and reinstalling it removes one the
  pipeline put there earlier
- a failed install leaves the project intact: the replacement is staged before
  anything is removed, and the project's authored overlays and harness
  configuration are held with the project until the install commits, so a retry
  restores them (`install-failure-recovery`)
- a bounded command is killed with its whole process group, so a timeout no
  longer returns while the work it started carries on

### 1.1.2

Fixes from building a four-module application with four agents working at the same
time in separate worktrees:

- `wo promote` and `bug promote` write one catalog entry file per item under
  `packs/<name>/catalog/`; `pack catalog` assembles `CATALOG.md` from them and
  the generated file is untracked, so concurrent promotions merge cleanly
  (`parallel-promote`). Legacy single-file catalogs migrate on first use.
- scaffolded suites are self-starting: they start the service when nothing is
  listening, resolve the health endpoint afterwards, and stop the whole process
  group on exit, so a suite that passes for its author passes for everyone
  (`suite-self-starting`)
- the documentation hook ignores template placeholder SOURCE paths

### 1.1.1

Findings from an independent consumer audit of 1.1.0, each with a regression
evaluation under `harness/evals/`:

- release gate validates the real plugin manifest, not only the marketplace one;
  lint rejects frontmatter that is not valid YAML (38 files corrected)
- packaged drivers work from the plugin layout (`plugin-drivers`)
- close and promote read the authoritative latest verification result in both
  drivers; plan-only and PASS-then-FAIL are refused (`promote-latest-status`)
- evidence is bound to the source tree it ran against: closing after the code
  changed requires a re-run (`evidence-freshness`)
- hooks merge by identity: user hooks survive, reinstalls do not duplicate,
  tampered pipeline hooks are restored, minimal removes only pipeline hooks
  (`hooks-merge`)
- reinstalling with a smaller profile removes pipeline-owned skills and
  pack agents the profile does not select; user additions survive
  (`profile-reconcile`)
- hook commands are quoted and relative to the project directory, so paths
  with spaces and moved projects work (`hooks-paths`)
- session orientation lists in-progress and blocked work (`wo list --active`,
  `session-orient-active`)
- the scaffolded suite asserts against the health URL it resolved
  (`suite-health-url`)
- an unknown evaluation name is an error, never "0 passed" (`eval-unknown-name`)
- documented: the documentation hook proves references resolve; the
  factuality validator proves support

## 1.1.0

What the pipeline contains now: the work-order and bug drivers with their
closeout guards, 95 agents, 162 skills plus 9 optional skill packs, 32 slash
commands, 15 hook scripts on three profiles, 23 rule sets chosen by stack
detection, 16 stack profiles, a behavioural test harness and a k6 load harness,
a knowledge-extraction lifecycle for code you did not write, a pack system that
carries verified work forward, a sanitizer, a plugin build, and an evaluation
suite that tests all of it. Everything below changed since 1.0.

### Lifecycle and drivers

- `wo suite <n>` scaffolds a behavioural suite for a work order from the suite
  template, ready to fill in and run.
- `wo verify <n> --run <suite>` executes the suite and writes `EXECUTED — PASS`
  or `EXECUTED — FAIL` from its exit code; logs are kept beside the document,
  without host paths.
- `wo new --area analysis|docs` opens an analysis specification and routes to
  the analysis roles.
- `wo promote` refuses a closeout that still carries template placeholders
  (`--allow-placeholders` overrides) and replaces its catalog entry instead of
  appending a duplicate.
- `wo stats` counts only `EXECUTED — PASS` as evidence and reports closeouts
  whose last run failed.
- `pack search` lists matching catalog entries with their pitfalls first, then
  unique folders; an empty `packs/` exits 0 with an explanation.
- Unpadded work-order numbers accepted everywhere; `--help` on every script.

### Enforcement

- `wo close`, `bug close`, and `wo promote` require `EXECUTED — PASS`.
  Plan-only and failed verifications are refused. Previously this was a
  filename existence check.
- Eight new hooks (7 at 1.0, 15 now): `commit-quality` (blocks staged
  credentials), `config-protection` (blocks weakening a lint or strictness
  config, including sections inside `pyproject.toml`, `setup.cfg`, and
  `package.json`), `post-edit-format`, `post-edit-typecheck`, `doc-file-warning`,
  `design-quality`, `ui-size-check`, `pre-compact`, `doc-claims-check`.
- The quality gate is language-aware (Go, Rust, Java, C#, Ruby, PHP, Python,
  JavaScript) and hooks read `MultiEdit` edits, not just single writes.
- Every hook has a stable `acp:` id and a profile; `ACP_HOOK_PROFILE` and
  `ACP_DISABLED_HOOKS` control them.
- The permission baseline is 77 deliberate allow rules and 21 deny rules,
  replacing a session allowlist that granted `ssh`, `scp`, `dropdb`, and bash.

### Agents and skills

- 95 agents (38 at 1.0): 52 technology specialists and 43 process roles, each
  with responsibilities, templates, a validation checklist, patterns,
  anti-patterns, and common issues. 19 more in opt-in domain packs
  (`identity`, `ml`, `network`, `healthcare`, `gan`).
- 162 skills, from 6 at 1.0: playbooks for testing, verification, API design,
  security review, migrations, deployment, architecture, and per-language and
  per-framework patterns.
- 9 optional skill packs (business-ops, healthcare, marketing, media, ml,
  network, science, supply-chain, web3) selected with `SKILL_PACKS`.
- 32 slash commands, from 8: `/plan`, `/feature-dev`, `/pr`, `/review-pr`,
  `/test-coverage`, `/refactor-clean`, `/checkpoint`, `/prd`, `/learn` and more.
- 23 language rule files condensed to 120 lines or fewer, the worked examples
  moved into companion skills.
- `bin/lint` validates agent frontmatter, skill structure, hook rules, rule
  files, cross-skill links, personal paths, and invisible unicode.

### Knowledge extraction lifecycle

A second lifecycle for understanding and documenting code you did not write,
held to the same evidence discipline as building it.

- `/analyze-repo` runs an eight-phase read-only analysis and produces a Feature
  Profile per feature plus a source-reference index.
- `/status-matrix`, `/docs-brief`, `/docs-primer`, `/docs-reference`,
  `/docs-faq`, `/docs-developer`, `/integration-kit`, `/feasibility`,
  `/review-docs`, and the roles behind them: `repo-analyst`,
  `narrative-curator`, `factuality-validator`, `critical-reviewer`,
  `product-strategist`, `developer-experience-writer`, `api-reference-writer`.
- `core/rules/common/documentation.md`: source or silence, `<!-- SOURCE: -->`
  traceability, status badges, over-claim language, and the rule that the
  validator is never the author. `doc-claims-check` verifies every SOURCE path
  and line number as the document is written.

### Harness

- Configurable authentication, database statistics and preparation from config,
  generic tiers, manifest-driven runners, endpoint-configurable k6 scenarios, a
  parameterised RLS check: nothing presumes the platform it came from. A k6
  import bug that made authenticated load runs pick no user is fixed.
- `bin/eval` runs behavioural evaluations of the pipeline itself and `bin/eval
  live` drives real sessions: ten offline evaluations and four live scenarios.
  `bin/acp test` runs lint, the sanitizer, every evaluation, the plugin build,
  and plugin validation in one command.

### Install and profiles

- `--profile minimal | standard | full` on `install.sh` and `new-project`;
  `bin/detect-stack` chooses the rule sets and fills in the run, test,
  and build commands; `--write` refreshes them once code exists and installs
  the rule sets the code now needs.
- 16 stack profiles (Next.js, NestJS, Remix, Angular, Vue, Svelte, Go, Python, Rust, Java, Kotlin, Swift, C#, PHP, Ruby, Flutter)
  appended to the generated `CLAUDE.md` from what detection found.
- `install.sh` renders every variable in one pass — 41 seconds to 1 — preserves
  `core/agents/overlays/` and `harness/config/` across reinstalls, and records
  the profile. `bin/build-plugin` assembles a plugin from the same sources.

### First-run fixes

Fixes from installing a clean copy and using it for the first time.

- `install.sh` refuses to install the installed copy over itself and re-runs
  from the source it recorded; copy failures abort instead of half-installing.
- Verification and bug closeout templates ship no pre-filled PASS rows,
  approvals, or deployment claims.
- `acp doctor` is profile-aware, understands plugin mode, and checks only the
  pipeline's own template variables.
- The test framework no longer sets `-e` at library scope, works without a TTY,
  and exits non-zero when any test failed. `pipeline.config.sh` resolves its own
  location, so a clone works anywhere.
