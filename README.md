<img width="1024" height="572" alt="image" src="https://github.com/user-attachments/assets/701e3fd8-6e4a-425f-b450-2f76bffb1d7c" />

# max

**A minimal, local-first coding agent written in Mojo.**

`max` is a single **~300 KB native binary** that takes a task, talks to a local LLM over Modular MAX's OpenAI-compatible API, executes the model's `bash(command)` calls inside a target repository, and prints the answer. 

- **Zero Python at runtime**
- **No dependencies beyond `libcurl`**
- **~16 MB peak RSS** (vs. ~250 MB for Python-based harnesses)

---

## Philosophy

> **Agent capability = Model × Harness.**  
> The harness half should be small enough to hold in your head.

`max` exists to find the smallest execution loop that reliably closes coding tasks unattended. Every line of harness code has to earn its keep: **features ship when they move a benchmark number, not when they sound useful.**

## Where it sits

```text
FRAMEWORKS  Mastra - NeMo OO-Agents - LangGraph
            build-your-own-agent kits; a different layer, not competitors.
            max deliberately uses no framework.

USER  "fix the parser bug"   (one-shot | REPL | piped session)
  |
  v
HARNESS  (ready-to-run agent loops)
  opencode ~1.05M LOC - dsh ~569k - codex ~420k+ - pi ~100k
  aider ~22k + ~100 deps     max ~1.5k LOC -> 300KB native binary
  a bare Python loop covers ~90% of trivial tasks; max is that loop
  plus the verified hardening (bounds, honest results, journal, sandbox)
  |  POST /v1/chat/completions  (+ tools[])
  v
INFERENCE SERVER  (separate OS process; max never manages it)
  Modular `max serve` - verified: KV prefix cache reuse
  ollama              - verified: qwen3:4b drove real tasks
  LM Studio - llama-server - vLLM  (OpenAI-compatible contract)
  |  message.tool_calls[bash(command)]
  v
MODEL  Qwen3-1.7B..14B  - the intelligence; the harness only feeds it

EXECUTION  (inside max)
  tool_call -> fork+exec /bin/bash -c "cmd"
     ├─ process group; killpg on timeout/deadline
     ├─ env scrub: KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL
     ├─ PATH gains `max edit`  (exact-match edits fail loud)
     └─ --sandbox (opt-in): seatbelt, writes = repo + tmp only
            v
     filesystem (the repo)
        pre:  md5 snapshot + APFS clonefile
        post: changed_files + compact diff + no-op warning
            v
     tool result -> next model turn   (journal replays the session)
```

---

## Quickstart

Three steps, copy-paste:

```bash
# 1. Install the Modular tools once (gives you mojo + the `max` model server)
pip install modular        # or: pipx install modular

# 2. Build and install the agent (puts `max` on your PATH)
git clone https://github.com/pierrebrunelle/max.git
cd max && ./install.sh
max --version   # should print "max 0.x", not "MAX 2x" (see note below)

# 3. Use it - from inside any project folder
cd my-project
max "the slugify test fails on unicode input - fix it and re-run the tests"
```

That's it. The first `max` run boots a local model server in the background
(`Qwen/Qwen3-1.7B` by default - about 2 GB of RAM), runs your task, and shuts
the server down when it finishes. Pick a different model with
`MAX_MODEL=<org/name>`.

Already running an OpenAI-compatible server (Modular `max serve`, ollama,
LM Studio)? Point `max` at it and it will use it instead of booting one:

```bash
export MAX_BASE_URL=http://127.0.0.1:11434/v1   # e.g. ollama
export MAX_MODEL=qwen3:4b
max "fix the parser bug and run its tests"
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

> **Note on binary naming:** Both this agent and Modular's CLI are named `max`.
> `pip install modular` puts Modular's `max` on PATH first, so `max` may
> resolve to it (`MAX 2x.y` is Modular's, `max 0.x` is this agent). Fix with
> `export PATH="$HOME/.local/bin:$PATH"` in `~/.zshrc`, or run
> `~/.local/bin/max` directly. The wrapper finds Modular's `max` on `PATH`
> for the model server automatically; if it can't, point
> `MAXCLI=/path/to/modular-max` at it.

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

If `AGENTS.md` or `CLAUDE.md` is present in the repository root, `max` automatically loads it into the system prompt. Run `max --help` for the full list of flags and environment variables.

Hacking on `max` itself: `make` builds `./max` in the repo root, and `scripts/with-max.sh` is the same lazy-serve wrapper that `./install.sh` installs, pointed at the repo build.

---

## Unattended Runs & Guardrails

`max` is built to run unattended loops without runaway context or silent hangs:

- **Journaling & Resume:** Replay or continue interrupted sessions via `--continue` or `--resume FILE`, with live progress written to a `status` file.
- **Context Compaction:** Automatically compacts older tool output instead of crashing at the context window limit.
- **Strict Local Bounds:** Enforces hard caps on request count, wall-clock time, per-command timeout, stdout/stderr output size, and per-request prompt size.
- **Loop & No-Op Detection:** A loop guard halts repeated identical commands. Tool results track `changed_files`, and write-shaped commands that leave the working tree untouched emit an explicit warning to the model.
- **Structured Edits (`max edit`):** `max` is on `PATH` inside model-issued commands, so the model can run `max edit FILE <<'EOF'` with `<<<<<<< SEARCH` / `=======` / `>>>>>>> REPLACE` blocks. The search text must match exactly once or the file is left untouched; a `.py` result that fails `py_compile` is rejected with the compiler's error.
- **Edit Feedback:** When a command changes files, the tool result includes a compact unified diff of what actually changed.
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
