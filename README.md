<img width="1024" height="572" alt="image" src="https://github.com/user-attachments/assets/701e3fd8-6e4a-425f-b450-2f76bffb1d7c" />

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

Say what you want in plain words; max runs the commands to get there:

    cd my-project
    max "the slugify test fails on unicode input - fix it and re-run the tests"
    max "add a --verbose flag to the cli and update the help text"
    max                              # REPL on stdin (max> ), cwd is the repo
    max --repo other/dir "fix the parser bug"
    printf 'fix the parser\nadd tests for it\n' | max   # piped lines share one session

In the REPL:

    max> tests fail on empty input, fix it
    max> !python3 test_kit.py       # run a command yourself; no request spent
    max> /reset                     # drop context, start over
    max> /quit                      # or Ctrl-D

`AGENTS.md`/`CLAUDE.md` in the repo root load into the system prompt.
`./max --help` lists every flag and env knob.

Unattended runs: `--continue`/`--resume FILE` replay journals, a
`status` file shows live progress, compaction rewrites old tool output
instead of dying at the context limit, retries cover transport errors,
and every bound is local (requests, wall clock, per-command timeout,
output caps, token budget, loop guard that stops repeated commands,
`--notify CMD`). `--sandbox` confines model-issued commands to the repo
plus tmp (macOS seatbelt). `--bare`
disables all of it for protocol parity with the reference client
(`bench/ref_client.py` in pierrebrunelle/max-results).

## Benchmark

Rows are verified by each task's own script, not the model's say-so
(github.com/pierrebrunelle/max-results, private).

- 6-task suite, Qwen3-4B, 2 reps: aider 100%, **max --bare 75%**,
  pi 58%; our binary runs at ~16 MB peak RSS vs aider's ~250 MB.
- `long-horizon` (6 bugs across 3 files), Qwen3-14B: aider and pi
  pass; max went 0/4. Free-form `bash` let the model report an edit
  that never landed, where aider's patch format fails loudly - so tool
  results now carry `changed_files`, and a write-shaped command that
  changed nothing gets an explicit `warning`. The remaining gap is the
  model's: `snake_to_camel` got rewritten two dozen ways, all wrong.

Method, tasks and repro: the `bench/` dir of max-results.

## Limits

One task loop, one bash tool, no sandboxing: commands run with your
permissions in the repo path, so use an isolated checkout when it
matters. No streaming, remote providers, MCP or subagents; the model
server is a separate process the agent never manages. Env vars named
for credentials (KEY, TOKEN, SECRET, PASSWORD, CREDENTIAL) are
stripped from model-issued commands.

If you want a polished assistant, sandboxed execution or remote APIs,
use aider or pi. max is for measuring how small the loop can get.
