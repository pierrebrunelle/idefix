<img width="1024" height="338" alt="idefix — a tiny native coding agent for local models: one tool, one loop, 300KB native" src=".github/banner.png" />

# idefix

**A tiny native coding agent for local models. One tool: `bash`. One loop.**

A ~300 KB Mojo binary, ~1.3k lines of agent logic you can read in an hour.
It takes a task, talks to any OpenAI-compatible server (`max serve`,
Ollama, LM Studio, llama-server, vLLM), runs the model's `bash(command)`
calls inside your repo, and prints the answer. Zero Python at runtime,
~16 MB peak RSS.

Capability = model × harness. The harness half should be small enough to
hold in your head — that is the whole reason idefix exists.

## Quickstart — fresh terminal, copy-paste each block

idefix needs two things: the binary, and a local model to talk to.

```bash
# 1. install idefix (prebuilt binary, no toolchain needed)
curl -fsSL https://github.com/pierrebrunelle/idefix/releases/latest/download/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"     # makes `idefix` resolve in this shell
idefix --version                          # sanity check
```

```bash
# 2. get a model — Ollama is the easiest local server
brew install ollama && brew services start ollama    # macOS
# Linux instead: curl -fsSL https://ollama.com/install.sh | sh
# if `ollama pull` says "could not connect", run `ollama serve` in a second tab
ollama pull hf.co/nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB:Q4_K_M   # ~6 GB
```

```bash
# 3. run it inside any repo — it finds Ollama on :11434 by itself
cd my-project
idefix "fix the parser bug and re-run the tests"
```

The Nemotron pull above is the model we measured (4/4 verifier-scored
tasks on Ollama). Any tool-capable model on `ollama` works too —
`ollama pull qwen3:8b` is a lighter download. Careful with
`Qwen3-4B-Instruct` builds: some templates emit tool calls as plain text
and no commands run (a protocol failure, not a model failure).

Not working?

- `command not found: idefix` — run the `export PATH=...` line, or call
  `~/.local/bin/idefix` directly.
- `with-max: no server ... and no model-server CLI` — step 2 missing:
  nothing is listening on `:11434`/`:8000`/`:1234`, so there is no model
  to talk to.

## Use

```bash
cd my-project
idefix "the slugify test fails on unicode input - fix it"
```

Already serving? The wrapper probes `ollama :11434`, `max serve :8000`,
`LM Studio :1234` and adopts the loaded model — zero exports needed.
With nothing running it falls back to lazily booting `max serve`
(requires Modular's `max` CLI installed). To pick one explicitly:

```bash
export IDEFIX_BASE_URL=http://127.0.0.1:11434/v1   # e.g. ollama
export IDEFIX_MODEL=qwen3:8b                      # or ~/.idefix/config
```

```text
$ idefix --repo . "test_slugify fails on 'Creme Brulee'; fix it"
[idefix] requests=4 commands=3 prompt_tokens=812 tokens=1982+71 elapsed=21s exit=0
Fixed: normalize accents before lowercasing in slugify().
```

```bash
printf 'fix the parser\nadd tests for it\n' | idefix   # piped session
idefix                                                # REPL (/reset, !cmd, /quit)
idefix --events "task"                                # NDJSON events on stdout (embedding)
idefix edit file.py <<'EOF'                           # structured edit
<<<<<<< SEARCH
old code
=======
new code
>>>>>>> REPLACE
EOF
```

## What a command goes through

**Editor UI, no UI code:** `acp/idefix-acp.py` is a ~200-line Python shim
that makes idefix an [ACP](https://agentclientprotocol.com) agent — works
in Zed and JetBrains agent panels. Setup: [`acp/README.md`](acp/README.md).

`bash -c` in the repo: own process group, killpg on timeout, env scrubbed
of `KEY`/`TOKEN`/`SECRET`/`PASSWORD`/`CREDENTIAL`. After each command the
model sees `changed_files`, a compact diff, and a warning when a
write-shaped command changed nothing — exit 0 with no diff is reported as
a warning, not success.

Every bound is a flag: `--max-requests --max-seconds
--max-command-seconds --max-output-bytes --max-http-bytes
--max-prompt-tokens --max-calls-per-response --retries --no-loop-guard
--doom-warn --compact-at --bare --sandbox --continue
--resume`. `--bare` strips the guardrails and is byte-parity with the
reference client; `--sandbox` confines writes to repo + tmp.

## Measured: one model, five serving layers

Same Mojo binary, same model (Qwen3-4B-Instruct-2507, 4-bit per backend),
same 4 verifier-scored coding tasks, 1 rep — directional, not statistical:

<img width="760" alt="serving layer results" src=".github/serve-matrix.svg" />

| serving layer | tasks passed | decode | total task wall |
|---|---|---|---|
| MLX-LM | 3/4 | 10 tok/s | 60s |
| Ollama + tool-call proxy | 3/4 | 44 tok/s | 191s |
| llama.cpp | 1/4 | 67 tok/s | 129s |
| Ollama native | 0/4 | 43 tok/s | protocol fail |
| `max serve` | 0/4 | 0.5 tok/s | wall-capped |

Two findings the raw numbers hide:

- "OpenAI-compatible" does not guarantee structured tool calls. Ollama's
  template for this model emits `<tool_call>` text inside a reasoning
  field; idefix executed zero commands until a ~100-line proxy rewrote
  it into `tool_calls`. That is a protocol failure, not a model failure.
- Fastest decode did not win. llama.cpp generated 6x faster than MLX
  but passed fewer tasks — the serving layer changes what the model
  effectively is (template, quant, tool format), not just its speed.
- The winner depends on the model. Re-running the same matrix on
  Nemotron Bolt flipped it: Ollama passed 4/4 (mlx 2/4, llama.cpp 2/4).
  There is no universal best backend — measure the model you serve.

Data and methodology:
[pierrebrunelle/max-results](https://github.com/pierrebrunelle/max-results/tree/main/bench).

## Honest status

Benchmarks (verifier-scored, never self-reported; methodology in
[pierrebrunelle/max-results](https://github.com/pierrebrunelle/max-results)):
same-tier pass rates as aider and pi at ~1/15th the footprint. On hard
tasks every harness fails at 4B — the binding constraint is the model,
and idefix is built so you can measure exactly that.

No TUI, no MCP, no cloud providers, no sub-agents — that is pi, aider,
claude-code. Commands run as your user inside `--repo` unless
`--sandbox`. Internals: [ARCHITECTURE.md](ARCHITECTURE.md).
