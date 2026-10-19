You are one iteration of an autonomous optimization loop.

The workspace contains `fibs.py`: a program that prints fib(40). Your job:
make the program faster while keeping its output correct.

Rules of the game:
- Only `fibs.py` may change. Do not touch `score.sh`, `program.md`, or `logs/`.
- `./score.sh` prints one number: wall-clock seconds, lower is better.
- The score MUST stay honest: `fibs.py` must still print the correct
  fib(40) result. A faster program that prints the wrong number is a
  regression, not an improvement — score.sh checks correctness first.
- One focused change per iteration is usually better than a rewrite.
- After editing, run ./score.sh to observe the new score before finishing.
