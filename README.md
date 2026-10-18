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

- `agent.mojo` - CLI, configuration, task loop
- `bindings.mojo` - libcurl/cJSON FFI and POSIX exec with bounded capture
- `agent_shim.c` - signal handling and process-group tracking
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

## Benchmark

```bash
# with `max serve` running a tool-capable model:
bash bench/bench.sh 3
```

Each run copies `bench/fixture/` to a temp repo, runs the task, and records
pass/fail, requests, commands, prompt tokens, and wall time for both the Mojo
agent and `tests/ref_client.py` (identical protocol, stdlib Python).

## Verified end to end

- macOS arm64, Mojo 1.1, MAX 26.6, `Qwen/Qwen3-1.7B` on CPU (float32).
- Task: fix `add()` in `calc.py`, run `test_calc.py` to verify.
- Result: `calc.py` contained `a + b` and the test printed `TEST PASSED`;
  2 requests, 3 commands, ~2.3k prompt tokens.
- The bundle (`bundle/`) performs the same round trip under `env -i`.

## Limits of this version

Single task loop with in-memory history. No saved sessions, streaming,
providers, MCP, subagents, or sandboxing. MAX does not manage model lifecycle
from the agent; the server must be up and configured.
