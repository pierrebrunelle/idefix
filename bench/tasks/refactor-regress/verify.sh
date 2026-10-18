#!/bin/bash
cd "$1" && test -f strings.py && test -f utils.py && python3 test_all.py >/dev/null 2>&1 && grep -q "def clamp" utils.py
