# idefix architecture

One file of agent logic (`idefix.mojo`, ~1.3k lines), one model-facing tool
(`bash`), one loop. This document is the map: layers, the run state chart,
the tool-call dataflow, and how sessions persist.

## Layers

```text
YOU        "fix the parser bug"     (one-shot | REPL | piped session)
  |
  v
HARNESS    idefix — 300 KB native binary, no runtime deps beyond libcurl
           owns: request building, tool execution, bounds, journal, answers
  |   POST {base}/chat/completions  {messages, tools:[bash]}
  v
SERVER     any OpenAI-compatible endpoint (separate OS process)
           Modular `max serve` - ollama - LM Studio - llama-server - vLLM
           idefix never manages it; scripts/with-max.sh lazily boots one
  |   assistant message with tool_calls[bash(command)]
  v
MODEL      Qwen3-1.7B..14B etc. — the intelligence; harness only feeds it

EXECUTION  inside idefix, per tool call:
           bash -c "cmd" in the repo — scrubbed env, process group,
           timeouts, output caps, changed_files + diff back to the model
```

## Run state chart

```text
                        +-------------------+
                        | INIT              |
                        | args, env, repo,  |-- bad args / no model --> exit 64
                        | journal setup     |
                        +--------+----------+
                                 |
                                 v
        +----------------->  REQUEST
        |                    POST messages[]
        |                         | transport/5xx
        |                         +---> RETRY (xN, backoff) ---- exhausted --> exit 3
        |                         | ctx-length error
        |                         +---> COMPACT once, retry --------------> exit 3
        |                         | 200
        |                         v
        |                      PARSE
        |                     tool_calls[]? (batched, --max-calls-per-response)
        |                         |
        |          +--------------+-------------+
        |          |no tool calls               |yes, k calls
        |          v                            v
        |        DONE                     EXEC (per call, sequential)
        |      print answer             bash -c cmd (see dataflow)
        |      stats line               tool result appended to
        |      exit 0                   history + journal
        |                                   |
        |                                   v
        |                              BOUNDS CHECK
        |                    requests | wall | prompt-tokens | loop-guard
        |                    exceeded -----------------------------> exit 2
        |                                   |
        +-----------------------------------+
```

REPL mode = the same loop per input line, context shared. `/reset` clears
history, `!cmd` runs a shell command locally (0 tokens), `/quit`/`/exit`
leaves. A task timeout is a bound like any other — exit 2.

## Tool-call dataflow

```text
tool_calls[i] {id, bash(command)}
   |
   v
scrub env  --------  drop vars matching KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL
   |
   v
snapshot   --------  md5sum the repo (prune .git/.idefix-state), APFS clonefile
   |
   v
exec       --------  fork /bin/bash -c "cmd", own process group
   |                 killpg on command timeout or wall deadline
   |                 drain output 3s, then killpg strays
   |                 (escape hatch: `setsid` = deliberate detach)
   |
   v
result     --------  stdout+stderr (capped), exit code, truncated-byte counts
   |
   v
diff       --------  md5 diff -> changed_files[] + compact unified diff
   |                 write-shaped cmd + zero changes -> explicit warning
   |
   v
journal    --------  append tool result entry to journal.jsonl + status file
   |
   v
APPEND to history -> next REQUEST
```

The honesty rule: `exit 0` with nothing changed is reported as a warning,
not success — small models otherwise believe failed edits landed.

## Sessions: journal, resume, fork

```text
journal.jsonl   append-only event log (per state dir, per repo)
status          live progress file for watchers/notify

idefix --continue          rebuild history from this repo's journal
idefix --resume FILE       replay FILE as the journal

fork = a file operation, not a feature:
  head -n K journal.jsonl > fork.jsonl && idefix --resume fork.jsonl
```

## vs the other harnesses

```text
opencode ~1.05M LOC - dsh ~569k - codex ~420k+ - pi ~100k
aider ~22k LOC + ~100 deps
idefix ~1.3k LOC -> one 300KB binary

same job, different surface:
  pi/aider = TUI, plugins, providers, MCP, sub-agents
  idefix   = the loop above and nothing else; every bound is a flag,
             every claim is a test (tests/run.sh, tests/mutation.sh)
```

A bare Python loop covers most trivial tasks; idefix is that loop plus the
verified hardening (bounds, honest results, journal, sandbox, cleanup).
Frameworks (LangGraph, NeMo OO-Agents, Mastra) are a different layer:
build-your-own kits — idefix deliberately uses none.
