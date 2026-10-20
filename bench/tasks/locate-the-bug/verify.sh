#!/bin/bash
cd "$1" || exit 1
out=$(python3 main.py 2>/dev/null) || exit 1
echo "$out" | grep -qx "ITEMS 5" || exit 1
echo "$out" | grep -qx "QTY 20" || exit 1
echo "$out" | grep -qx "TOTAL 111.00" || exit 1
# a second dataset defeats answers hardcoded to the shipped fixture
tmp=$(mktemp -d)
printf 'sku,qty,unit_price\nX,2,3.00\nY,1,4.50\nZ,5,1.00\n' > "$tmp/extra.csv"
out2=$(python3 main.py "$tmp/extra.csv" 2>/dev/null) || exit 1
rm -rf "$tmp"
echo "$out2" | grep -qx "ITEMS 3" || exit 1
echo "$out2" | grep -qx "QTY 8" || exit 1
echo "$out2" | grep -qx "TOTAL 15.50" || exit 1
