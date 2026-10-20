# max

A minimal native coding agent in Mojo: one ~255 KB binary that accepts a
task, talks to a local model over MAX's OpenAI-compatible API, runs the
model's `bash(command)` tool calls inside a repo, and prints the answer.
No Python, no runtime deps beyond `libcurl`; the bundle runs under
`env -i` at ~16 MB peak RSS.

Agent capability ≈ model × harness. Weights are the server's problem;
the smallest harness that closes the loop (task → tool calls → bounded
shell → answer) is the bet. The working rule is subtraction.

## Quickstart

Prereqs: `mojo` on PATH to build; Modular's MAX CLI to serve the model.

```bash
make
MAX_MODEL=Qwen/Qwen3-1.7B ./scripts/with-max.sh --repo ./project \
  "Fix the parser bug and run its tests"
```

`with-max.sh` lazily starts `max serve`, runs the task, and cleans up
what it started. Already serving? `MAX_MODEL=<org/name> ./max --repo DIR
"task"`. `./install.sh` puts a `max` wrapper in `~/.local/bin`.

Note: our binary is `max`; Modular's MAX CLI is also `max` — point
`MAXCLI=/path/to/modular-max` in `with-max.sh` if they share a PATH.

## Using it

```bash
./max --repo DIR "task"                          # one-shot
./max --repo DIR                                 # interactive REPL (max> )
printf 'fix\nadd tests\n' | ./max --repo DIR     # piped tasks share a session
```

`AGENTS.md`/`CLAUDE.md` in the repo root load into the system prompt.
`./max --help` lists every flag and env knob.

Built to be left unattended on a local model:

- `--continue` replays the repo's journal to resume its session;
  `--resume FILE` resumes any journal; a `status` file shows live
  `req= cmds= prompt_tokens= elapsed=` progress.
- Compaction rewrites the oldest tool outputs to re-fetchable stubs
  instead of dying at the context limit; retries cover transport errors.
- Every bound is local: request count, wall clock, per-command timeout,
  output caps, token budget, repeat-command loop guard, `--notify CMD`.
- `--bare` disables all of it for protocol parity with `tests/ref_client.py`.

## Benchmark

75% pass at ~16 MB peak RSS on Qwen3-4B (the 6-task × 5-harness run in
`bench/RESULTS.md`); the same 18-task suite runs aider, pi, dsh and
opencode at the same endpoint. Method and raw logs: `bench/README.md`.

## Limits

Single task loop; one bash tool. No streaming, providers, MCP, subagents,
or sandboxing — commands run with your permissions in the repo path, so
use an isolated checkout when isolation matters. The model server is a
separate process; the agent never manages model lifecycle.
