_Lives at pierrebrunelle/idefix. `bench/` paths below refer to the sibling repo [pierrebrunelle/max-results](https://github.com/pierrebrunelle/max-results) (bench machinery, cards, scored rows stay there)._

# MEGAPLAN — what idefix keeps, steals, and refuses

Synthesis of the harness dissection series: each coding agent answers the
same six questions about a production harness (ideally itself), and the
answers are merged into one mechanism matrix. Source-level inventory lives
in `DISSECT.md`; this file is the decision layer. `COMPARE.md` is the
living scoreboard — the do/don't table kept current as cards resolve.
Bench evidence for each adopted mechanism lands as an `H-NNN` card, not
as prose.

Status: 3 answers in (Devin, Codex, Claude-over-4-checkouts). Slots open:
pi, opencode, goose, aider, deepagents self-dissections + the idefix
control run on Nemotron.

---

## 0. The question every harness answered

1. **Keep set** — which mechanisms are load-bearing, with file:line.
2. **The one** — if you keep a single mechanism, which.
3. **Delusion audit** — which mechanism is suspected placebo; the
   ablation that would prove it.
4. **Model vs harness** — which mechanisms only compensate for a weak
   model and evaporate with a perfect one.
5. **Inversion** — what the harness deliberately withholds; measured or
   dogma.
6. **Output contract** — mechanism | file | ~LOC | survives 90% cut? |
   model-weakness? | evidence.

## 1. Answers so far

### Devin (self-dissection, panic-bounds honesty)

- Keep: control loop, persistent shell session, exact-match edit tool,
  context compactor, bounded observation, file journal/undo.
- The one: **exact-match editing** — converts silent shell-edit
  corruption into a retryable, self-describing failure. idefix already
  has it (`idefix edit` unique-match + near-line anchors).
- Highest-value port: the compactor's summary shape — preserving task
  state, edited files, pending todos. → became **H-023**.
- Placebo suspects: malformed-arg repair, subagents, MCP, smart
  permissions, prompt-driven safeguards.
- Deliberately absent: semantic indexing, enforced test verification.
  Classified dogma, not measured.

### Codex (openai/codex @2816088, Rust)

- Keep: action/result loop (~4.2k), bounded subprocess (~1.3k), context
  budgeting (~1.5k), repo instructions (~560), one native sandbox
  (~2.3k), bounded retries (~210).
- The one: **the action/result loop** — record what happened, feed it
  into the next request.
- Placebo suspect: automatic long-term memory (~9.2k LOC incl. tests).
  Proposed ablation: paired tasks on revisited repos, memory on/off,
  equal spend including memory generation, blind scoring.
- Load-bearing detail we verified in our source: **drain-after-cap** —
  stop retaining bytes, keep reading the pipe (`exec.rs:1194-1241`).
  idefix already does this (`bindings.mojo` discarded counter).
- Inversion: no acceptance gate — loop can finish without a test-pass
  artifact. Unmeasured.
- Zero of six kept mechanisms evaporate with a perfect model.

### Claude (opencode + aider + Codex + Goose checkouts; spot-checked 12 citations, 2 wrong)

- Cross-harness keep set (~800 LOC of real logic): tool loop;
  answer-every-tool-call; output cap **with spill to file**; shell
  timeout + process-group kill; compaction as backstop; max-turns cap;
  repo-instructions file.
- The one: **the tool-result path** — one answer per call plus capped
  output spilling to a greppable file. → spill became **H-024**.
- Placebo suspects: shell-permission parser (opencode `scan.ts`+`parse.ts`
  = 3,174 LOC for safety UX); aider's edit-format zoo (3.3k LOC, one
  format covers ~97% of configured models); provider breadth.
- Finding of the series: **aider's fuzzy matcher is dead code** — bare
  `return` at `editblock_coder.py:183` precedes the call users credit
  for robust edits. Flagship-feature placebo, confirmed at source.
- Aider as cautionary tale: 5.6k LOC exists mostly because its model
  has no tools (867-LOC repo map compensates). Our single bash tool
  gives reads/greps/tests for free.
- Constants audit: 2000 lines, 50KB, 10s, 10,000B have no rationale in
  comments anywhere. All dogma until measured.

### dsh / DeepSeek Harness (bundle-level dissection, 2026-11-04)

Not a public source repo — dissected the installed npm package
(`/opt/homebrew/lib/node_modules/@deepseek-ai/dsh`, 505MB, ~7,340 JS
files, ~240 plugin packages). Architecture: **cordis micro-kernel** —
the agent is an ordered stack of patch-layer plugin bundles; the
headless profile mounts 93 bundles (`dsh-base` + `dsh-headless`).

