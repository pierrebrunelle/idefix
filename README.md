# mojo-max-agent

A minimal native coding agent in Mojo. It accepts a coding task, talks to a
local model served by MAX through the OpenAI-compatible chat API, runs the
model's `bash(command)` tool calls in a repository, and returns the final
answer. No Python interpreter is required to run the agent itself.

## Deployable footprint (measured)

| Artifact | Size |
| --- | --- |
| `agent` binary | 205 KB |
| Mojo runtime dylibs (4) | ~2.7 MB |
| **Total bundle** | **~2.9 MB** |

Plus macOS system libraries (`libcurl`, `libSystem`). cJSON is statically
linked; the process shim is a static archive. The bundle runs under `env -i`
with no Mojo toolchain, no Python, and no PATH. Startup is sub-10 ms; peak RSS
on a real two-request run is ~16 MB.

MAX, the model, and the task's own tools (bash, python3, git) are separate
deployment concerns and are not counted in the client footprint.

## Usage

```bash
max serve --model Qwen/Qwen3-1.7B --devices cpu --quantization-encoding float32

MAX_MODEL=Qwen/Qwen3-1.7B ./agent --repo ./project \
  "Fix the parser bug and run its tests"
```

No TASK → interactive REPL on stdin with one shared session (follow-ups see
prior context). `/reset` clears history, `/quit` or Ctrl-D exits, and piped
stdin runs one task per line:

```bash
./agent --repo ./project            # interactive
printf 'fix the parser\nupdate its tests\n' | ./agent --repo ./project
```

Configuration:

| Knob | Source | Default |
| --- | --- | --- |
| Endpoint | `MAX_BASE_URL` | `http://127.0.0.1:8000/v1` |
| Model | `MAX_MODEL` (required) | - |
| Auth | `MAX_API_KEY` | none |
| Instructions file | `--instructions FILE` | none |
| Max requests | `--max-requests N` | 40 |
| Wall clock | `--max-seconds N` | 1800 |
| Per-command timeout | `--max-command-seconds N` | 120 |
| Command output cap | `--max-output-bytes N` | 65536 |
| Prompt token budget | `--max-prompt-tokens N` | off |
| Sampling | `--temperature F` | server default |
| Transcript | `--transcript FILE` | off |
| Calls per response | `--max-calls-per-response N` | 8 |

The repo path is a working directory, not a sandbox. The agent runs with the
invoking user's permissions; use an isolated checkout when isolation matters.

## What the agent guarantees

- One `bash(command)` tool. Each call is a fresh `/bin/bash -c` process with
  the repository as its working directory.
- Complete tool-call/result pairing. One `role:tool` reply per call, including
  calls rejected for invalid arguments (which never execute).
- Bounded everything: request count, wall clock, HTTP size, per-command
  duration, and retained output (head+tail with a discarded-byte count).
- Process-group cleanup on timeout: SIGTERM, then SIGKILL after a grace
  period; orphaned grandchildren die with the group.
- Tool calls emitted as `<tool_call>` markup in `content` (models without a
  server-side tool parser) are extracted and replayed as structured calls.
- `<think>` regions are stripped before parsing and reporting.

## Layout

- `agent.mojo` - CLI, configuration, task loop, REPL
- `bindings.mojo` - libcurl/cJSON FFI and POSIX exec with bounded capture
- `agent_shim.c` - signal handling, process-group tracking, stdin readline
- `vendor/cJSON.{c,h}` - vendored JSON parser, statically linked
- `tests/` - stub server, test suite (`tests/run.sh`), Python reference client
- `bench/` - fixture and harness comparing the Mojo agent to the reference

## Build

Requires the Mojo compiler (install via `uv tool install` or pixi) and a C
compiler for the shim and cJSON.

```bash
make            # cc: vendor/cJSON.o + agent_shim.o -> libagent_c.a, mojo build
make test       # stub-server trouble-path suite
```

Linux x86_64: the code is POSIX-only (fork/execv/poll/waitpid, getline,
signal shims); `make` works with pixi-installed Mojo and
`apt install libcurl4-openssl-dev` (or the pixi curl). The macOS `bundle`
target uses `otool`/`install_name_tool`; on Linux ship the runtime `.so`
set beside the binary with `rpath $ORIGIN` instead.

