# max — agent principles

`max` measures the smallest loop that reliably closes coding tasks.
Agent capability = model x harness; the harness half should be small
enough to hold in your head.

## Optimization targets (in order)

1. pass@1 per token on small local models (Qwen3 1.7B-14B)
2. systems footprint: binary size, RSS, wall-clock

## Rules

- **Subtract first.** A change that removes code beats one that adds.
- **Evidence or it does not ship.** A feature lands only if it moves a
  measured number or closes a demonstrated correctness hole. Cite the
  benchmark row or the bug.
- **One model-facing tool: `bash(command)`.** New affordances ride
  inside commands (e.g. `max edit`), never new tool schemas.
- **Every bound is local and enforced.** Requests, wall clock, command
  timeout, output caps, token budget, loop guard. No outer watchdog.
- **Tool results do not lie.** exit 0 with no files changed is not
  success; surface `changed_files`, `diff`, and warnings to the model.
- **`--bare` is the protocol oracle.** Its wire output stays
  byte-identical to `bench/ref_client.py` in max-results; verify with
  `bench/check_parity.py`.
- **Benchmarks live in max-results**, not this repo: tasks, harness
  comparisons, logs, RESULTS.md.
- **Verification must be able to fail.** Show a check going red on a
  broken variant before calling it a test.
- **Report unknowns as unknowns.** An unmeasured claim is a claim, not
  a fact.

## Verification

`make` builds (needs `mojo` on PATH or `MOJO=/path/to/mojo`).
`bash tests/run.sh` runs the stub-server suite; report the PASS/FAIL
count. The suite is the contract — new behavior ships with a check.

- Tests bind port 18923. Kill strays before diagnosing mass failures:
  `lsof -ti:18923 | xargs kill -9`.
- FFI traps (dangling `as_c_string_span`, calloc out-params, in/out
  bufsize) are documented in `.devin/skills/mojo-c-ffi/SKILL.md`. Read
  it before touching `external_call` marshalling.
- Commit with `git commit -F msgfile`, not `-m "$(cat <<'EOF' ...)"`:
  an apostrophe in the message breaks the nested quoting.
- Under `make`, `command -v` resolves absolute tool paths; `which`
  does not.
- A `mojo build` binary is not portable: it links `@rpath` Mojo
  dylibs. Ship `make bundle` output (binary + dylibs + with-max).
