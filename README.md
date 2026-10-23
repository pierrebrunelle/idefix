# max

A minimal coding agent in Mojo: one ~255 KB binary that takes a task,
talks to a local model over MAX's OpenAI-compatible API, runs the
model's `bash(command)` calls inside a repo, and prints the answer.
No Python, no runtime deps beyond libcurl; ~16 MB peak RSS.

The bet is that agent capability = model x harness, and the harness
half should be small enough to hold in your head. max exists to find
the smallest loop that still closes tasks unattended. Features ship
when they move a benchmark number, not when they sound useful.

## Quickstart

Prereqs: `mojo` on PATH to build; Modular's MAX CLI to serve a model.

    make
    MAX_MODEL=Qwen/Qwen3-1.7B ./scripts/with-max.sh --repo ./project \
      "Fix the parser bug and run its tests"

`with-max.sh` lazily starts `max serve`, runs the task, and cleans up
what it started. Already serving? `MAX_MODEL=<org/name> ./max --repo
DIR "task"`.

A run looks like:

    $ ./max --repo . "test_slugify fails on 'Creme Brulee'; fix it"
    [model] Reading slugify and its test.
    [model] lower() runs before the accent strip. Patching.
    [model] Tests pass.
    [max] requests=4 commands=3 prompt_tokens=812 tokens=1982+71 elapsed=21s exit=0
    Fixed: normalize accents before lowercasing in slugify().

Note: our binary is `max`; Modular's CLI is also `max`. Point
`MAXCLI=/path/to/modular-max` in `with-max.sh` if they collide.
`./install.sh` puts a `max` wrapper in `~/.local/bin`.

## Using it

    ./max --repo DIR "task"                        # one-shot
    ./max --repo DIR                               # interactive REPL (max> )
    printf 'fix\nadd tests\n' | ./max --repo DIR   # piped tasks share a session

`AGENTS.md`/`CLAUDE.md` in the repo root load into the system prompt.
`./max --help` lists every flag and env knob.

Unattended runs: `--continue`/`--resume FILE` replay journals, a
`status` file shows live progress, compaction rewrites old tool output
instead of dying at the context limit, retries cover transport errors,
and every bound is local (requests, wall clock, per-command timeout,
output caps, token budget, loop guard, `--notify CMD`). `--bare`
disables all of it for protocol parity with `tests/ref_client.py`.

## Benchmark

Rows are verified by each task's own script, not the model's say-so
(`bench/RESULTS.md`; raw logs: github.com/pierrebrunelle/max-results).

- 6-task suite, Qwen3-4B, 2 reps: aider 100%, **max 75%**, pi 58%;
  max runs at ~16 MB peak RSS vs aider's ~250 MB.
- `long-horizon` (6 bugs across 3 files), Qwen3-14B: aider and pi
  pass; max did not. Free-form `bash` let the model report an edit
  that never landed, where aider's patch format fails loudly. Tool
  results now carry `changed_files`, so a no-op edit cannot read as
  success.

Method and repro: `bench/README.md`.

## Limits

One task loop, one bash tool, no sandboxing: commands run with your
permissions in the repo path, so use an isolated checkout when it
matters. No streaming, remote providers, MCP or subagents; the model
server is a separate process the agent never manages. Env vars named
for credentials (KEY, TOKEN, SECRET, PASSWORD, CREDENTIAL) are
stripped from model-issued commands.

If you want a polished assistant, sandboxed execution or remote APIs,
use aider or pi. max is for measuring how small the loop can get.
