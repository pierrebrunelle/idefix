_Lives at pierrebrunelle/idefix. `bench/` paths below refer to the sibling repo [pierrebrunelle/max-results](https://github.com/pierrebrunelle/max-results) (bench machinery, cards, scored rows stay there)._

# COMPARE — idefix vs the field, mechanism by mechanism

The maintained decision table. Regenerate the scoreboard with
`python3 bench/score.py`; update verdicts when a dissection lands or an
H-card resolves. Verdict vocabulary: **have** (shipped), **arm**
(flagged, card open), **measured-no** (corpus falsified it),
**design-no** (rejected on principle), **dogma-suspect** (we claim it's
dead weight elsewhere, unmeasured here), **open** (undecided, evidence
named).

Last updated: 2026-11-04, corpus 989 rows, idefix 70236bd. **dsh
(DeepSeek Harness) arm is live** as of `compare/dsh-home` import —
headless profile boots against the MLX endpoint direct (native
tool_calls confirmed); bundle-level dissection in MEGAPLAN §1.

## A. The convergent keep-set — what every harness needs (~800 LOC total)

| mechanism | devin | codex | goose | opencode | aider | dsh | idefix | verdict |
|---|:-:|:-:|:-:|:-:|:-:|:-:|---|---|
| action/result loop | keep | keep #1 | keep | keep | keep | `dsh-agent-loop` | core | have |
| answer every tool call | — | keep | keep | keep | n/a | `dsh-invariants` | pairing preserved under compaction | have |
| bounded subprocess (timeout, pgkill, drain-after-cap) | keep | keep | keep | keep | — | `dsh-tool-call-timeout-policy` + jobs | `bindings.mojo` run_capture | have |
| bounded observation (cap head+tail) | keep | keep | keep | keep | — | `dsh-fs-observation-policy` | `--max-output-bytes` 64KB | have |
| output spill to file | keep | (cap only) | keep | keep | — | **`dsh-spill-local`+policy** | `--spill` flag, `70236bd` | arm H-024 |
| compaction backstop | keep #1* | keep | keep | keep | — | `dsh-compaction-basic` (+2 alternates) | `--compact-at` + stubs | have |
| rich compaction (state survives clearing) | keep #1 | — | — | — | — | `<compacted-summary>` marker | `--compact-rich` flag | arm H-023 |
| repo instructions file | — | keep | keep | — | — | `dsh-agent-instructions` | AGENTS/CLAUDE 8KB cap | have |
| finite transport retries | keep | keep | — | — | — | `dsh-llm-retry` | `--retries` | have |
| turn/loop bound | — | — | keep | — | — | **`dsh-repeat-tool-reminder`** | `--max-requests` + loop-guard | have+ |
| exact-match edit + miss hint | keep #1 | — | — | keep | keep | `dsh-tool-str-replace-editor` | `idefix edit` unique-match | have |
| OS sandbox | — | keep | — | — | — | `dsh-bash-sandbox` + policy | `--sandbox` seatbelt | have |
| journal / undo | keep | — | — | — | — | `dsh-session-*` (~15 pkgs) | journal.jsonl + resume | have |
| background/async exec | — | — | — | — | — | `job_output`/`job_kill` | — | open — bounded async |

*Devin's "#1" is the compactor's preservation contract — the shape our
H-023 flag implements.

**idefix covers the entire convergent set.** No cell is empty by accident.

## B. Divergence — what we don't do, and why

| mechanism | carried by | ~LOC there | our verdict | evidence |
|---|---|---:|---|---|
| subagents | devin ≥819, dsh 684KB, deepagents | 2–3k | dogma-suspect | Devin's own delusion pick: "coordination layer whose bugs masquerade as task bugs"; dsh's largest mounted bundle |
| long-term memory | codex 9.2k, deepagents | 9k+ | dogma-suspect | Codex's ablation candidate; machinery proven, benefit never was |
| malformed-arg/call repair | devin ~200, codex 8, goose, opencode | 200–1k | **measured-no** | `arg_failed` = 0.00 over 989 rows; H-020 arm running to kill it formally |
| fuzzy/lenient edit matching | aider, opencode, codex | ~100–3.3k | design-no | aider's fuzzy path is **dead code** (`editblock_coder.py:183` bare return) — users credit a path that never runs |
| edit-format zoo | aider | 3.3k | design-no | 289/297 models use one format; the rest is tail |
| provider breadth | goose 35k, opencode 20+ protocols | 35k+ | design-no | plumbing, not capability |
| permission/shell parser | opencode | 3,174 | design-no | safety-UX parser; our bounds are enforcement, not parsing |
| per-model prompts | opencode, aider | — | model-comp | optimizes the model, not the task |
| persistent shell session | devin ≥1.4k | 1.4k | **different by design (unmeasured)** | stateless commands are deterministic + replayable; persistence is hidden state a 4B can't track. Real divergence — candidate card if a task ever demands it |
| semantic index / repo map | aider 867 | 1k+ | design-no | exists only because aider has no tools; bash gives grep for free |
| todo drift guard | devin ~200 | 200 | model-comp | guards a mechanism we don't have |
| MCP client | devin | ~3k | design-no | tool-surface expansion against the one-tool rule |
| acceptance gate (forced verify) | codex inversion | — | **measured-no for now** | `fabricated_claim` = 4% of idefix fails; revisit if it rises |
| telemetry/rollout/code-mode | codex ~65k | 65k | out of scope | not agent capability |
| smart permissions | devin ≥213 | 200+ | design-no | policy layer; we bound the world instead |

## C. What idefix does that the field doesn't

| mechanism | why it's ours | measured? |
|---|---|---|
| one model-facing tool (`bash`) | forces everything through one auditable pipe | design axiom |
| loop-guard + doom-escalate/nudge | nobody else detects deterministic repeat-death (opencode: "doom-loop detection: none") | H-019/H-022 testing; loop-guard = our #1 failure class |
| env credential scrub | model subprocess never sees KEY/TOKEN/SECRET | mutation-tested |
| `--bare` protocol oracle | byte-identical wire vs ref client — nobody else has a parity lock | check_parity PASS |
| result can't lie (`changed_files`, `discarded_bytes`, `spilled_to`) | exit 0 with no write ≠ success | mediator-backed |
| 1.4k LOC total | auditable in one read | — |

## D. Open candidates — what would change a verdict

| candidate | source | evidence needed | status |
|---|---|---|---|
| staleness signal (file changed externally) | devin journal | a corpus cell where model patches a file modified mid-run | parked — no observed case yet |
| protected `.git` in sandbox | codex | threat-model call, not benchmark | open — safety, not pass-rate |
| hierarchical AGENTS.md (root→cwd) | codex | a task whose commands cd below root | degenerate — commands start at repo root |
| persistent shell | devin | a task class failing on statelessness | unmeasured; revisit on demand |
| acceptance gate | codex inversion | `fabricated_claim` > ~10% of fails | measured-no today |

## E. Measured scoreboard (unpaired raw counts — different task mixes, directional only)

| arm | pass/total | note |
|---|---:|---|
| **idefix** | 59/102 (58%) | base arm |
| idefix-compactrich | 34/52 (65%) | H-023 collecting |
| idefix-compact12 | 19/28 (68%) | H-013 |
| idefix-doomesc | 35/53 (66%) | H-019 |
| idefix-doomnudge | 32/58 (55%) | H-022 |
| idefix-spill | 50/93 (54%) | H-024 collecting |
| idefix-argsrepair | 52/94 (55%) | H-020, mechanism never fires |
| deepagents | 30/61 (49%) | |
| goose | 26/61 (43%) | |
| pi | 30/81 (37%) | |
| opencode | 14/39 (36%) | |
| aider | 34/105 (32%) | |
| dsh | 0/13 (0%) | launch-broken until dsh-home import — fresh rows accumulate now |

Paired/held-out verdicts come from `publish_table.py` only — it refuses
to print under-covered data, which is where the real numbers land.

## F. The smallest set for same-or-better performance

Per all three dissections, the convergent core is ~800 LOC: loop,
pairing, bounded exec, bounded observation, compaction, repo docs,
retries, turn cap. idefix's additions on top (edit contract, loop-guard,
journal, honest results, credential scrub) are what plausibly move us
*above* same-size harnesses — and the raw 58% vs 32–49% spread is
consistent with that, pending paired verdicts.

The field's own numbers support the 90%-cut thesis: devin ships a 186MB
binary, codex ~241k LOC of agent crates, opencode ~25k, goose ~14.8k,
aider ~5.6k (mostly compensating for no tools). idefix is 1.4k — at 4x
under aider and 170x under codex it already matches-or-beats them on
this corpus. The smallest set is roughly what we have; the open work is
proving which of our extras (the flag arms) earn their lines.
