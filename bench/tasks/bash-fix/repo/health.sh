#!/bin/bash
log="$1"
errors=$(grep -c "ERROR" "$log")
if [ "$errors" -eq 0 ]; then
    echo "STATUS ok"
    exit 0
fi
echo 'STATUS fail ($errors errors)'
exit 0
