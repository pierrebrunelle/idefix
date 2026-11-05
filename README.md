<img width="1024" height="338" alt="idefix — a tiny native coding agent for local models: one tool, one loop, 300KB native" src=".github/banner.png" />

# idefix

**A tiny native coding agent for local models.** One ~300 KB Mojo binary,
one model-facing tool (`bash(command)`), one loop — ~1.3k lines you can
read in an hour. Talks to any OpenAI-compatible server: Ollama, LM Studio,
llama.cpp, `max serve`, vLLM.

Capability = model × harness. The harness half should be small enough to
hold in your head.

<img width="1024" alt="idefix architecture at a glance — setup, safety bounds, the request/tool loop, and editor/event integrations" src=".github/architecture.jpg" />

## Get it running

```bash
# 1. install (prebuilt binary, no toolchain needed)
curl -fsSL https://github.com/pierrebrunelle/idefix/releases/latest/download/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"

# 2. a model server — Ollama shown, anything OpenAI-compatible works
brew install ollama && brew services start ollama    # macOS
ollama pull qwen3:8b

# 3. run it in a repo — finds Ollama on :11434 by itself
cd my-project
idefix "the slugify test fails on unicode input - fix it"
```

```text
[idefix] requests=4 commands=3 prompt_tokens=812 tokens=1982+71 elapsed=21s exit=0
Fixed: normalize accents before lowercasing in slugify().
```

```text
idefix "task"        one shot, exits when done
idefix               REPL: /reset  !cmd  /quit
cat todo | idefix    piped lines share one session
idefix --continue    resume this repo's journal
idefix edit FILE     apply SEARCH/REPLACE blocks
```

Other server: `IDEFIX_BASE_URL` + `IDEFIX_MODEL`. Careful with
`Qwen3-4B-Instruct` builds: some templates emit tool calls as plain text
and nothing runs — a protocol failure, not a model failure.

## What makes it different

- **Every bound is a flag.** Requests, wall clock, command time, output
  bytes, HTTP bytes, prompt tokens, retries, and a doom-loop guard that
  stops repeated identical commands. Commands run in their own killed
  process group with credentials scrubbed from env; `--sandbox` confines
  writes to repo + tmp.
- **Tool results don't lie.** The model sees `changed_files`, a compact
  diff, and a warning when a write-shaped command changed nothing.
- **What it lacks is deliberate.** Subagents, long-term memory, fuzzy
  edits, and per-provider plumbing were each measured dead weight or
  designed out — devin/codex-class harnesses run 25k-240k LOC for the
  same convergent core.
- **Measured, not claimed.** Verifier-scored benchmarks (never
  self-reported) in
  [pierrebrunelle/max-results](https://github.com/pierrebrunelle/max-results):
  same-tier pass rates as aider/pi at ~1/15th the footprint. On hard
  tasks every harness fails at 4B — the model is the constraint, and
  idefix is built so you can measure that.

## How it works

```text
            "fix the bug"
                 |
                 v
   +--->  POST /chat/completions
   |      {messages[], tools: [bash(command)]}
   |             |
   |             v
   |        tool_calls? -- no --> print answer -> exit 0
   |             | yes
   |             v
   |      bash -c cmd    in the repo, own process group
   |      creds scrubbed | timeout = killpg
   |      output capped head+tail  |  --spill -> file
   |             |
   |             v
   |      result {exit_code, changed_files, diff}
   |      appended to messages[]
   |             |
   +-------------+    any bound trips -> exit 2
                       requests | wall clock | tokens | same-cmd x3

   every step -> journal.jsonl   (--continue rebuilds context)
```

## Beyond the terminal

- **Editor UI, no UI code:** `acp/idefix-acp.py` (~200-line shim) makes
  idefix an [ACP](https://agentclientprotocol.com) agent inside Zed and
  JetBrains agent panels. Setup: [acp/README.md](acp/README.md).
- **Embed it:** `--events` streams NDJSON events on stdout.
- Design dissections and the full harness comparison live in
  [max-results/bench](https://github.com/pierrebrunelle/max-results/tree/main/bench).

No TUI, no MCP, no cloud providers, no sub-agents — that is pi, aider,
claude-code. Commands run as your user inside `--repo` unless `--sandbox`.
