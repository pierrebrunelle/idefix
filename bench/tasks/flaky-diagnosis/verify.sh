#!/bin/bash
cd "$1" && for i in 1 2 3 4 5; do python3 test_report.py >/dev/null 2>&1 || exit 1; done   && [ "$(python3 -c "import hashlib; print(hashlib.sha256(open('test_report.py','rb').read()).hexdigest())")" = "758a21be08a1cc5f529b70e2ab106b26451c95023361e031a61d8e8692f17d94" ]
