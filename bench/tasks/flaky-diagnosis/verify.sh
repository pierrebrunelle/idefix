#!/bin/bash
cd "$1" && for i in 1 2 3 4 5; do python3 test_report.py >/dev/null 2>&1 || exit 1; done
