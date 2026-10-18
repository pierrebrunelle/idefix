# Benchmark results

Model: `Qwen/Qwen3-4B-Instruct-2507` on MAX. 24 runs across 6 tasks x 2 clients.

## Pass rate

| task | mojo | ref |
| --- | --- | --- |
| empty-input | 100% | 100% |
| fix-add | 100% | 100% |
| multi-file | 100% | 100% |
| off-by-one | 100% | 100% |
| parse-config | 0% | 0% |
| slugify | 50% | 0% |
| **overall** | **75%** | **67%** |

![pass rate](charts/pass_rate.svg)

## Cost per run (median)

| metric | mojo | ref |
| --- | --- | --- |
| wall_s | 24.5 | 31.5 |
| peak RSS MB | 15.8 | 18.0 |
| prompt tokens | 933.5 | 822 |
| requests | 5.0 | 4 |
| commands | 4.0 | 3 |

![wall](charts/wall_time.svg) ![rss](charts/peak_rss.svg) ![tokens](charts/prompt_tokens.svg)

## Raw runs

| client | task | rep | pass | requests | commands | tokens | wall_s | rss_mb | exit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| mojo | empty-input | 1 | 1 | 3 | 3 | 788 | 22.1 | 15.8 | 0 |
| ref | empty-input | 1 | 1 | 3 | 3 | 822 | 22.4 | 17.8 | 0 |
| mojo | empty-input | 2 | 1 | 3 | 3 | 812 | 22.3 | 15.9 | 0 |
| ref | empty-input | 2 | 1 | 3 | 3 | 828 | 25.2 | 18.2 | 0 |
| mojo | fix-add | 1 | 1 | 6 | 5 | 1052 | 32.4 | 15.8 | 0 |
| ref | fix-add | 1 | 1 | 8 | 7 | 1465 | 51.8 | 17.9 | 0 |
| mojo | fix-add | 2 | 1 | 4 | 5 | 980 | 23.3 | 16.1 | 0 |
| ref | fix-add | 2 | 1 | 4 | 3 | 801 | 26.4 | 18.1 | 0 |
| mojo | multi-file | 1 | 1 | 5 | 4 | 850 | 23.7 | 15.8 | 0 |
| ref | multi-file | 1 | 1 | 4 | 3 | 768 | 20.1 | 17.8 | 0 |
| mojo | multi-file | 2 | 1 | 5 | 4 | 887 | 25.3 | 15.8 | 0 |
| ref | multi-file | 2 | 1 | 6 | 5 | 1115 | 36.6 | 18.3 | 0 |
| mojo | off-by-one | 1 | 1 | 3 | 3 | 720 | 19.5 | 16.0 | 0 |
| ref | off-by-one | 1 | 1 | 4 | 3 | 803 | 21.6 | 18.0 | 0 |
| mojo | off-by-one | 2 | 1 | 3 | 2 | 665 | 21.1 | 15.8 | 0 |
| ref | off-by-one | 2 | 1 | 4 | 3 | 764 | 18.8 | 18.0 | 0 |
| mojo | parse-config | 1 | 0 | 15 | 14 | 5803 | 304.5 | 15.8 | 0 |
| ref | parse-config | 1 | 0 | 12 | 11 | 4674 | 229.0 | 17.7 | 0 |
| mojo | parse-config | 2 | 0 | 15 | 15 | 6446 | 341.3 | 16.2 | 2 |
| ref | parse-config | 2 | 0 | None | None | None | 143.0 | 18.0 | 1 |
| mojo | slugify | 1 | 0 | 5 | 4 | 1102 | 80.8 | 15.8 | 0 |
| ref | slugify | 1 | 0 | None | None | None | 251.5 | 18.0 | 2 |
| mojo | slugify | 2 | 1 | 5 | 4 | 1101 | 69.5 | 15.8 | 0 |
| ref | slugify | 2 | 0 | None | None | None | 290.9 | 17.8 | 2 |
