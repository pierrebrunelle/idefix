# Benchmark results

Local MAX serving (`max serve`, single replica). Harness versions:
pi 1.3.0, deepseek-harness 0.2.0-rc.2, aider 0.86.2. Verified by each
task's independent `verify.sh`; tokens are usage-reported, not scored.

## `Qwen/Qwen3-4B-Instruct-2507`

60 runs: 6 tasks x 2 reps x 5 harnesses.

## Leaderboard

| harness | pass rate | median wall | peak RSS | median tokens |
| --- | --- | --- | --- | --- |
| aider | 12/12 (100%) | 23.1s | 250.2 MB | 811.0 |
| mojo-max-agent | 9/12 (75%) | 24.5s | 15.8 MB | 933.5 |
| python-loop | 8/12 (67%) | 31.5s | 18.0 MB | 822 |
| pi | 7/12 (58%) | 79.8s | 125.9 MB | 2750.0 |
| deepseek-harness | 0/12 (0%) | 420.3s | 191.9 MB | None |

![leaderboard](charts/qwen3-4b-instruct-2507/leaderboard.svg)

![time](charts/qwen3-4b-instruct-2507/median_time.svg) ![strip](charts/qwen3-4b-instruct-2507/wall_strip.svg)

![pareto](charts/qwen3-4b-instruct-2507/pareto.svg) ![tokens](charts/qwen3-4b-instruct-2507/tokens_per_success.svg)

### Methodology notes

- mojo-max-agent and python-loop talk to MAX on :8000 with a text-command
  protocol; aider uses its edit-format prompts on :8000. pi and
  deepseek-harness use native OpenAI tool calling, which this MAX serve
  build cannot parse (no hermes tool parser), so they run through
  bench/toolcall_proxy.py on :8001, which rewrites <tool_call> text into
  structured tool_calls. Wall times include the proxy hop.
- deepseek-harness rows: the model reads the ~6k-token Cordis plugin system
  prompt and may generate refusal-style text instead of tool calls; such
  runs die at the 420s watchdog inside a single completion. A 0% here is a
  model x harness interaction, not a verdict on dsh on bigger models.
- Timeout rows count in medians; 'requests=None' means the run was killed
  before its first LLM call returned.

### Pass rate by task

| task | mojo-max-agent | python-loop | aider | pi | deepseek-harness |
| --- | --- | --- | --- | --- | --- |
| empty-input | 100% | 100% | 100% | 100% | 0% |
| fix-add | 100% | 100% | 100% | 100% | 0% |
| multi-file | 100% | 100% | 100% | 100% | 0% |
| off-by-one | 100% | 100% | 100% | 50% | 0% |
| parse-config | 0% | 0% | 100% | 0% | 0% |
| slugify | 50% | 0% | 100% | 0% | 0% |

![pass rate](charts/qwen3-4b-instruct-2507/pass_rate.svg) ![rss](charts/qwen3-4b-instruct-2507/peak_rss.svg)

### Raw runs