## Benchmark

```bash
# GPU serving (fastest): install Metal toolchain once, then:
xcodebuild -downloadComponent MetalToolchain
max serve --model Qwen/Qwen3-4B-Instruct-2507   # GPU default

# CPU serving (no toolchain): --devices cpu --quantization-encoding float32

MAX_MODEL=Qwen/Qwen3-4B-Instruct-2507 python3 bench/run_matrix.py 2
python3 bench/analyze.py
```

`bench/tasks/` holds fourteen SWE-style tasks (issue text -> edit ->
independent `verify.sh`), graded from a one-line fix to chained defects,
CLI-arg handling, a performance bound, and a test-tamper trap. The runner
clones each task repo into a temp dir, runs each client with a watchdog
timeout, and records pass, requests, commands, prompt tokens, wall time, and
peak RSS (via `wait4` rusage) into `bench/results.jsonl`. `analyze.py` writes
`bench/RESULTS.md` and per-model SVG charts to `bench/charts/<model>/`.
Comparison clients: `tests/ref_client.py` (identical protocol, stdlib
Python), aider, pi, and deepseek-harness (`dsh`). pi and dsh speak native
OpenAI tool calling, which this MAX build cannot parse, so they route through
`bench/toolcall_proxy.py` (:8001). On hybrid-thinking models the proxy also
injects `chat_template_kwargs` (e.g. `enable_thinking=false`); mojo/ref/aider
use a no-rewrite variant on :8002 since mojo parses `<tool_call>` text
natively.

## Verified end to end

- macOS arm64, Mojo 1.1, MAX 26.6, `Qwen/Qwen3-1.7B` on CPU (float32).
- Task: fix `add()` in `calc.py`, run `test_calc.py` to verify.
- Result: `calc.py` contained `a + b` and the test printed `TEST PASSED`;
  2 requests, 3 commands, ~2.3k prompt tokens.
- The bundle (`bundle/`) performs the same round trip under `env -i`.

## Benchmark findings

Full data in `bench/RESULTS.md` — 60 runs: 6 SWE-style tasks x 2 reps x 5
harnesses on `Qwen3-4B-Instruct-2507` (MAX, GPU), plus a second board on
`Qwen3-14B`.

| harness | pass rate | median wall | peak RSS |
| --- | --- | --- | --- |
| aider | 12/12 (100%) | 23.1 s | 250 MB |
| **mojo-max-agent** | **9/12 (75%)** | **24.5 s** | **15.8 MB** |
| python-loop (ref_client.py) | 8/12 (67%) | 31.5 s | 18.0 MB |
| pi | 7/12 (58%) | 79.8 s | 126 MB |
| deepseek-harness | 0/12 (0%) | 420.3 s | 192 MB |

How to read it:

- aider wins on pass rate because it is a different harness class: one
  request, whole-file edits, files pre-staged in context. It cannot run
  tests or recover from failed commands in this configuration — the loop
  harnesses can. On single-file fix tasks its format is simply advantaged.
- mojo-max-agent matches aider's wall time at ~6% of its peak memory and
  ~3 MB on disk versus a Python interpreter + 108 packages.
- mojo and python-loop are protocol-identical, so their pass-rate delta is
  sampling noise; the real deltas are RSS (15.8 vs 18.0 MB), startup, and
  deployed size.
- pi completes real tool-call loops through the proxy but pays ~3x wall and
  ~8x RSS versus mojo; its failures are mostly generation loops, not harness
  errors.
- deepseek-harness scored 0% because Qwen3-4B emits refusal text, not tool
  calls, under its ~6k-token plugin system prompt — a model x harness
  interaction, not a verdict on dsh with larger models.
- Agent CPU per run is ~0.01 s; all wall time is model inference. Serving
  config dominates correctness (4B/GPU >> 1.7B/CPU on the same suite).

## Limits of this version

Single task loop with in-memory history. No saved sessions, streaming,
providers, MCP, subagents, or sandboxing. MAX does not manage model lifecycle
from the agent; the server must be up and configured.
