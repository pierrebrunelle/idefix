# Job

- Person: a developer who just built `agent` and has a local OpenAI-compatible
  endpoint (or the stub) — no shell plumbing wanted, just talk to it.
- Situation: has the binary, `MAX_MODEL` may or may not be set, wants to drive a
  coding task conversationally.
- Arrival kind: finish a job.
- Job: give the agent a task, get an answer, then a follow-up that uses the
  first answer's context — without retyping or writing bash.
- Done: they see the agent's printed answer, ask a follow-up that resolves
  correctly, and leave with an exit code they can trust.
- Leave: answer printed, or Ctrl-D. They know the session ended.
- Path: `./agent --help` → `./agent` (REPL banner on TTY, or piped stdin) →
  `mojo> ` prompt → task line → tool calls on stderr → answer on stdout →
  `/reset`, `/quit`, or EOF.
- Stages this product does not have: account/setup screen, progress display,
  history browsing, undo.
- Source: watched against `tests/stub_server.py` (normal/malformed modes) and
  source (`agent.mojo`, `bindings.mojo`, `tests/run.sh`).
