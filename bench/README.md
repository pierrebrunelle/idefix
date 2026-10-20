# bench

Harness comparison matrix: every task in `tasks/` x every harness x N
reps, rows appended to `results.jsonl`; `analyze.py` renders `RESULTS.md`
and `charts/*.svg`.

Harnesses: `mojo` (max `--bare`), `maxv2` (max with journal, compaction
and retries on), `ref` (`tests/ref_client.py`), `aider`, `pi`, `dsh`,
`opencode`. mojo/maxv2/ref/aider talk to `max serve` on :8000; pi/dsh/
opencode go through `toolcall_proxy.py` on :8001, which rewrites Hermes
`<tool_call>` text into OpenAI tool_calls.

## Run

    ./bench/setup.sh                            # tool + pinned-version checks
    max serve                                   # model endpoint, :8000
    python3 bench/toolcall_proxy.py             # terminal 2, :8001
    MAX_MODEL=<org/name> python3 bench/run_matrix.py 2            # 2 reps, all harnesses
    MAX_MODEL=<org/name> python3 bench/run_matrix.py 2 mojo,ref   # subset
    python3 bench/analyze.py

`run_matrix.py` preflights the endpoints and refuses to run when they are
down. Provider configs are rendered into `bench/.generated/` (gitignored)
from the committed templates; nothing tracked is rewritten per model.

## Integrity

Each row carries `run_id` (UTC time + git sha), `ts` and `bench_version`.
Before a harness runs, every file matching the task's `meta.json`
`protected` globs (default `["test_*"]` when no meta.json) is
sha256-snapshotted; a changed or deleted protected file fails the row
with `"tampered": true`. `analyze.py` only falls back to the shared
`logs/` dir for rows without `run_id`.

Env knobs: `BENCH_RESULTS`, `BENCH_LOGS`, `BENCH_TIMEOUT`, `BENCH_TASKS`,
`MAX_BASE_URL`, `BENCH_TOOLCALL_BASE`.
