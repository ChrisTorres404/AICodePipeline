# AICodePipeline

A work-order system for coding projects. Each task gets a spec and a test. A task can't be
closed until its test has run and passed against the current code.

It works on any codebase, with any coding agent or with none.

## Requirements

macOS or Linux, bash 3.2 or newer, `python3`, `perl` and `git`.

## Install

Clone this repository once:

```bash
git clone https://github.com/ChrisTorres404/AICodePipeline.git pipeline
```

**New project:**

```bash
pipeline/bin/new-project ~/code/my-app --name "My App"
cd ~/code/my-app
export PATH="$PWD/.aicodepipeline/bin:$PATH"
acp doctor .
```

To keep the pipeline and the code in separate folders, add `--pipeline-dir acp --code-dir app`.

**Existing project:**

```bash
cp pipeline/pipeline.config.example.sh /path/to/project/pipeline.config.sh   # edit the top lines
pipeline/bin/install.sh /path/to/project
```

**Claude Code plugin:**

```bash
pipeline/bin/build-plugin
claude plugin add ./pipeline/dist/plugin
```

## Basic use

```bash
wo new "Rate limiting on the public API" --size small
wo verify 0001 --run tests/rate-limit.sh   # runs the test and records the result
wo close 0001                              # closes it, or says what is missing
```

Bugs work the same way with `bug new`, `bug verify` and `bug close`.

Other useful commands:

| Command | What it does |
|---|---|
| `acp doctor` | checks the install |
| `acp check` | checks staged changes for secrets and other problems |
| `wo list` | lists work orders |
| `playbook search <term>` | searches past work you have kept |
| `bin/sanitize <dir>` | scans a folder for secrets before you share it |

## More

- [Getting started](docs/getting-started.md)
- [Adopting an existing project](docs/adopting-an-existing-project.md)
- [Release notes](docs/releases/)

## License

MIT. See `LICENSE` and `THIRD-PARTY-NOTICES.md`.

Christian Torres, [github.com/ChrisTorres404](https://github.com/ChrisTorres404)
