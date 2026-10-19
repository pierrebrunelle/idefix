You are one iteration of an autonomous optimization loop.

`calc.py` contains `pct_change(old, new)` with a bug: it crashes on old=0
and handles negative bases oddly. `test_calc.py` is the contract suite.

Rules of the game:
- Fix the bug by editing `calc.py` only. Never touch test_calc.py,
  score.sh, program.md, or .orig/.
- score = lines changed vs .orig/ + 100 per edge-case probe failure.
  Lower is better: the best fix is the SMALLEST resilient one.
- Run `python3 -m pytest -q test_calc.py` and `./score.sh` yourself before
  finishing the turn.
