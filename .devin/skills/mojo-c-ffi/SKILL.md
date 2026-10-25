---
name: mojo-c-ffi
description: Traps and working patterns for Mojo external_call C FFI in this repo (bindings.mojo, max_shim.c). Read before adding or changing any external_call marshalling site. Covers dangling as_c_string_span pointers, calloc out-params, in/out bufsize parameters, envp/argv array walking, and platform-gated symbols.
---

# Mojo C FFI in this repo

`bindings.mojo` wraps libcurl, cJSON and POSIX process APIs through
`external_call`. Every bug below shipped silently and returned plausible
values. There are ~50 marshalling sites; a known-answer check is the only
thing that catches a wrong one.

## Traps that already happened here

1. **`String.as_c_string_span().ptr()` can dangle.** The span may
   materialize a temporary buffer; storing the pointer in a heap array is
   a latent UAF. `c_argv` stored `as_c_string_span().ptr()` per arg; after
   new heap traffic, `argv[2]` pointed into `SSH_AUTH_SOCK` and bash ran
   `.7NftYL1efH/Listeners` as a command. Signature to recognize: a shell
   executing a tail of an environment variable. Fix: `strdup` each arg
   inside the expression that builds the C array.

2. **Out-buffers must come from `external_call["calloc", raw_ptr]` +
   `unsafe_bitcast` + `free`.** Passing `List[UInt8].unsafe_ptr()` as a
   C `char*` out-buffer silently writes nothing. `bindings.realpath`
   returned `""` from day one; every repo then hashed to `fnv1a("")` and
   shared one session dir (tests asserted existence, never identity, so
   nothing caught it).

3. **In/out size params must be initialized before the call.**
   `_NSGetExecutablePath(buf, bufsize)` reads `bufsize` on input; a zeroed
   pointer fails. Callocs a `UInt32`, store the capacity, then call.

4. **`char**`/`envp` arrays walk via `envp.value().unsafe_bitcast[cstr_ptr]()`
   then index `slots[i]` until null. The bitcast is already a `Pointer`;
   `unsafe_get()` does not exist on it. Entries are replaced by
   `strdup`'ing the whole `NAME=value` string.

5. **Platform-gated symbols do not link on the other OS.**
   `_NSGetExecutablePath` is Darwin-only; an `external_call` to it breaks
   the Linux build. Put the `#if defined(__APPLE__)`/`__linux__` split in
   `max_shim.c` (see `max_self_exe`) and call the shim symbol instead.

## Rules

- Free every `calloc` you made; never free a pointer C gave you.
- Prefer one shim C function over a new `external_call` signature when
  the call needs setup, platform ifdefs, or struct access.
- After editing a marshalling site, prove identity, not existence:
  `realpath("/")` returns `"/"`, `fnv1a` matches a published vector.
- `external_call` returns must be consumed or `_ =`-assigned; the
  compiler warns on unused.
