# Benchmark results

Local MAX serving (`max serve`, single replica). Harness versions:
pi 1.3.0, deepseek-harness 0.2.0-rc.2, aider 0.86.2. Verified by each
task's independent `verify.sh`; tokens are usage-reported, not scored.
Raw rows, logs and charts: github.com/pierrebrunelle/max-results.

## `Qwen/Qwen3-4B-Instruct-2507`

60 valid runs (60 total): 6 tasks x 2 reps x 5 harnesses.

| harness | pass rate | median wall | peak RSS | median tokens |
| --- | --- | --- | --- | --- |
| aider | 12/12 (100%) | 23.1s | 250.2 MB | 811.0 |
| max --bare | 9/12 (75%) | 24.5s | 15.8 MB | 933.5 |
| python-loop | 8/12 (67%) | 31.5s | 18.0 MB | 822 |
| pi | 7/12 (58%) | 79.8s | 125.9 MB | 2750.0 |
| deepseek-harness | 0/12 (0%) | 420.3s | 191.9 MB | None |

### Pass rate by task

| task | max --bare | python-loop | aider | pi | deepseek-harness |
| --- | --- | --- | --- | --- | --- |
| empty-input | 100% | 100% | 100% | 100% | 0% |
| fix-add | 100% | 100% | 100% | 100% | 0% |
| multi-file | 100% | 100% | 100% | 100% | 0% |
| off-by-one | 100% | 100% | 100% | 50% | 0% |
| parse-config | 0% | 0% | 100% | 0% | 0% |
| slugify | 50% | 0% | 100% | 0% | 0% |

### Known failures

| harness | failure | runs | tasks |
| --- | --- | --- | --- |
| deepseek-harness | timeout | 8 | all six tasks |
| deepseek-harness | verify-fail | 4 | empty-input, fix-add, off-by-one, parse-config |
| pi | timeout | 3 | parse-config, slugify |
| max --bare | verify-fail | 2 | parse-config, slugify |
| pi | verify-fail | 2 | off-by-one, parse-config |
| python-loop | exit-2 | 2 | slugify |
| max --bare | exit-2 | 1 | parse-config |
| python-loop | exit-1 | 1 | parse-config |
| python-loop | verify-fail | 1 | parse-config |

## `Qwen/Qwen3-14B` partial matrix (endpoint outage)

26 valid runs of 84 attempted, before the serving endpoint failed
mid-run: 5 tasks x 2 reps x 3 harnesses produced outcomes; the rest
died on transport errors and are excluded. Treat these numbers as a
truncated sample, not a leaderboard.

| harness | pass rate | median wall | peak RSS |
| --- | --- | --- | --- |
| aider | 4/8 (50%) | 497.8s | 261.0 MB |
| pi | 3/9 (33%) | 900.0s | 126.7 MB |
| max --bare | 1/9 (11%) | 879.2s | 15.8 MB |

| task | max --bare | aider | pi |
| --- | --- | --- | --- |
| chained-bugs | 0% | 100% | 0% |
| cli-args | 0% | 100% | 100% |
| empty-input | 50% | 50% | 50% |
| fix-add | 0% | 0% | 0% |
| flaky-diagnosis | 0% | 0% | 0% |

## `Qwen/Qwen3-14B` long-horizon study

`long-horizon`: six broken helpers across `text.py`, `nums.py`,
`store.py`; the agent iterates `python3 test_kit.py` until it prints
TEST PASSED. `BENCH_MAX_REQ=40`, `BENCH_TIMEOUT=900`, thinking off via
proxy-injected `enable_thinking=false` on every arm.

### Before `changed_files` (max binary at e2a3096)

| arm | pass | wall | requests | commands | peak RSS | ended |
| --- | --- | --- | --- | --- | --- | --- |
| aider | 1 | 75.4s | - | - | 255.2 MB | all six fixed |
| pi | 1 | 335.1s | 12 | - | 114.1 MB | all six fixed |
| dsh | 0 | 901.3s | - | - | 187.9 MB | watchdog; degenerate output |
| max | 0 | 432.1s | 20 | 39 | 16.0 MB | no tool call mid-task |

Failure autopsy on max: every `sed -i` first errored on GNU syntax
(macOS needs `sed -i ''`), then BSD-correct seds returned exit 0 on
non-matching patterns, so nothing changed while the tool reported
success; the run ended on a prose plan with no tool call. aider's
SEARCH/REPLACE format fails loudly on a non-match, which is the
structural difference this task exposes.

### After `changed_files` + product prompt suffix (HEAD)

Regime warning: this run served at ~5 tok/s. The 48 GB host was under
memory pressure (weights + ~6 GB KV cache vs. the rest of the user's
workload), so every arm's wall time is serving-dominated, not
harness-dominated. max numbers still measure behavior correctly;
aider/pi failures here should be read against the healthy-regime run
above, where both passed.

| arm | pass | wall | requests | commands | peak RSS | ended |
| --- | --- | --- | --- | --- | --- | --- |
| max rep1 | 0 | 880.2s | 16 | 49 | 16.1 MB | wall; `http 0` retries |
| max rep2 | 0 | 879.7s | 17 | 36 | 16.1 MB | wall; unexecuted tool_call |
| aider rep1 | 0 | 900.2s | - | - | 231.0 MB | watchdog; `$$` degenerate output |
| aider rep2 | 0 | 900.2s | - | - | 219.9 MB | watchdog; same shape |
| pi rep1 | 0 | 15.1s | 4 | - | 120.0 MB | stream ended w/o finish_reason x3 |
| pi rep2 | 0 | 15.8s | 4 | - | 130.2 MB | same shape |

What the fix bought, measurably: `changed_files` removed the
edit-didn't-land failure. rep1 made 24 real edits to `text.py` (25
commands honestly reported as no-ops); rep2 made 4. The new bottleneck
is semantic - the model rewrote `snake_to_camel` ~24 times with wrong
logic (`capitalize()`, `title()` variants) and never reached bugs 2-6.
aider's healthy-regime pass took ~763 tokens; max burned ~2,900
iterating. Writing correct code through shell edit commands still costs
more model capability than a patch format, at least at 5 tok/s where
every attempt is expensive.

## Methodology notes

- `mojo` is `./max --bare` (v1 wire protocol only); `max` is the
  shipped binary; `ref`/`python-loop` is `tests/ref_client.py`.
- mojo/max/ref/aider talk to `max serve` directly or through a
  passthrough proxy (`PROXY_REWRITE=0`); pi/dsh/opencode need the
  rewriting proxy because this MAX build has no Hermes tool parser.
- deepseek-harness rows: the model reads the ~6k-token Cordis plugin
  system prompt and emits refusal-style text instead of tool calls;
  every observed run across both models died at the watchdog. A 0%
  here is a model x harness interaction, not a dsh verdict.
- Timeout rows count in medians; `requests=None` means the run was
  killed before its first LLM call returned. Rows marked `infra` in
  the raw data died on endpoint/transport errors and are excluded.