- **Keep set (mounted bundles + size):** `dsh-agent-loop` (184KB,
  `agent/inbox` state machine), `dsh-compaction-basic` (140KB;
  `<compacted-summary>` marker, `compactionRetries`/`headroomTokens`),
  `dsh-spill-local`+`dsh-spill-policy` (152KB — **native output spill**),
  `dsh-tool-bash` (92KB; background jobs `job_output`/`job_kill` —
  bounded async exec we lack), `dsh-tool-str-replace-editor` (52KB —
  exact-match edit), **`dsh-repeat-tool-reminder`** (112KB, thresholds
  config — the only other harness with native doom-loop detection),
  `dsh-llm-retry` (100KB), `dsh-tool-call-timeout-policy`,
  `dsh-fs-observation-policy`, `dsh-bash-sandbox`+`sandbox-policy`,
  `dsh-session-*` persistence chain (~15 pkgs, journal v4 jsonl+zstd).
- **Delusion suspects:** `dsh-subagent` (684KB — largest mounted
  bundle), jobs/workflow-ptc, otel telemetry ×2, web-search, skill/goal/
  plan-mode/todo plugins — mostly untouched by a headless bench run.
  Plus ~70 `dsh-client-ui-*` packages that don't mount at all.
- **Convergence confirmations:** FOURTH harness with spill-to-file
  (strengthens H-024's premise), FIRST other harness with doom
  detection (validates loop-guard as load-bearing, not an idefix
  quirk), str-replace exact-match edit contract again.
- **Dissectability:** per-package `lib/index.js` with readable
  config/error strings — inventory reliable at package granularity;
  line-level claims would be weaker.
- Scale: ~3-4MB of JS mounts per headless run vs idefix's single
  ~1.4k-LOC binary; 505MB installed.

## 2. The mechanism matrix

| mechanism | claimed by | idefix has it | verdict |
|---|---|---|---|
| action/result loop | all three | yes (core) | load-bearing, unmeasured and obvious |
| bounded subprocess: timeout, pgkill, drain-after-cap | Codex, Claude | yes `bindings.mojo` | load-bearing; drain verified at source |
| bounded observation (output cap, head+tail) | all three | yes | load-bearing |
| **output spill to file** | Claude (goose/opencode pattern) | **added `--spill`** | **H-024 testing** |
| tool-call pairing preserved under truncation | Claude | yes (compact_history keeps pairs) | load-bearing |
| compaction (context backstop) | all three | yes | load-bearing; stub fidelity is the open question |
| **rich compaction stubs (task/file state survives clearing)** | Devin | **added `--compact-rich`** | **H-023 testing** |
| repo instructions file | Codex, Claude | yes, **now 8KB-capped** (was unbounded: bounds hole) | load-bearing + fixed |
| finite transport retries | Codex | yes | load-bearing |
| max-turns / loop guard | Claude | yes (+ doom-nudge, doom-escalate) | H-019/H-022 testing |
| exact-match edit + miss hint | Devin #1, Claude runner-up | yes `idefix edit` | load-bearing |
| OS sandbox | Codex runner-up | yes `--sandbox` (seatbelt) | safety bound, not a pass-rate lever |
| journal / undo | Devin | yes | ours |
| malformed-arg repair | named placebo by all three | `--args-repair` arm exists | **falsified by corpus: arg_failed=0.00** — pending kill |
| fuzzy/lenient edit matching | Claude: comp | no | rejected; aider's version is literally dead code |
| subagents | Devin: placebo suspect | no | do not port |
| long-term memory | Codex: placebo suspect (~9.2k LOC) | no | do not port |
| repo map / semantic index | aider necessity (no tools) | no | unnecessary: bash gives it free |
| multi-provider plumbing | Claude: plumbing not quality | no | out of scope by design |
| per-model prompts | Claude: comp | no | model-compensation |
| shell-permission parser | Claude: 3.2k LOC safety UX | no | bounds are ours, not a parser's |

## 3. Model vs harness split

Convergent claim across all three answers, and it matches the corpus:
with a perfectly-formed-call model, ~300–1,000 LOC per harness evaporates
(tool-name repair, arg coercion, fuzzy tiers, toolshim text parsing,
empty-response retries, per-model prompts). Everything else is
infrastructure: finite context, pipe backpressure, hung processes,
network failure, repo-specific knowledge, execution authority.

Corpus check: `arg_failed` = 0.00 across scored rows — the repair path is
armed and has never fired. `--args-repair` (H-020) is testing a mechanism
for a failure mode our models don't produce. If it stays at zero, the
card dies on evidence, exactly as designed.

## 4. The 90% deletion

If each harness lost 90% of its code, the survivors across the series
collapse to ~800 lines: the loop, paired tool results, a bounded
subprocess, capped-and-spilled output, a compactor, an instructions file,
a retry branch, a turn cap. idefix at ~1.4k LOC is already near that
floor — the deletion analysis says the architecture is the answer, and
the remaining work is fidelity of the few mechanisms inside it
(H-023/H-024) rather than new mechanism acquisition.

## 5. idefix coverage ledger

Closed by this round:
- AGENTS.md/CLAUDE.md injection had no size bound → 8KB cap + marker.
- Cleared stubs dropped `changed_files` → `--compact-rich` (H-023).
- Cap-hit output was unrecoverable → `--spill` (H-024).

Open, deliberately unported:
- Acceptance gate (Codex's inversion): no mechanism forces a test-pass
  artifact before done. Candidate for a future card; models currently
  verify on their own often enough that the baseline must be measured
  first (`verify_attempted` mediator exists for exactly this).
- Staleness signal from Devin (parked in plan).
- Semantic search / repo map: rejected — aider proves it costs ~5.6k
  LOC to serve a tool-less model; ours has tools.

## 6. Experiment design

| card | flag | arm | mediator (gate) | direction | evidence filter |
|---|---|---|---|---|---|
| H-023 | `--compact-rich` | idefix-compactrich | `repeat_outcome_cmds` | lt | `mediators.compact_fired==true` cells only |
| H-024 | `--spill` | idefix-spill | `pass` | gt | `mediators.output_discarded==true` cells only |

New mediators in `score.py`: `compact_fired` (journal `ev=compact`, or
`[idefix] context overflow: compacted` eprint) and `output_discarded`
(any tool result `discarded_bytes>0` or `spilled_to` set). Both
idefix-family-scoped, null when the log cannot answer.

Pairing rule: the arm flag is a no-op unless the condition fires, so
unconditional comparisons dilute. Induction must filter to fired cells.

Measured so far (corpus 987 rows): compaction fires on ~24% of idefix
rows so H-023 accumulates normally; the output cap has NEVER fired —
0 `discarded_bytes` events corpus-wide. First trigger attempt
(`flood-key`) failed informatively: task.txt named the pattern, every
model piped `| grep` on first contact, cap never fired. Small models
filter instinctively rather than eat a flood — itself a datapoint:
the failure class `--spill` addresses is rare for these models.
`flood-scan` is the corrected trigger: the task asks for "the anomalous
sector's alert code" without naming any marker, so the first inspection
run is bare and hits the cap; code sits at byte ~82K of 164K, outside
both keep-windows. If even flood-scan produces no cap events, H-024
dies on absence — recorded as absence, not failure.

## 7. Evidence provenance

- Devin's dissection: panic-bounds honesty; claims about own internals.
- Codex's: source-verified file:line on a public repo; spot-checked ok.
- Claude's: 12 citations spot-checked, 2 wrong (aider dead-code line off
  by 5; seatbelt `deny default` line is a comment). Corrected before
  recording. Treat unverified flags in that answer as provisional.
- Our claims: suite 190/0, parity byte-equal, mediators live in
  `scored.jsonl`. Everything above "load-bearing" is inference-from-code
  until an H-card returns rows — the matrix's verdict column is a claim
  register, not a result.

## 8. Open slots

Awaiting self-dissections (paste as they arrive): pi, opencode, goose,
aider, deepagents. Unavailable: dsh (home never imported), rea (not
installed).

**Control run (idefix self-dissection on Nemotron-3.5-Bolt, 2026-11-02):**
two attempts. Attempt 1 (unstructured prompt): the model read AGENTS.md
and ARCHITECTURE.md, never opened source, and hit finish_reason=length
mid-answer after 4 requests — context burned on repeated preamble.
Attempt 2 (scripted: exact grep/sed commands, 1500-word cap): the model
executed the protocol perfectly — 5 commands, correct files and line
ranges, 6 requests, 49s — then emitted process narration ("I have
executed the following steps...") plus a partial mechanism list, not
the Q1-Q6 deliverable. Harness-side: every command landed, results were
consumed, no loop-guard, no truncation of the commands themselves.
Verdict: on this analysis-class task the bottleneck is the 4B model's
synthesis, not the 1.4k harness — idefix supplied the loop; the model
couldn't hold it. That is the measured version of the "model x harness"
separation this project exists to quantify.
