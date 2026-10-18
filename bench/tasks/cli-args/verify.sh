#!/bin/bash
cd "$1" && [ "$(python3 tool.py --upper hello 2>/dev/null)" = "HELLO" ] && [ "$(python3 tool.py hello 2>/dev/null)" = "hello" ]
