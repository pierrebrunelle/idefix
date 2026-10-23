# bench

Harness comparison matrix: every task in `tasks/` x every harness x N
reps, rows appended to `results.jsonl`; `analyze.py` renders `RESULTS.md`
and `charts/<model-slug>/*.svg`.

Harnesses: `mojo` (max `--bare`), `maxv2` (max with journal, compaction
and retries on), `ref` (`tests/ref_client.py`), `aider`, `pi`, `dsh`,
`opencode`. mojo/maxv2/ref/aider talk to `max serve` on :8000; pi/dsh/
opencode go through `toolcall_proxy.py` (default :8001), which rewrites
Hermes `<tool_call>` text into OpenAI tool_calls. If a `max serve`
upgrade gains a Hermes `--tool-parser`, point the three proxied
harnesses at :8000 and drop the proxy (check with a `tools=` request;
`response_format` alone does not populate `tool_calls`).

Two proxy modes:

- `PROXY_REWRITE=1` (default): `<tool_call>` rewrite for pi/dsh/opencode.
- `PROXY_REWRITE=0`: passthrough that only injects
  `PROXY_TEMPLATE_KWARGS` into each request body. Route every arm
  through a proxy with the same kwargs when the model needs template
  flags (e.g. `'{"enable_thinking": false}'` on Qwen3 thinking models),
  so no arm sees a different template. mojo/maxv2/ref/aider then point
  at the passthrough via `MAX_BASE_URL`.

`dsh` has watchdog-timed out on every observed run (Qwen3-4B and 14B);
its rows burn a full `BENCH_TIMEOUT` each and the failure looks like a
dsh/config issue, not a task outcome. Exclude it unless debugging it.

## Run

    ./bench/setup.sh                            # tool + pinned-version checks
    max serve --model <org/name>                # Modular max CLI, :8000 - not the
                                              # agent binary (see scripts/with-max.sh)
    python3 bench/toolcall_proxy.py             # terminal 2, :8001
    MAX_MODEL=<org/name> python3 bench/run_matrix.py 2            # 2 reps, all harnesses
    MAX_MODEL=<org/name> python3 bench/run_matrix.py 2 mojo,ref   # subset
    python3 bench/analyze.py

Iterate in tiers rather than rerunning the full matrix:

    # smoke, ~5 min: catches dead-on-arrival harness changes
    BENCH_TASKS=empty-input,fix-add,slugify \
      MAX_MODEL=<m> python3 bench/run_matrix.py 1 mojo,maxv2

    # signal, ~30-60 min: tasks where models actually diverge
    BENCH_TASKS=off-by-one,parse-config,multi-file,long-horizon \
      BENCH_MAX_REQ=40 BENCH_TIMEOUT=900 \
      MAX_MODEL=<m> python3 bench/run_matrix.py 1 maxv2,aider,pi

`long-horizon` (six broken helpers across three files, iterate until
`test_kit.py` prints TEST PASSED) is the long-task stress test; it
needs `BENCH_MAX_REQ` raised past the default cap of 15 requests.

`python3 bench/check_tasks.py` oracle-checks every task: each task's
`solution.patch` must fix the pristine repo without touching protected
files (verify passes), and the unpatched repo must fail — proves tasks
are solvable and graders discriminate. Run it after editing a task.

`run_matrix.py` refuses to run when `MAX_MODEL` is unset, when the
endpoints are down, or when the server on :8000 is not serving that
model. Provider configs are rendered into `bench/.generated/`
(gitignored) from the committed templates; nothing tracked is rewritten
per model.

`results.jsonl`, `logs-*/` and `charts/` are ignored; past artifacts
live in github.com/pierrebrunelle/max-results (private). Run
`analyze.py` against `BENCH_RESULTS=<path>` to regenerate `RESULTS.md`.

## Integrity

Each row carries `run_id` (UTC time + git sha, `-dirty` when the tree is
dirty), `ts` and `bench_version`. After each run the task's copied repo
is compared against the pristine `tasks/<name>/repo/` for every file
matching `meta.json`'s `protected` globs (default `["test_*"]` when no
meta.json; a glob matches a file's repo-relative path or its basename,
and `*` can cross `/`). A changed, deleted or added protected file fails
the row with `"tampered": true`. The protected list is appended to the
task prompt, so the constraint is never invisible.

Logs and transcripts land in `logs-<model-slug>/<run_id>/`, so
`analyze.py` attributes infra failures to the right batch. For rows
without `run_id` (pre-`run_id` data) it falls back to the shared
`logs/` dir.

Env knobs: `MAX_MODEL` (required), `MAX_BASE_URL`, `BENCH_TOOLCALL_BASE`,
`BENCH_RESULTS`, `BENCH_LOGS`, `BENCH_TIMEOUT`, `BENCH_TASKS`,
`BENCH_MAX_REQ`, `BENCH_CHARTS`, `BENCH_OUT_MD`. The proxy reads
`PROXY_UPSTREAM`, `PROXY_PORT`, `PROXY_TEMPLATE_KWARGS`, `PROXY_REWRITE`.

`max serve` spends ~2 min compiling the graph on first model load;
`run_matrix.py` refuses to start until every configured endpoint
answers `/v1/models`, so compile time never lands in wall times.
