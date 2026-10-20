#!/bin/bash
cd "$1" || exit 1
out=$(bash health.sh ok.log 2>/dev/null); rc=$?
[ "$out" = "STATUS ok" ] || exit 1
[ "$rc" -eq 0 ] || exit 1
out=$(bash health.sh bad.log 2>/dev/null); rc=$?
[ "$out" = "STATUS fail (3 errors)" ] || exit 1
[ "$rc" -eq 1 ] || exit 1
# a generated log with a different count defeats hardcoded answers
tmp=$(mktemp -d)
printf 'INFO a\nERROR x\nINFO b\nERROR y\n' > "$tmp/g.log"
out=$(bash health.sh "$tmp/g.log" 2>/dev/null); rc=$?
rm -rf "$tmp"
[ "$out" = "STATUS fail (2 errors)" ] || exit 1
[ "$rc" -eq 1 ] || exit 1
