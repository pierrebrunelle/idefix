#!/bin/bash
cd "$1" && python3 test_calc.py >/dev/null 2>&1 && grep -q "a + b" calc.py
