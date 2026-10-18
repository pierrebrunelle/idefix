#!/bin/bash
cd "$1" && test -f render.py && python3 cli.py 2>/dev/null | grep -q "NAME" && python3 cli.py 2>/dev/null | grep -q "Ada" && python3 cli.py 2>/dev/null | grep -q "55" && python3 cli.py 2>/dev/null | grep -q "|"
