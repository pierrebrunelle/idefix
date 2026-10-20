# max

A minimal native coding agent in Mojo: one ~255 KB binary that accepts a
task, talks to a local model over MAX's OpenAI-compatible API, runs the
model's `bash(command)` tool calls inside a repo, and prints the answer.
No Python, no runtime deps beyond `libcurl` — the bundle (~3 MB with Mojo
dylibs) runs under `env -i`. Peak RSS on a real run is ~16 MB.

## The bet

Agent capability ≈ model × harness. Weights are the server's problem;
the harness — prompt, tools, memory, loop discipline — is ours, and the
smallest one that closes the loop (task → tool calls → bounded shell →
answer) captures most of the value. So the optimization target is:

                verified improvements
    maximize  ─────────────────────────
              tokens × wall-s × mechanism

- **Verified improvement per unit of mechanism.** A feature ships when
  it survives a bench measurement or names the failure it prevents.
  `bench/` is the ledger; `bench/check_tasks.py` proves the ledger's
  tasks are solvable before a row is trusted.
- **Cost per iteration.** `opt/` runs max as an optimization engine —
  mutate → score → keep/discard, hundreds of times, unattended. At
  ~16 MB RSS and instant startup, the model is the bottleneck, never
  the harness.
- **Failure modes you can enumerate.** One bash tool, one endpoint,
  an append-only journal. "Not a sandbox" is documented, not patched
  over — the safe pattern is shipped (`with-max.sh`, tmpdir runs), not
  implied.

The working rule is subtraction: when two mechanisms carry the same
guarantee, keep the one with fewer states. Reviews of this repo delete
code more often than they add it.

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

`bench/` runs an 18-task suite against max (a `--bare` arm and a
full-featured `maxv2` arm), a python reference loop, aider, pi, dsh and
opencode at the same endpoint: `MAX_MODEL=<org/name> python3 bench/run_matrix.py 2`, then
`python3 bench/analyze.py` writes `bench/RESULTS.md`. Headline on
Qwen3-4B-Instruct-2507 (the 6-task x 5-harness run in `bench/RESULTS.md`):
75% pass at ~16 MB peak RSS. Setup and repro:
`bench/README.md`.

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
