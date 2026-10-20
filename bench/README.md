# bench

Harness comparison matrix: every task in `tasks/` x every harness x N
reps, rows appended to `results.jsonl`; `analyze.py` renders `RESULTS.md`
and `charts/<model-slug>/*.svg`.

Harnesses: `mojo` (max `--bare`), `maxv2` (max with journal, compaction
and retries on), `ref` (`tests/ref_client.py`), `aider`, `pi`, `dsh`,
`opencode`. mojo/maxv2/ref/aider talk to `max serve` on :8000; pi/dsh/
opencode go through `toolcall_proxy.py` on :8001, which rewrites Hermes
`<tool_call>` text into OpenAI tool_calls. If a `max serve` upgrade gains
a Hermes `--tool-parser`, point the three proxied harnesses at :8000 and
drop the proxy (check with a `tools=` request; `response_format` alone
does not populate `tool_calls`).

## Run

    ./bench/setup.sh                            # tool + pinned-version checks
    max serve --model <org/name>                # Modular max CLI, :8000 - not the
                                              # agent binary (see scripts/with-max.sh)
    python3 bench/toolcall_proxy.py             # terminal 2, :8001
    MAX_MODEL=<org/name> python3 bench/run_matrix.py 2            # 2 reps, all harnesses
    MAX_MODEL=<org/name> python3 bench/run_matrix.py 2 mojo,ref   # subset
    python3 bench/analyze.py

`python3 bench/check_tasks.py` oracle-checks every task: each task's
`solution.patch` must fix the pristine repo without touching protected
files (verify passes), and the unpatched repo must fail — proves tasks
are solvable and graders discriminate. Run it after editing a task.

`run_matrix.py` refuses to run when `MAX_MODEL` is unset, when the
endpoints are down, or when the server on :8000 is not serving that
model. Provider configs are rendered into `bench/.generated/`
(gitignored) from the committed templates; nothing tracked is rewritten
per model.

`results.jsonl` and the log/chart dirs are tracked artifacts: a repro
run modifies them in place. Point `BENCH_RESULTS` and `BENCH_LOGS` at
scratch paths to keep the tree clean.

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
`BENCH_CHARTS`, `BENCH_OUT_MD`. The proxy reads `PROXY_UPSTREAM`,
`PROXY_PORT`, `PROXY_TEMPLATE_KWARGS`, `PROXY_REWRITE`.
