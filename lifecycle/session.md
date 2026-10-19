# Session — agent REPL

## Who, and the job

Pierre (see `lifecycle/job.md`): has the built binary, wants a task + a
follow-up in context, no shell plumbing. Done = printed answers, trusted exit.

## What I checked

- Watched run (real TTY, `tests/stub_server.py` normal mode): banner, `mojo> `
  prompt, two turns, `/reset`, Ctrl-D, stats line.
- Watched run (piped stdin): two tasks → `Done.` twice, exit 0.
- Watched run (dead server, port 18923 free): `CURL_ERROR:7`, exit 3.
- Read source: `agent.mojo` `run_turn()`/`finish()`/REPL loop,
  `bindings.mojo` `read_line()`/`is_tty()`/`prompt()`, `agent_shim.c`
  `shim_read_line()`, `tests/run.sh`, `tests/stub_server.py`.
- `./agent --help` and the no-`MAX_MODEL` die path (rc 64, real code checked
  unpiped).

## Pierre tries to get a task done, then a follow-up, without writing bash

1. `./agent --help` prints usage; the first line reads
   `usage: agent --repo DIR [flags] [TASK]   (no TASK -> interactive REPL on
   stdin)` and a `REPL:` line names `/reset` and `/quit`. He can tell the
   no-argument form exists and what it does.
2. With `MAX_MODEL` unset, `./agent` prints `[agent] MAX_MODEL is not set.`
   plus the same usage, exits 64. The missing piece is named.
3. With the endpoint set, `./agent` on a TTY prints
   `[agent] interactive mode — /reset clears context, /quit or Ctrl-D exits`
   then `mojo> `. The commands he will need are announced before he needs
   them.
4. `mojo> fix the parser` → the stub turn runs → `Done.` → `mojo> ` returns.
   First success.
5. `mojo> and the tests?` → `Done.` — the second turn answered using turn 1's
   context (stub pairing confirmed; transcript shows the accumulated history).
6. Trouble, dead server: he types `task with dead server`. The product printed
   `[agent] http 0: CURL_ERROR:7` and `[agent] turn ended with exit 3` — and,
   before this session's fix, also printed `(no final answer)` on stdout: a
   fake answer for a transport that never reached the model. Fixed during this
   review; now stdout stays silent on failed turns, stderr carries the reason,
   and the session survives for the next line.
7. Trouble, pasting a stack trace: every newline is a task. A four-line paste
   becomes four turns. There is no continuation or paste affordance. Open.
8. `mojo> /reset` → `[agent] context reset`; next line starts from the system
   prompt only (transcript verified).
9. Ctrl-D → `[agent] requests=3 commands=1 prompt_tokens=20 exit=0`. He knows
   the session ended and what it cost. `/quit` exits the same way.

## Where the job broke

| # | Moment | What he needed | What the product did | Change | Size |
|---|--------|----------------|----------------------|--------|------|
| 6 | dead server | silence on stdout, reason on stderr | printed `(no final answer)` as if the model had answered | `agent.mojo`: placeholder only when `code == 0`; applied and retested — 19/19 tests pass, dead-server turn now prints nothing to stdout | Small — applied |
| 7 | multi-line paste | a way to give one task spanning lines | each line became its own turn | none exists; documenting the limit in README is the smallest honest fix | Flow — open |
| 9 | mid-session | cost so far | stats print only at exit | acceptable; `--transcript` snapshots at exit only | Small — open |

Troubles attempted and produced: dead server, missing `MAX_MODEL`, EOF,
`/reset`, unknown slash-words (sent to the model as text — by design).
Could not produce: `/quit` mid-turn (input is line-based; a running turn
finishes first), Ctrl-C mid-turn (SIGINT is forwarded to the child process
group by the shim, then the agent exits — tested at source level only).

## Problems this creates after success

- Per-turn spend is invisible until exit. Open; stats-at-exit is the product's
  only ledger.
- Failed turns leave their user line in history, so the next turn stacks user
  messages (`system, user, user` observed in the dead-server transcript).
  Honest — the questions were asked — but the model may answer a dead task
  late. Open.
- Piped stdin mode doubles as a task queue (`printf 'a\nb\n' | ./agent`),
  which also means paste and queue share one mechanism. Serendipitous, and the
  same reason step 7's paste problem exists.

## Read-back

Every quote above was produced live in this session except where named as
source-read. The `(no final answer)` fix is applied, built, and covered by
`tests/run.sh` (19/19 green).
