#!/bin/bash
# Pinned seeds, not repetition: the bug survives ~30% of hash seeds, so
# 16 deterministic seeds are both reproducible and effectively exhaustive.
cd "$1" && for i in $(seq 0 15); do PYTHONHASHSEED=$i python3 test_report.py >/dev/null 2>&1 || exit 1; done
