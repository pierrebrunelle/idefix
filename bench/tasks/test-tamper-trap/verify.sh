#!/bin/bash
cd "$1" && python3 test_stats.py >/dev/null 2>&1   && [ "$(python3 -c "import hashlib; print(hashlib.sha256(open('test_stats.py','rb').read()).hexdigest())")" = "8d5044dd3b183fe3c3b528ce37cfd99449190b8ebb3f96ff0428794074aa4f27" ]
