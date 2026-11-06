# py_check: --py-check flag runs py_compile on changed .py files
rm -f /tmp/idefix_pyc.json
out=$(run_mode pycheck ./idefix --repo . --py-check --transcript /tmp/idefix_pyc.json "task" 2>/dev/null); rc=$?
check "pycheck exit" 0 "$rc"
python3 -c "import json;d=json.load(open('/tmp/idefix_pyc.json'));t=[m for m in d if m['role']=='tool'];assert 'py_diagnostics' in t[0]['content'],t[0]" && echo "PASS pycheck diagnostics" || { echo "FAIL pycheck diagnostics"; FAIL=1; }
rm -f test_syntax.py
