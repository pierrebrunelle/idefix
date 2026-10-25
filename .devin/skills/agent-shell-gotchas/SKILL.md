---
name: agent-shell-gotchas
description: Shell and tooling traps this repo has paid for, in test scripts, wrappers, installers, and agent-driven commands. Read before writing shell in this repo (tests/run.sh, scripts/*.sh, Makefile, install paths) or when a shell-based check looks vacuous.
---

# Shell gotchas this repo already paid for

- **`git commit -m "$(cat <<'EOF' ... EOF)"` breaks on apostrophes** in
  the message (`unexpected EOF`). Write the message to a file and use
  `git commit -F msgfile`.
- **`command -v` resolves absolute tool paths; `which` does not** under
  make's `sh`. The bundle target uses `command -v $(MOJO)`.
- **`type -aP name` prints nothing but still feeds one empty line** to a
  `while read` loop; guard `[ -n "$line" ]` or a default survives as a
  bogus value.
- **`pgrep -f` matches the post-`exec` cmdline**, not the wrapper text. A
  test pattern containing the wrapper string can never match: prove
  teeth by mutating the code under test (a `killpg`→`kill` mutation
  produced the expected `FAIL orphan survived`).
- **A fixed-port test server flakes wholesale when a stray instance
  holds the port** (`Address already in use`, mass FAILs). Kill first:
  `lsof -ti:18923 | xargs kill -9`.
- **A stub HTTP server needs `do_GET /v1/models`** for liveness probes;
  a POST-only stub makes wrappers take the "server down" path.
- **Second-granularity clocks make deadline-boundary tests racy.** Drive
  time-dependent tests with a deterministic mode (`loop` +
  `--no-loop-guard`), not wall-clock assertions.
- **Interpolating a file list into `bash -c` is a code-execution sink.**
  Filenames are attacker/model-controlled: single-quote every entry
  (`'x'`, `'\''` for embedded quotes), never `$list` raw. This was a
  live bug in the diff echo (`injname` test covers it).
- **Scripted block edits can silently miss**: after sed/python block
  surgery, re-read the transformed region and compile before assuming
  the edit landed ("edits applied" acks report per-edit success, not
  whole-intent success).
- **`curl`-less checksum note:** `install-remote.sh` pipes a release
  tarball to disk with no signature verification — acceptable for a
  first release, noted for hardening later.
- **Fetch `raw.githubusercontent.com` or `gh api` for file content**;
  `github.com/.../blob/...` pages return ~1000 lines of navigation
  chrome before the file.

# Probes that settle inflated claims

- **RSS/memory split:** `otool -L <bin>` for real deps, `vmmap -summary
  <pid>` for dirty pages. Killed the "drop libcurl for 2MB RSS" claim:
  the binary links 4 dylibs and holds ~9MB dirty total.
- **Prefix KV-cache reuse:** `prompt_tokens_details.cached_tokens` in a
  chat-completions response is direct server-side evidence; a repeated
  prefix returned 2432/2471 cached (98%). Append-only history collects
  it free; history rewrite (compaction) is the only prefix-breaker.
