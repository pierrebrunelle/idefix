# max

A minimal native coding agent in Mojo: one ~255 KB binary that accepts a
task, talks to a local model over MAX's OpenAI-compatible API, runs the
model's `bash(command)` tool calls inside a repo, and prints the answer.
No Python, no runtime deps beyond `libcurl` — the bundle (~3 MB with Mojo
dylibs) runs under `env -i`. Peak RSS on a real run is ~16 MB.

## Quickstart

```bash
# build (needs mojo on PATH)
make

# one command: lazily starts `max serve` (Modular MAX CLI) if needed,
# runs the task, and cleans up what it started
MAX_MODEL=Qwen/Qwen3-1.7B ./scripts/with-max.sh --repo ./project \
  "Fix the parser bug and run its tests"
```

Server already running? Skip the wrapper:

```bash
MAX_MODEL=Qwen/Qwen3-1.7B ./max --repo ./project "task"
```

Note: our binary is `max`; Modular's MAX CLI is also `max`. Point
`MAXCLI=/path/to/modular-max` in `with-max.sh` if they share a PATH.

## Modes

```bash
./max --repo DIR "task"          # one-shot
./max --repo DIR                 # interactive REPL (max> )
printf 'fix\nadd tests\n' | ./max --repo DIR   # piped tasks share one session
```

REPL: `/reset` clears context, `/quit` or `/exit` or Ctrl-D exits, `!cmd`
runs a shell command locally without a model request.

`AGENTS.md`/`CLAUDE.md` in the repo root load into the system prompt.
`--instructions FILE` appends more.

## Long-running runs

Built to be left unattended on a local model:

- `~/.max/sessions/<repo-hash>/journal.jsonl` is the append-only event
  log (messages, retries, compactions, done); `<repo-hash>` is a hash of
  the repo's real path. `--continue` replays it to resume this repo's
  session; `--resume FILE` resumes any journal.
- `status` in the same dir shows live `req= cmds= prompt_tokens= elapsed=
  last=<cmd>` — `cat` it from another terminal.
- `--compact-at N` (default 24000 prompt tokens) rewrites the oldest tool
  outputs to `[cleared; re-run the command to inspect]`: re-fetchable data,
  pairing preserved, logged every time. A context-length HTTP 400 triggers
  the same clear and retries the request. `--compact-keep N` (default 6)
  sets how many recent results survive.
- `--retries N` (default 3) retries transport/5xx failures at 1s/2s/4s.
- A command repeated 3+ times in a row gets `loop_warning` appended to its
  tool result; `--no-loop-guard` disables.
- `--notify CMD` runs CMD in the repo when the run finishes.
- `--bare` disables every post-v1 behavior (no state files, no AGENTS.md,
  no compaction/retries/echo) for protocol parity with `tests/ref_client.py`;
  `--continue`, `--resume` and `--notify` are rejected, not ignored.

## Configuration

| Knob | Source | Default |
| --- | --- | --- |
| Endpoint | `MAX_BASE_URL` | `http://127.0.0.1:8000/v1` |
| Model | `MAX_MODEL` (required) | - |
| Auth | `MAX_API_KEY` | none |
| State dir | `--state-dir` / `MAX_STATE_DIR` | `$HOME/.max` |
| Max requests | `--max-requests N` | 40 |
| Wall clock | `--max-seconds N` | 1800 |
| Per-command timeout | `--max-command-seconds N` | 120 |
| Command output cap | `--max-output-bytes N` | 65536 |
| HTTP response cap | `--max-http-bytes N` | 64 MiB |
| Prompt token budget | `--max-prompt-tokens N` | off |
| Sampling | `--temperature F` | server default |
| Transcript | `--transcript FILE` | off |
| Calls per response | `--max-calls-per-response N` | 8 |

All bounds are enforced locally; the repo path is a working directory, not
a sandbox. The agent runs with your permissions — use an isolated checkout
when isolation matters.

## Benchmark

`bench/` runs the same 14-task suite against reference, aider, pi, dsh and
opencode harnesses at the same endpoint (max runs with `--bare` for
protocol parity): `python3 bench/run_matrix.py 2`, then
`python3 bench/analyze.py` writes `bench/RESULTS.md`. Headline on
Qwen3-4B-Instruct-2507: 75% pass at ~16 MB peak RSS.

## Install

`./install.sh` builds a bundle into `~/.local/max` and writes a
`~/.local/bin/max` wrapper (shadows Modular's `max` CLI on PATH — rename
or use `./max` from the repo if that matters).

## Limits

Single task loop; one bash tool. No streaming, providers, MCP, subagents,
or sandboxing. Command output keeps the first and last halves of the byte
cap, and invalid UTF-8 in it is replaced with U+FFFD on the wire. The
model server is a separate process — the agent never manages model
lifecycle (`with-max.sh` only wraps startup for you).
