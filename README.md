<img width="1024" height="572" alt="image" src="https://github.com/user-attachments/assets/701e3fd8-6e4a-425f-b450-2f76bffb1d7c" />

# max

**A minimal, local-first coding agent written in Mojo.**

`max` is a single **~255 KB native binary** that takes a task, talks to a local LLM over Modular MAX's OpenAI-compatible API, executes the model's `bash(command)` calls inside a target repository, and prints the answer. 

- **Zero Python at runtime**
- **No dependencies beyond `libcurl`**
- **~16 MB peak RSS** (vs. ~250 MB for Python-based harnesses)

---

## Philosophy

> **Agent capability = Model × Harness.**  
> The harness half should be small enough to hold in your head.

`max` exists to find the smallest execution loop that reliably closes coding tasks unattended. Every line of harness code has to earn its keep: **features ship when they move a benchmark number, not when they sound useful.**

---

## Quickstart

### Prerequisites
- [`mojo`](https://www.modular.com/mojo) on `PATH` (to build)
- Modular's `max` CLI (to serve a local model)

### Build & Run

```bash
make
MAX_MODEL=Qwen/Qwen3-1.7B ./scripts/with-max.sh --repo ./project \
  "Fix the parser bug and run its tests"
```

`with-max.sh` lazily boots `max serve`, runs the task against the target repo, and tears down what it started. If you already have an OpenAI-compatible server running:

```bash
MAX_MODEL=<org/name> ./max --repo ./project "Fix the parser bug and run its tests"
```

### Example Run

```text
$ ./max --repo . "test_slugify fails on 'Creme Brulee'; fix it"
[model] Reading slugify and its test.
[model] lower() runs before the accent strip. Patching.
[model] Tests pass.
[max] requests=4 commands=3 prompt_tokens=812 tokens=1982+71 elapsed=21s exit=0
Fixed: normalize accents before lowercasing in slugify().
```

> **Note on binary naming:** Both this agent and Modular's CLI are named `max`. If they collide on your `PATH`, point `MAXCLI=/path/to/modular-max` when using `with-max.sh`. Running `./install.sh` installs a `max` wrapper into `~/.local/bin`.

---

## Usage

Describe what you want in plain English. `max` runs the shell commands required to inspect, patch, and verify the repo:

```bash
cd my-project

# One-shot tasks
max "the slugify test fails on unicode input - fix it and re-run the tests"
max "add a --verbose flag to the cli and update the help text"
max --repo ../other-dir "fix the parser bug"

# Multi-step piped session (lines share context)
printf 'fix the parser\nadd tests for it\n' | max

# Interactive REPL (uses current working directory as repo)
max
```

### Interactive REPL

```text
max> tests fail on empty input, fix it
max> !python3 test_kit.py       # run a shell command directly; 0 tokens spent
max> /reset                     # clear conversation context and start fresh
max> /quit                      # exit (or Ctrl-D)
```

If `AGENTS.md` or `CLAUDE.md` is present in the repository root, `max` automatically loads it into the system prompt. Run `./max --help` for the full list of flags and environment variables.

---

## Unattended Runs & Guardrails

`max` is built to run unattended loops without runaway context or silent hangs:

- **Journaling & Resume:** Replay or continue interrupted sessions via `--continue` or `--resume FILE`, with live progress written to a `status` file.
- **Context Compaction:** Automatically compacts older tool output instead of crashing at the context window limit.
- **Strict Local Bounds:** Enforces hard caps on request count, wall-clock time, per-command timeout, stdout/stderr output size, and total token budget.
- **Loop & No-Op Detection:** A loop guard halts repeated identical commands. Tool results track `changed_files`, and write-shaped commands that leave the working tree untouched emit an explicit warning to the model.
- **Transport Resilience:** Automatic retries across transient local server/transport errors, plus `--notify CMD` hooks on completion.
- **macOS Seatbelt Sandboxing (`--sandbox`):** Confines model-issued commands to the target repository and `/tmp`.
- **Protocol Parity Mode (`--bare`):** Disables all harness guardrails for strict protocol parity with the reference benchmark client (`bench/ref_client.py` in `pierrebrunelle/max-results`).

---

## Benchmarks

Every benchmark row is verified by the task's independent test script—never by the model's self-report (full methodology, tasks, and reproduction harness in `pierrebrunelle/max-results`).

### 6-Task Suite (`Qwen3-4B`, 2 reps)

| Harness | Pass Rate | Peak RSS | Runtime Stack |
| :--- | :---: | :---: | :--- |
| `aider` | 100% | ~250 MB | Python |
| **`max --bare`** | **75%** | **~16 MB** | **Mojo (native binary)** |
| `pi` | 58% | — | — |

### Failure Analysis: `long-horizon` (6 bugs across 3 files, `Qwen3-14B`)
- **Result:** `aider` and `pi` pass; `max` went `0/4`.
- **Diagnosis:** Free-form `bash` allowed the model to think an edit landed when it hadn't, whereas `aider`'s structured diff format fails loudly on malformed patches.
- **Harness Fix:** Tool results now explicitly return `changed_files`, and write-shaped commands that modify zero files return an explicit `warning` to the model. The remaining gap on this task is model capability (`snake_to_camel` was rewritten two dozen ways, all wrong).

---

## Scope & Limits

- **Single loop, single tool:** One task loop and one `bash(command)` tool.
- **Execution permissions:** Unless `--sandbox` (macOS seatbelt) is passed, commands execute with your user permissions inside the repo path. Use an isolated checkout or container when running untrusted tasks.
- **Credential scrubbing:** Environment variables matching `KEY`, `TOKEN`, `SECRET`, `PASSWORD`, or `CREDENTIAL` are automatically stripped from model-issued subshells.
- **Deliberate non-goals:** No token streaming, no remote cloud API providers, no MCP, and no subagents. The model server is a separate OS process that the binary never manages directly.

If you want a polished pair-programming UI, cross-platform container sandboxing, or hosted cloud APIs, use **aider** or **pi**. `max` is a laboratory for measuring how small the agent loop can get.
