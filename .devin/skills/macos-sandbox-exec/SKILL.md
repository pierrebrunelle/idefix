---
name: macos-sandbox-exec
description: Working knowledge for the macOS seatbelt (SBPL) profile used by --sandbox in idefix.mojo, plus the Linux bwrap parity recipe. Read before editing sandbox_profile() or adding sandbox operations.
---

# sandbox-exec (seatbelt) in idefix

`--sandbox` wraps each model command in `/usr/bin/sandbox-exec -p
<profile>`. Spawn it by absolute path: PATH is model-influenced.

## SBPL quirks that cost time here

- Operation names are narrow and suffixed: `sysctl-read` (not `sysctl`).
  An unknown op reports `unbound variable`.
- `(allow signal)` takes no target filter; `(target same-sandbox)`
  reports `illegal function`.
- `(subpath "")` reports `empty subpath pattern` — means an interpolated
  argument was empty (this is how the broken `realpath` was found).
- Profile-parse failures surface in tool output as `exit_code: 65`.

## Debug recipe

Print the profile (`-v` shows it), then run it standalone before wiring:

    /usr/bin/sandbox-exec -p '(version 1)(deny default)...' /bin/echo ok

## Working profile (deny default)

    (version 1)(deny default)
    (allow process-exec process-fork signal sysctl-read mach-lookup)
    (allow file-read*)
    (allow file-write* (subpath REPO) (subpath $TMPDIR)
                       (subpath /private/tmp) (subpath /private$TMPDIR))
    (deny file-write* (subpath REPO/.git/hooks) (literal REPO/.git/config))

The `.git/hooks` + `.git/config` denies mirror codex/Anthropic practice:
the sandbox must not let a command rewrite the repo's guard rails.

## Linux parity (not yet wired)

`--sandbox` dies cleanly at parse when sandbox-exec is absent. The bwrap
equivalent, when someone tests it on Linux:

    bwrap --ro-bind / / --bind "$REPO" "$REPO" --tmpfs /tmp \
          --dev /dev --proc /proc -- bash -c "$CMD"

Ship it only after running it on Linux.