| harness | task | rep | pass | requests | commands | tokens | wall_s | rss_mb | exit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| mojo-max-agent | empty-input | 1 | 1 | 3 | 3 | 788 | 22.1 | 15.8 | 0 |
| python-loop | empty-input | 1 | 1 | 3 | 3 | 822 | 22.4 | 17.8 | 0 |
| mojo-max-agent | empty-input | 2 | 1 | 3 | 3 | 812 | 22.3 | 15.9 | 0 |
| python-loop | empty-input | 2 | 1 | 3 | 3 | 828 | 25.2 | 18.2 | 0 |
| mojo-max-agent | fix-add | 1 | 1 | 6 | 5 | 1052 | 32.4 | 15.8 | 0 |
| python-loop | fix-add | 1 | 1 | 8 | 7 | 1465 | 51.8 | 17.9 | 0 |
| mojo-max-agent | fix-add | 2 | 1 | 4 | 5 | 980 | 23.3 | 16.1 | 0 |
| python-loop | fix-add | 2 | 1 | 4 | 3 | 801 | 26.4 | 18.1 | 0 |
| mojo-max-agent | multi-file | 1 | 1 | 5 | 4 | 850 | 23.7 | 15.8 | 0 |
| python-loop | multi-file | 1 | 1 | 4 | 3 | 768 | 20.1 | 17.8 | 0 |
| mojo-max-agent | multi-file | 2 | 1 | 5 | 4 | 887 | 25.3 | 15.8 | 0 |
| python-loop | multi-file | 2 | 1 | 6 | 5 | 1115 | 36.6 | 18.3 | 0 |
| mojo-max-agent | off-by-one | 1 | 1 | 3 | 3 | 720 | 19.5 | 16.0 | 0 |
| python-loop | off-by-one | 1 | 1 | 4 | 3 | 803 | 21.6 | 18.0 | 0 |
| mojo-max-agent | off-by-one | 2 | 1 | 3 | 2 | 665 | 21.1 | 15.8 | 0 |
| python-loop | off-by-one | 2 | 1 | 4 | 3 | 764 | 18.8 | 18.0 | 0 |
| mojo-max-agent | parse-config | 1 | 0 | 15 | 14 | 5803 | 304.5 | 15.8 | 0 |
| python-loop | parse-config | 1 | 0 | 12 | 11 | 4674 | 229.0 | 17.7 | 0 |
| mojo-max-agent | parse-config | 2 | 0 | 15 | 15 | 6446 | 341.3 | 16.2 | 2 |
| python-loop | parse-config | 2 | 0 | None | None | None | 143.0 | 18.0 | 1 |
| mojo-max-agent | slugify | 1 | 0 | 5 | 4 | 1102 | 80.8 | 15.8 | 0 |
| python-loop | slugify | 1 | 0 | None | None | None | 251.5 | 18.0 | 2 |
| mojo-max-agent | slugify | 2 | 1 | 5 | 4 | 1101 | 69.5 | 15.8 | 0 |
| python-loop | slugify | 2 | 0 | None | None | None | 290.9 | 17.8 | 2 |
| aider | empty-input | 1 | 1 | 1 | None | 794 | 15.8 | 238.2 | 0 |
| aider | empty-input | 2 | 1 | 1 | None | 794 | 13.5 | 259.6 | 0 |
| aider | fix-add | 1 | 1 | 1 | None | 777 | 15.6 | 245.5 | 0 |
| aider | fix-add | 2 | 1 | 1 | None | 777 | 13.5 | 249.4 | 0 |
| aider | multi-file | 1 | 1 | 1 | None | 849 | 26.4 | 251.0 | 0 |
| aider | multi-file | 2 | 1 | 1 | None | 849 | 24.9 | 252.1 | 0 |
| aider | off-by-one | 1 | 1 | 1 | None | 807 | 21.4 | 248.8 | 0 |
| aider | off-by-one | 2 | 1 | 1 | None | 807 | 19.9 | 257.5 | 0 |
| aider | parse-config | 1 | 1 | 1 | None | 892 | 46.3 | 260.2 | 0 |
| aider | parse-config | 2 | 1 | 1 | None | 892 | 47.0 | 243.9 | 0 |
| aider | slugify | 1 | 1 | 1 | None | 815 | 57.4 | 253.4 | 0 |
| aider | slugify | 2 | 1 | 1 | None | 815 | 54.3 | 244.0 | 0 |
| pi | empty-input | 1 | 1 | 5 | 2 | 2769 | 46.8 | 127.3 | 0 |
| deepseek-harness | empty-input | 1 | 0 | None | None | None | 420.5 | 193.8 | 0 |
| pi | empty-input | 2 | 1 | 5 | 2 | 2770 | 54.8 | 128.8 | 0 |
| deepseek-harness | empty-input | 2 | 0 | 1 | None | None | 326.1 | 191.5 | 0 |
| pi | fix-add | 1 | 1 | 4 | 1 | 2568 | 48.4 | 125.8 | 0 |
| deepseek-harness | fix-add | 1 | 0 | None | None | None | 420.3 | 185.0 | 0 |
| pi | fix-add | 2 | 1 | 4 | 1 | 2566 | 54.7 | 126.3 | 0 |
| deepseek-harness | fix-add | 2 | 0 | 1 | None | None | 305.3 | 192.0 | 0 |
| pi | multi-file | 1 | 1 | 5 | 2 | 2731 | 80.7 | 127.2 | 0 |
| deepseek-harness | multi-file | 1 | 0 | None | None | None | 420.3 | 191.9 | 0 |
| pi | multi-file | 2 | 1 | 8 | 5 | 2874 | 165.4 | 115.4 | 0 |
| deepseek-harness | multi-file | 2 | 0 | None | None | None | 420.5 | 187.9 | 0 |
| pi | off-by-one | 1 | 1 | 4 | 1 | 2585 | 78.8 | 127.0 | 0 |
| deepseek-harness | off-by-one | 1 | 0 | None | None | None | 420.5 | 191.8 | 0 |
| pi | off-by-one | 2 | 0 | 2 | 1 | 2455 | 58.5 | 114.5 | 0 |
| deepseek-harness | off-by-one | 2 | 0 | 1 | None | None | 347.5 | 186.6 | 0 |
| pi | parse-config | 1 | 0 | 4 | 2 | 2970 | 420.4 | 126.0 | 143 |
| deepseek-harness | parse-config | 1 | 0 | 1 | None | None | 376.1 | 192.9 | 0 |
| pi | parse-config | 2 | 0 | 4 | 1 | 2901 | 209.5 | 109.9 | 0 |
| deepseek-harness | parse-config | 2 | 0 | None | None | None | 420.5 | 191.6 | 0 |
| pi | slugify | 1 | 0 | 1 | None | None | 420.1 | 124.6 | 143 |
| deepseek-harness | slugify | 1 | 0 | None | None | None | 420.3 | 192.8 | 0 |
| pi | slugify | 2 | 0 | 1 | None | None | 420.2 | 113.6 | 143 |
| deepseek-harness | slugify | 2 | 0 | None | None | None | 420.4 | 194.2 | 0 |

