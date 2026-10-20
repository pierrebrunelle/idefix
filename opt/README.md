# opt — max as an optimization engine

karpathy/autoresearch pattern, generalized: **mutate artifact → score →
keep or discard → repeat**. The artifact can be code, a config, a strategy,
a prompt — anything `score.sh` can grade. autoresearch is harness-agnostic
("spin up Claude/Codex or whatever"); max is the smallest possible engine
for that loop: a 4MB binary, ~16MB RSS, zero deps, one OpenAI-compatible
endpoint. The loop machinery itself is bash + git — no Python in the driver
path (score.sh invokes whatever the artifact needs).

## Gates + scalar, not just scalar

Real optimization targets carry constraints ("faster without changing
functionality", "fix the bug with the fewest lines"). score.sh composes
them: **hard constraints are gates** (violated → print 9999, the worst
possible score), **the objective is the scalar**. Multi-objective folds in
as weighted sum or edge-probe penalty.

| task | gate | scalar |
| --- | --- | --- |
| Jira bug, least-LOC resilient fix | test suite passes | diff lines + 100·edge-probe failures |
| script faster, same output | output == golden reference | wall seconds |
| improve a prediction | — | error on held-out set |

## A workspace is a git repo with three things

| file | role | who edits it |
| --- | --- | --- |
| `program.md` | the game: rules, editable files, metric | **human** (the "research org code") |
| artifact(s) | the thing being optimized (e.g. `fibs.py`) | **max** |
| `score.sh` | prints ONE float (exit-checked, oracle-verified) | nobody mid-run |

Direction defaults to min (`OPT_DIRECTION=max` to flip). Everything else in
the workspace is fair game for mutation — keep the mutable surface small
(autoresearch's single-file rule keeps diffs reviewable).

## Run it

```bash
# run from the repo root; loop.sh resolves ./max relative to itself
cp -r opt/examples/fib-speed /tmp/ws1       # workspaces are scratch copies
MAX_BASE_URL=http://127.0.0.1:8002/v1 MAX_MODEL=Qwen/Qwen3-4B-Instruct-2507 \
  OPT_N=100 OPT_SECONDS=300 ./opt/loop.sh /tmp/ws1
```

Each iteration logs to `experiments.tsv` (`iter, score, best, KEEP|DROP`)
and `logs/iter-N.log` (max's `-v` transcript). Git history per workspace IS
the experiment journal: `git log` shows every kept improvement.

Env knobs: `MAX_AGENT` (binary path), `OPT_N`, `OPT_DIRECTION`,
`OPT_MAX_REQ`, `OPT_SECONDS`, plus max's own `MAX_BASE_URL`/`MAX_MODEL`.

## Examples

`opt/examples/fib-speed/` — naive `fib(40)` in pure Python, score = wall
seconds guarded by a correctness oracle. Baseline ~14s; a memoized version
scores ~0.03s. Wrong answers score 9999.

`opt/examples/bugfix-lean/` — `pct_change` crashes on `old=0`. score =
diff-lines vs `.orig/` + 100 per adversarial edge-case failure, gated by
the test suite. Calibrated: buggy=9999, sloppy-fix=7, lean-fix=5 — the
gradient actually distinguishes fix quality.

## Why this shape

- **Fixed scope** (few files) → comparable, reviewable iterations.
- **Fixed metric** (score.sh) → the loop never needs judgment calls.
- **Git keep/discard** → reproducible lineage, free checkpointing.
- **Model is a component**: run 4B for iteration throughput, escalate to
  bigger models only where the small one stalls — the bench in `bench/` is
  the evidence for which harness/model pair burns the least per improvement.
