# Minimal native coding agent: one bash tool, one task loop, MAX endpoint.

from std.ffi import external_call, c_int, c_long, c_size_t, c_ssize_t
from std.os import getenv
from std.sys import argv

import bindings


comptime SYSTEM_PROMPT = """You are a coding agent working inside a repository on the user's machine. You have one tool: bash(command), which runs /bin/bash -c in the repository directory and returns the exit code and bounded output.

Rules:
- Act through the tool. Do not describe commands; issue them.
- Inspect before editing: read files, then change them. Write files with here-docs or scripts; verify changes with diffs or tests.
- Fix the root cause; do not skip tests or add workarounds.
- When the task is verifiably done, reply with a short summary of what changed and how it was verified. Do not call the tool again."""


comptime SYSTEM_SUFFIX = """
- Prefer `idefix edit FILE <<'EOF'` with <<<<<<< SEARCH / ======= / >>>>>>> REPLACE blocks for file edits; it fails loudly when the search text does not match.
- The host runs macOS/BSD userland: portable commands only (sed -i '' not sed -i; no GNU-only flags). If a command errors, change the command, not the plan.
- An exit_code of 0 does not prove an edit changed the file (a non-matching sed edits nothing); the result's changed_files field lists what actually changed. Confirm before re-running tests.
- A reply without a tool call ends the run."""


comptime TOOLS = '{"type":"function","function":{"name":"bash","description":"Run a bash command in the repository directory. Returns exit code and bounded merged stdout/stderr output.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"The bash command to run"}},"required":["command"],"additionalProperties":false}}}'
comptime EDIT_HINT = "\nblocks look like:\n<<<<<<< SEARCH\nexact existing text\n=======\nnew text\n>>>>>>> REPLACE"
comptime VERSION = "0.1.0"
comptime DEFAULT_BASE = "http://127.0.0.1:8000/v1"


struct Config(Copyable):
    var repo: String
    var instructions: String
    var task: String
    var base_url: String
    var model: String
    var bearer: String
    var max_requests: Int
    var max_seconds: Int
    var max_command_ms: Int
    var max_output_bytes: Int
    var max_http_bytes: Int
    var max_prompt_tokens: Int
    var max_calls_per_response: Int
    var temperature: Float64
    var has_temperature: Bool
    var transcript: String
    var verbose: Bool
    var compact_at: Int
    var compact_keep: Int
    var retries: Int
    var loop_guard: Bool
    var doom_warn: Bool
    var notify: String
    var state_root: String
    var session_dir: String
    var cont: Bool
    var resume_file: String
    var journal_path: String
    var bare: Bool
    var sandbox: Bool
    var bindir: String

    def __init__(out self):
        self.repo = "."
        self.instructions = ""
        self.task = ""
        self.base_url = DEFAULT_BASE
        self.model = ""
        self.bearer = ""
        self.max_requests = 40
        self.max_seconds = 1800
        self.max_command_ms = 120000
        self.max_output_bytes = 65536
        self.max_http_bytes = 64 * 1024 * 1024
        self.max_prompt_tokens = 0
        self.max_calls_per_response = 8
        self.temperature = 0.0
        self.has_temperature = False
        self.transcript = ""
        self.verbose = False
        self.compact_at = 24000
        self.compact_keep = 6
        self.retries = 3
        self.loop_guard = True
        self.doom_warn = False
        self.notify = ""
        self.state_root = ""
        self.session_dir = ""
        self.cont = False
        self.resume_file = ""
        self.journal_path = ""
        self.bare = False
        self.sandbox = False
        self.bindir = ""


def usage() -> String:
    return "usage: idefix --repo DIR [flags] [--] [TASK]   (no TASK -> interactive REPL on stdin)\n  env: IDEFIX_BASE_URL (default http://127.0.0.1:8000/v1), IDEFIX_MODEL (required), IDEFIX_API_KEY, IDEFIX_STATE_DIR; MAX_* aliases accepted\n  flags: --instructions FILE --max-requests N --max-seconds N --max-command-seconds N --max-output-bytes N --max-http-bytes N --max-prompt-tokens N --temperature F --transcript FILE --max-calls-per-response N -v\n         --compact-at N --compact-keep N --retries N --no-loop-guard --doom-warn --notify CMD --state-dir DIR --continue --resume FILE --bare --sandbox --version\n  state: journal + status under --state-dir | $IDEFIX_STATE_DIR | $HOME/.idefix; --continue resumes this repo's session\n  REPL: shared context across lines; /reset clears, /quit|/exit or Ctrl-D exits, !CMD runs a shell command\n  tool commands run without env vars named for credentials (KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL)"


def read_file(path: String) raises -> String:
    var p = path
    var fp = external_call["fopen", bindings.FILE_ptr](
        p.as_c_string_span().ptr(), "rb".as_c_string_span().ptr()
    )
    if not fp:
        raise Error("cannot open " + path)
    _ = external_call["fseek", c_int](fp, c_int(0), c_int(2))
    var sz = external_call["ftell", c_long](fp)
    if sz < 0:
        _ = external_call["fclose", c_int](fp)
        raise Error("cannot size " + path)
    _ = external_call["fseek", c_int](fp, c_int(0), c_int(0))
    var buf = List[UInt8](capacity=Int(sz) + 1)
    buf.resize(Int(sz), 0)
    _ = external_call["fread", c_size_t](
        buf.unsafe_ptr(), c_size_t(1), c_size_t(sz), fp
    )
    _ = external_call["fclose", c_int](fp)
    return String(unsafe_from_utf8=buf^)


def env2(primary: String, legacy: String) -> String:
    var v = getenv(primary)
    if v == "":
        v = getenv(legacy)
    return v


def die(msg: String, code: Int):
    bindings.eprint("[idefix] " + msg)
    external_call["exit", c_int](c_int(code))


def parse_args() raises -> Config:
    var cfg = Config()
    var a = argv()
    var positional = List[String]()
    var i = 1
    while i < len(a):
        var arg = String(a[i])
        if arg == "-v":
            cfg.verbose = True
        elif arg == "--repo" or arg == "--instructions" or arg == "--transcript" or arg == "--temperature" or arg == "--notify" or arg == "--state-dir" or arg == "--resume":
            i += 1
            if i >= len(a):
                die("missing value for " + arg, 64)
            var v = String(a[i])
            if arg == "--repo":
                cfg.repo = v
            elif arg == "--instructions":
                cfg.instructions = v
            elif arg == "--transcript":
                cfg.transcript = v
            elif arg == "--temperature":
                try:
                    cfg.temperature = Float64(v)
                except:
                    die("invalid value for --temperature: " + v, 64)
                # NaN and +-inf would serialize to bare `nan`/`inf` on the
                # wire, which is not valid JSON.
                if cfg.temperature != cfg.temperature or (cfg.temperature - cfg.temperature) != 0.0:
                    die("invalid value for --temperature: " + v + " (must be finite)", 64)
                cfg.has_temperature = True
            elif arg == "--notify":
                cfg.notify = v
            elif arg == "--state-dir":
                cfg.state_root = v
            elif arg == "--resume":
                cfg.resume_file = v
            else:
                die("unhandled flag: " + arg, 64)
        elif (
            arg == "--max-requests" or arg == "--max-seconds"
            or arg == "--max-command-seconds" or arg == "--max-output-bytes"
            or arg == "--max-http-bytes" or arg == "--max-prompt-tokens"
            or arg == "--max-calls-per-response" or arg == "--compact-at"
            or arg == "--compact-keep" or arg == "--retries"
        ):
            i += 1
            if i >= len(a):
                die("missing value for " + arg, 64)
            var v = String(a[i])
            var n = 0
            try:
                n = Int(v)
            except:
                die("invalid integer for " + arg + ": " + v, 64)
            if n < 0:
                die("invalid value for " + arg + ": " + v + " (must be >= 0)", 64)
            if arg == "--max-requests":
                cfg.max_requests = n
            elif arg == "--max-seconds":
                cfg.max_seconds = n
            elif arg == "--max-command-seconds":
                cfg.max_command_ms = n * 1000
            elif arg == "--max-output-bytes":
                cfg.max_output_bytes = n
            elif arg == "--max-http-bytes":
                cfg.max_http_bytes = n
            elif arg == "--max-prompt-tokens":
                cfg.max_prompt_tokens = n
            elif arg == "--max-calls-per-response":
                cfg.max_calls_per_response = n
            elif arg == "--compact-at":
                cfg.compact_at = n
            elif arg == "--compact-keep":
                cfg.compact_keep = n
            else:
                cfg.retries = n
        elif arg == "--no-loop-guard":
            cfg.loop_guard = False
        elif arg == "--doom-warn":
            cfg.doom_warn = True
        elif arg == "--continue":
            cfg.cont = True
        elif arg == "--bare":
            cfg.bare = True
        elif arg == "--sandbox":
            cfg.sandbox = True
        elif arg == "-h" or arg == "--help":
            print(usage())
            _ = external_call["exit", c_int](c_int(0))
        elif arg == "--version":
            print("idefix " + VERSION)
            _ = external_call["exit", c_int](c_int(0))
        elif arg == "--":
            i += 1
            while i < len(a):
                positional.append(String(a[i]))
                i += 1
        elif arg.find("-") == 0:
            die("unknown flag: " + arg + " (use -- to pass a task starting with -)", 64)
        else:
            positional.append(arg)
        i += 1
    if len(positional) > 1:
        die("multiple positional arguments; quote the task as a single argument", 64)
    if len(positional) == 1:
        cfg.task = positional[0]
    # no TASK -> REPL mode (validated after env checks)
    if cfg.state_root == "":
        cfg.state_root = getenv("IDEFIX_STATE_DIR")
    if cfg.state_root == "":
        var home = getenv("HOME")
        if home != "":
            cfg.state_root = home + "/.idefix"
    # <state_root>/config (key=value): lowest-precedence connection defaults,
    # so `idefix "task"` works with zero exports once configured.
    if cfg.state_root != "":
        try:
            var conf = read_file(cfg.state_root + "/config")
            for line in conf.split("\n"):
                var eq = line.find("=")
                if eq <= 0 or line.strip().find("#") == 0:
                    continue
                var k = String(line[byte= :eq].strip())
                var v = String(line[byte= eq + 1 :].strip())
                if k == "base_url" and cfg.base_url == DEFAULT_BASE:
                    cfg.base_url = v
                elif k == "model" and cfg.model == "":
                    cfg.model = v
                elif k == "api_key" and cfg.bearer == "":
                    cfg.bearer = v
        except:
            pass
    var env_base = env2("IDEFIX_BASE_URL", "MAX_BASE_URL")
    if env_base != "":
        cfg.base_url = env_base
    var env_model = env2("IDEFIX_MODEL", "MAX_MODEL")
    if env_model != "":
        cfg.model = env_model
    var env_key = env2("IDEFIX_API_KEY", "MAX_API_KEY")
    if env_key != "":
        cfg.bearer = env_key
    if cfg.model == "":
        die("IDEFIX_MODEL is not set. " + usage(), 64)
    cfg.bindir = bindings.self_dir()
    var acc = cfg.repo
    var accrc = external_call["access", c_int](acc.as_c_string_span().ptr(), c_int(0))
    if accrc != 0:
        die("repo path does not exist: " + cfg.repo, 64)
    if not bindings.is_dir(cfg.repo):
        die("repo path is not a directory: " + cfg.repo, 64)
    if cfg.bare:
        # bench-compat mode: every behavior added after the original loop off
        if cfg.cont or cfg.resume_file != "" or cfg.notify != "" or cfg.sandbox:
            die("--bare disables --continue, --resume, --notify and --sandbox", 64)
        cfg.compact_at = 0
        cfg.retries = 0
        cfg.loop_guard = False
        cfg.doom_warn = False
    if cfg.sandbox:
        if not bindings.file_exists("/usr/bin/sandbox-exec"):
            die("--sandbox requires macOS sandbox-exec; Linux parity is bwrap, not yet wired", 64)
        # '"' and '\' break out of quoted SBPL subpath args
        var stmp = getenv("TMPDIR")
        # the profile embeds realpath(repo), not the raw flag: a symlink
        # can smuggle a quote past a raw-string check, so validate the
        # resolved path too (realpath of a missing dir returns its arg)
        var rres = bindings.realpath(cfg.repo)
        if (
            cfg.repo.find('"') >= 0 or cfg.repo.find("\\") >= 0
            or stmp.find('"') >= 0 or stmp.find("\\") >= 0
            or rres.find('"') >= 0 or rres.find("\\") >= 0
        ):
            die("--sandbox: repo path and TMPDIR must not contain '\"' or '\\'", 64)
    if not cfg.bare and cfg.state_root != "":
        cfg.session_dir = (
            cfg.state_root + "/sessions/"
            + bindings.fnv1a_hex(bindings.realpath(cfg.repo))
        )
        cfg.journal_path = cfg.session_dir + "/journal.jsonl"
    if cfg.resume_file != "":
        cfg.journal_path = cfg.resume_file
    if cfg.instructions != "":
        try:
            cfg.instructions = read_file(cfg.instructions)
        except e:
            die("cannot read instructions file: " + String(e), 64)
    return cfg^


def vlog(cfg: Config, s: String):
    if cfg.verbose:
        bindings.eprint("[idefix] " + s)


def write_transcript(path: String, history: String):
    if path == "":
        return
    var ok = bindings.write_file(path, "[" + history + "]")
    if not ok:
        bindings.eprint("[idefix] failed to write transcript: " + path)


def journal(cfg: Config, ev: String):
    if cfg.journal_path == "":
        return
    _ = bindings.append_file(cfg.journal_path, ev + "\n")


def journal_msg(cfg: Config, msg_json: String):
    journal(cfg, '{"ev":"msg","m":' + msg_json + "}")


def push_msg(cfg: Config, mut history: String, msg_json: String):
    history += "," + msg_json
    journal_msg(cfg, msg_json)


def tool_msg(cid: String, content: String) -> String:
    return (
        '{"role":"tool","tool_call_id":' + bindings.json_quote(cid)
        + ',"content":' + bindings.json_quote(content) + "}"
    )


def looks_write(cmd: String) -> Bool:
    var marks = List[String](
        "sed -i", "tee ", "apply_patch", "mv ", "cp ", "rm ",
        "mkdir", "touch", "patch ", "truncate", "dd ",
        __list_literal__=NoneType(),
    )
    for i in range(len(marks)):
        if cmd.find(marks[i]) >= 0:
            return True
    # '>' writes a file unless it is an fd duplicate (2>&1, >&2), a
    # comparison (>=, =>) or an arrow (->); '>' in '>>' still counts
    var bs = cmd.as_bytes()
    for i in range(cmd.byte_length()):
        if Int(bs[i]) != 0x3E:
            continue
        var prev = 0x20
        var nxt = 0x20
        if i > 0:
            prev = Int(bs[i - 1])
        if i + 1 < cmd.byte_length():
            nxt = Int(bs[i + 1])
        if prev != 0x26 and prev != 0x2D and prev != 0x3D and nxt != 0x3D and nxt != 0x26:
            return True
    return False


def housekeeping_ms(deadline: Int, cap: Int) -> Int:
    # housekeeping commands (snapshot/diff/cleanup/notify) share the
    # task deadline instead of running their full fixed timeout
    var ms = Int((deadline - bindings.now_seconds()) * 1000)
    if ms > cap:
        return cap
    if ms < 1000:
        return 1000
    return ms


def sandbox_profile(repo: String, tmp: String) -> String:
    return (
        "(version 1)(deny default)"
        + "(allow process-exec process-fork signal sysctl-read mach-lookup)"
        + "(allow file-read*)"
        + '(allow file-write* (subpath "' + repo + '") (subpath "' + tmp
        + '") (subpath "/private/tmp") (subpath "/private' + tmp + '"))'
        + '(deny file-write* (subpath "' + repo
        + '/.git/hooks") (literal "' + repo + '/.git/config"))'
    )


def write_status(cfg: Config, st: TurnStats, extra: String):
    if cfg.session_dir == "":
        return
    var s = (
        "req=" + String(st.requests)
        + " cmds=" + String(st.commands)
        + " prompt_tokens=" + String(st.last_prompt_tokens)
        + " elapsed=" + String(bindings.now_seconds() - st.start_s) + "s"
    )
    if extra != "":
        s += " " + extra
    _ = bindings.write_file(cfg.session_dir + "/status", s + "\n")


def build_body(cfg: Config, history: String) -> String:
    var temp = String("")
    if cfg.has_temperature:
        temp = ',"temperature":' + String(cfg.temperature)
    return (
        '{"model":'
        + bindings.json_quote(cfg.model)
        + ',"stream":false'
        + temp
        + ',"tools":['
        + TOOLS
        + '],"messages":['
        + history
        + "]}"
    )


def compact_history(history: String, keep: Int) raises -> Tuple[String, Int]:
    # Rewrite contents of tool messages older than the last `keep` to a stub.
    # Messages are edited in place, never removed: tool_call pairing is a wire
    # invariant and dropping a tool result would 400 the next request.
    var arr = bindings.cjson_parse("[" + history + "]")
    if not arr:
        return history, 0
    var n = bindings.cjson_len(arr)
    var n_tool = 0
    for i in range(n):
        var m = bindings.cjson_arr(arr, i)
        if bindings.cjson_str(bindings.cjson_get(m, "role")) == "tool":
            n_tool += 1
    var clear_before = n_tool - keep
    if clear_before <= 0:
        bindings.cjson_del(arr)
        return history, 0
    var cleared = 0
    var seen = 0
    for i in range(n):
        var m = bindings.cjson_arr(arr, i)
        if bindings.cjson_str(bindings.cjson_get(m, "role")) != "tool":
            continue
        seen += 1
        if seen > clear_before:
            break
        var content = bindings.cjson_str(bindings.cjson_get(m, "content"))
        if content.find("[cleared") >= 0:
            continue
        var exit_code = String("null")
        var inner = bindings.cjson_parse(content)
        if inner:
            var ec = bindings.cjson_get(inner, "exit_code")
            if ec:
                exit_code = String(Int(bindings.cjson_num(ec)))
            bindings.cjson_del(inner)
        cleared += content.byte_length()
        var stub = (
            '{"exit_code":'
            + exit_code
            + ',"output":"[cleared; re-run the command to inspect]","discarded_bytes":0}'
        )
        _ = bindings.cjson_replace_str(m, "content", stub)
    var out = bindings.cjson_print(arr)
    bindings.cjson_del(arr)
    var o = String(out.strip())
    if o.byte_length() >= 2 and String(o[byte= : 1]) == "[":
        var inner = String(o[byte=1 : o.byte_length() - 1])
        return inner, cleared
    return o, cleared


def rebuild_history(journal_text: String, system_msg: String) raises -> String:
    # Replay msg events from a JSONL journal into a history fragment.
    var msgs = List[String]()
    for line in journal_text.split("\n"):
        var s = String(line)
        if s == "":
            continue
        var j = bindings.cjson_parse(s)
        if not j:
            continue
        var ev = bindings.cjson_str(bindings.cjson_get(j, "ev"))
        if ev == "reset":
            msgs.clear()
        elif ev == "msg":
            var m = bindings.cjson_get(j, "m")
            if m:
                msgs.append(bindings.cjson_print(m))
        bindings.cjson_del(j)
    # A journal cut mid-batch (crash between the assistant msg and its
    # tool results) would replay unpaired tool_calls; the next request
    # 400s. Drop the trailing assistant msg in that case.
    var pend_idx = -1
    var pend_need = 0
    var pend_got = 0
    for i in range(len(msgs)):
        var mj = bindings.cjson_parse(msgs[i])
        if mj:
            var role = bindings.cjson_str(bindings.cjson_get(mj, "role"))
            var tc = bindings.cjson_get(mj, "tool_calls")
            if role == "assistant" and tc and bindings.cjson_len(tc) > 0:
                pend_idx = i
                pend_need = bindings.cjson_len(tc)
                pend_got = 0
            elif role == "tool" and pend_need > 0:
                pend_got += 1
            bindings.cjson_del(mj)
    var keep = len(msgs)
    if pend_need > 0 and pend_got < pend_need:
        keep = pend_idx
    var history = system_msg
    for i in range(keep):
        history += "," + msgs[i]
    return history


def is_ctx_error(resp: String) -> Bool:
    var low = resp.lower()
    return low.find("context") >= 0 or low.find("too long") >= 0


struct TurnStats(Copyable):
    var requests: Int
    var commands: Int
    var last_prompt_tokens: Int
    var total_prompt_tokens: Int
    var total_completion_tokens: Int
    var start_s: Int
    var last_cmd: String
    var cmd_repeats: Int

    def __init__(out self):
        self.requests = 0
        self.commands = 0
        self.last_prompt_tokens = 0
        self.total_prompt_tokens = 0
        self.total_completion_tokens = 0
        self.start_s = 0
        self.last_cmd = ""
        self.cmd_repeats = 0


def run_turn(cfg: Config, mut history: String, mut st: TurnStats) raises -> Tuple[String, Int]:
    # One task: loop model calls + bash execution until the model answers
    # with plain text or a budget trips. Returns (final_answer, exit_code).
    var deadline = bindings.now_seconds() + cfg.max_seconds
    var exit_code = 0
    var final = ""
    var doom_armed = False
    # per-turn budget: the REPL shares st across turns
    st.requests = 0
    while st.requests < cfg.max_requests:
        if bindings.now_seconds() > deadline:
            bindings.eprint("[idefix] --max-seconds exceeded")
            exit_code = 2
            break
        var req_ms = (deadline - bindings.now_seconds()) * 1000
        var r = bindings.http_post(
            cfg.base_url + "/chat/completions", build_body(cfg, history),
            cfg.bearer, max(req_ms, 1), cfg.max_http_bytes
        )
        st.requests += 1
        var code = r[0]
        var resp = r[1]
        vlog(cfg, "request " + String(st.requests) + " -> http " + String(code))
        var attempt = 0
        while (code == 0 or code >= 500) and attempt < cfg.retries and st.requests < cfg.max_requests:
            # code 0 is a transport error; 5xx is retryable
            if bindings.now_seconds() > deadline:
                break
            attempt += 1
            bindings.eprint(
                "[idefix] http " + String(code) + ": retry "
                + String(attempt) + "/" + String(cfg.retries)
            )
            journal(
                cfg,
                '{"ev":"retry","ts":' + String(bindings.now_seconds())
                + ',"attempt":' + String(attempt) + ',"http":' + String(code) + "}",
            )
            var backoff_ms = 1000 * (1 << min(attempt - 1, 16))
            var left_ms = (deadline - bindings.now_seconds()) * 1000
            if left_ms > 0:
                bindings.sleep_ms(min(backoff_ms, left_ms))
            req_ms = (deadline - bindings.now_seconds()) * 1000
            r = bindings.http_post(
                cfg.base_url + "/chat/completions", build_body(cfg, history),
                cfg.bearer, max(req_ms, 1), cfg.max_http_bytes
            )
            st.requests += 1
            code = r[0]
            resp = r[1]
        if code == 0 and (
            bindings.now_seconds() > deadline or resp.find("CURL_ERROR:28") >= 0
        ):
            # 28 is our own req_ms timeout clamp, which is deadline-derived
            bindings.eprint("[idefix] --max-seconds exceeded")
            exit_code = 2
            break
        if not cfg.bare and code == 400 and is_ctx_error(resp):
            # context overflow: clear old tool output and retry this request once
            var (nh, cleared) = compact_history(history, cfg.compact_keep)
            if cleared > 0:
                history = nh
                bindings.eprint("[idefix] context overflow: compacted " + String(cleared) + " bytes")
                journal(
                    cfg,
                    '{"ev":"compact","ts":' + String(bindings.now_seconds())
                    + ',"cleared":' + String(cleared) + "}",
                )
                if st.requests < cfg.max_requests:
                    req_ms = (deadline - bindings.now_seconds()) * 1000
                    r = bindings.http_post(
                        cfg.base_url + "/chat/completions", build_body(cfg, history),
                        cfg.bearer, max(req_ms, 1), cfg.max_http_bytes
                    )
                    st.requests += 1
                    code = r[0]
                    resp = r[1]
        if code != 200:
            bindings.eprint("[idefix] http " + String(code) + ": " + resp[byte= : min(resp.byte_length(), 300)])
            exit_code = 3
            break
        var root = bindings.cjson_parse(resp)
        if not root:
            bindings.eprint("[idefix] response is not JSON")
            exit_code = 3
            break
        var usage_ = bindings.cjson_get(root, "usage")
        if usage_:
            st.last_prompt_tokens = Int(bindings.cjson_num(bindings.cjson_get(usage_, "prompt_tokens")))
            st.total_prompt_tokens += st.last_prompt_tokens
            st.total_completion_tokens += Int(bindings.cjson_num(bindings.cjson_get(usage_, "completion_tokens")))
        write_status(cfg, st, "")
        var choices = bindings.cjson_get(root, "choices")
        if not choices or bindings.cjson_len(choices) == 0:
            bindings.eprint("[idefix] response has no choices")
            bindings.cjson_del(root)
            exit_code = 3
            break
        var choice0 = bindings.cjson_arr(choices, 0)
        var fr = bindings.cjson_str(bindings.cjson_get(choice0, "finish_reason"))
        if fr == "length":
            bindings.eprint("[idefix] warning: finish_reason=length (truncated)")
        var msg = bindings.cjson_get(choice0, "message")
        if not msg:
            bindings.cjson_del(root)
            bindings.eprint("[idefix] response has no message")
            exit_code = 3
            break
        var calls = bindings.cjson_get(msg, "tool_calls")
        var content = bindings.strip_think(
            bindings.cjson_str(bindings.cjson_get(msg, "content"))
        )
        if content == "":
            # thinking-mode servers (ollama et al.) put the answer in a
            # separate reasoning field and leave content empty
            content = bindings.strip_think(
                bindings.cjson_str(bindings.cjson_get(msg, "reasoning"))
            )
        if content == "":
            content = bindings.strip_think(
                bindings.cjson_str(bindings.cjson_get(msg, "reasoning_content"))
            )
        var msg_owner = bindings.raw_ptr()
        var asst = String("")
        if not (calls and bindings.cjson_len(calls) > 0):
            var mk = bindings.markup_calls_json(content)
            if mk != "":
                asst = (
                    '{"role":"assistant","content":'
                    + bindings.json_quote(content)
                    + ',"tool_calls":[' + mk + "]}"
                )
                msg_owner = bindings.cjson_parse(asst)
                calls = bindings.cjson_get(msg_owner, "tool_calls")
        if calls and bindings.cjson_len(calls) > 0:
            var plan = bindings.strip_markup(content)
            if not cfg.bare and plan != "":
                bindings.eprint("[model] " + plan)
            if asst == "":
                # MAX echoes null tool_calls/function_call fields that its own
                # request schema rejects; rebuild the assistant message valid.
                asst = '{"role":"assistant","content":'
                var cont = bindings.cjson_get(msg, "content")
                if cont:
                    asst += bindings.cjson_print(cont)
                else:
                    asst += "null"
                asst += ',"tool_calls":' + bindings.cjson_print(calls) + "}"
            push_msg(cfg, history, asst)
            var n = bindings.cjson_len(calls)
            if n > cfg.max_calls_per_response:
                n = cfg.max_calls_per_response
            var doom = False
            for j in range(n):
                var call = bindings.cjson_arr(calls, j)
                var cid = bindings.cjson_str(bindings.cjson_get(call, "id"))
                var fn_ = bindings.cjson_get(call, "function")
                var name = bindings.cjson_str(bindings.cjson_get(fn_, "name"))
                var arg_item = bindings.cjson_get(fn_, "arguments")
                var argsj = bindings.cjson_str(arg_item)
                if argsj == "" and arg_item:
                    # some servers emit arguments as an object, not a
                    # stringified blob - re-serialize like the markup path
                    argsj = bindings.cjson_print(arg_item)
                var result = String("")
                if name != "bash":
                    result = (
                        '{"error":"unknown tool","name":'
                        + bindings.json_quote(name) + "}"
                    )
                else:
                    var aj = bindings.cjson_parse(argsj)
                    if not aj:
                        result = '{"error":"arguments are not valid JSON"}'
                    else:
                        var cmd = bindings.cjson_str(bindings.cjson_get(aj, "command"))
                        if bindings.now_seconds() > deadline:
                            result = '{"error":"time budget expired; not executed"}'
                        elif cmd == "":
                            result = '{"error":"missing or empty command"}'
                        else:
                            st.commands += 1
                            vlog(cfg, "bash: " + cmd[byte= : min(cmd.byte_length(), 120)])
                            var nl = cmd.find("\n")
                            var first = String(cmd[byte= : min(nl if nl >= 0 else cmd.byte_length(), 80)])
                            write_status(cfg, st, "last=" + first)
                            if cfg.loop_guard:
                                if cmd == st.last_cmd:
                                    st.cmd_repeats += 1
                                else:
                                    st.cmd_repeats = 0
                                st.last_cmd = cmd
                            var doom_now = cfg.loop_guard and st.cmd_repeats >= 4
                            var mark = String("")
                            var hasher = String("md5 -r")
                            var prof = String("")
                            var clone_ok = False
                            var tree = String("")
                            if doom_now and cfg.doom_warn and not doom_armed:
                                # warn once instead of killing: the model sees
                                # the error and gets one turn to stop on its own
                                doom_armed = True
                                result = (
                                    '{"error":"same command repeated 5 times;'
                                    + ' do not re-issue it - run a different check'
                                    + ' or reply with your final answer.'
                                    + ' Repeating it stops the run."}'
                                )
                                journal(
                                    cfg,
                                    '{"ev":"loop","ts":'
                                    + String(bindings.now_seconds())
                                    + ',"cmd":' + bindings.json_quote(cmd)
                                    + ',"warn":true}',
                                )
                            elif doom_now:
                                result = (
                                    '{"error":"same command repeated 5 times;'
                                    + ' stopped by loop guard"}'
                                )
                                journal(
                                    cfg,
                                    '{"ev":"loop","ts":'
                                    + String(bindings.now_seconds())
                                    + ',"cmd":' + bindings.json_quote(cmd)
                                    + ',"stop":true}',
                                )
                                doom = True
                            else:
                                if not cfg.bare:
                                    # hash snapshot so "rewritten" and "changed" are
                                    # different answers; sed -i exits 0 on a no-match
                                    var hw = bindings.run_capture(
                                        "if command -v md5sum >/dev/null; then echo md5sum;"
                                        + " elif command -v md5 >/dev/null; then echo 'md5 -r'; fi",
                                        cfg.repo, 64, 5000, False,
                                    )
                                    # no hasher: mark stays "" and the whole
                                    # snapshot/diff stage stays off this command
                                    if hw[1] == 0 and String(hw[0].strip()) != "":
                                        hasher = String(hw[0].strip())
                                        mark = cfg.session_dir + "/cmdmark-" + String(bindings.pid())
                                        if cfg.session_dir == "":
                                            mark = "/tmp/idefix-cmdmark-" + String(Int(bindings.now_seconds() * 1000)) + "-" + String(bindings.pid())
                                        var snap = "find . "
                                        if cfg.session_dir.find(cfg.repo + "/") == 0:
                                            snap += "-path './" + String(
                                                cfg.session_dir[byte= cfg.repo.byte_length() + 1 :]
                                            ) + "' -prune -o "
                                        # files >=50M skip hashing; a size line keeps
                                        # them visible to changed_files (+48M overlaps
                                        # the boundary so nothing falls between)
                                        snap += (
                                            "\\( -name .git -o -name .max-state -o -name .idefix-state \\) -prune -o "
                                            + "-type f \\( -size -50M -exec " + hasher
                                            + " {} + -o -size +48M -exec sh -c 'for f do echo \"big:$(wc -c <\"$f\" | tr -d \"[:space:]\") $f\"; done' sh {} + \\)"
                                            + " 2>/dev/null | sort > " + mark
                                        )
                                        _ = bindings.run_capture(snap, cfg.repo, 64, housekeeping_ms(deadline, 30000), False)
                                        tree = "/tmp/idefix-tree-" + String(Int(bindings.now_seconds() * 1000)) + "-" + String(bindings.pid())
                                        var cr = bindings.run_capture(
                                            "rm -rf " + tree + "; cp -Rc . " + tree,
                                            cfg.repo, 64, 60000, False,
                                        )
                                        clone_ok = cr[1] == 0
                                var cmd_timeout = cfg.max_command_ms
                                var left_ms = (deadline - bindings.now_seconds()) * 1000
                                if left_ms < cmd_timeout:
                                    cmd_timeout = left_ms
                                if cmd_timeout < 1:
                                    cmd_timeout = 1
                                if cfg.sandbox:
                                    var tmp = getenv("TMPDIR")
                                    if tmp == "":
                                        tmp = "/private/tmp"
                                    prof = sandbox_profile(bindings.realpath(cfg.repo), tmp)
                                    vlog(cfg, "profile: " + prof)
                                var pdir = String("")
                                if not cfg.bare:
                                    pdir = cfg.bindir
                                var rc = bindings.run_capture(
                                    cmd, cfg.repo, cfg.max_output_bytes, cmd_timeout, True, prof, pdir
                                )
                                vlog(
                                    cfg,
                                    "  -> exit " + String(rc[1])
                                    + " out=" + String(rc[0].byte_length()) + "B",
                                )
                                result = (
                                    '{"exit_code":'
                                    + String(rc[1])
                                    + ',"output":'
                                    + bindings.json_quote(rc[0])
                                    + ',"discarded_bytes":'
                                    + String(rc[2])
                                )
                                if st.cmd_repeats >= 2:
                                    var count = st.cmd_repeats + 1
                                    result += (
                                        ',"loop_warning":"same command ran '
                                        + String(count) + ' times in a row;'
                                        + ' if a check already passed, reply with'
                                        + ' your final answer instead of re-running"'
                                    )
                                    journal(
                                        cfg,
                                        '{"ev":"loop","ts":' + String(bindings.now_seconds())
                                        + ',"cmd":' + bindings.json_quote(cmd)
                                        + ',"count":' + String(count) + "}",
                                    )
                                if mark != "":
                                    # same snapshot again; lines present on only one
                                    # side are created, modified or deleted files
                                    var dcmd = "find . "
                                    if cfg.session_dir.find(cfg.repo + "/") == 0:
                                        dcmd += "-path './" + String(
                                            cfg.session_dir[byte= cfg.repo.byte_length() + 1 :]
                                        ) + "' -prune -o "
                                    dcmd += (
                                        "\\( -name .git -o -name .max-state -o -name .idefix-state \\) -prune -o "
                                        + "-type f \\( -size -50M -exec " + hasher
                                        + " {} + -o -size +48M -exec sh -c 'for f do echo \"big:$(wc -c <\"$f\" | tr -d \"[:space:]\") $f\"; done' sh {} + \\)"
                                        + " 2>/dev/null"
                                        + " | sort > " + mark + ".after; "
                                        + "{ comm -13 " + mark + " " + mark + ".after; "
                                        + "comm -23 " + mark + " " + mark + ".after; }"
                                        # md5sum separates with two spaces; sed
                                        # strips field 1 plus all spacing so the
                                        # filename survives on both hashers
                                        + " | sed 's/^[^ ]* *//' | sort -u | head -40"
                                    )
                                    var fr = bindings.run_capture(
                                        dcmd, cfg.repo, 4096, housekeeping_ms(deadline, 30000), False
                                    )
                                    if fr[1] == 0:
                                        var cf = String(fr[0].strip())
                                        result += (
                                            ',"changed_files":'
                                            + bindings.json_quote(cf)
                                        )
                                        if cf != "" and clone_ok:
                                            # filenames are model-controlled;
                                            # single-quote every entry or it
                                            # executes in this shell
                                            var qf = String("")
                                            var cfl = cf.split("\n")
                                            for fi in range(len(cfl)):
                                                var fname = String(cfl[fi])
                                                if fname != "":
                                                    qf += "'" + fname.replace("'", "'\\''") + "' "
                                            var d2 = (
                                                "for f in " + qf
                                                + "; do diff -u -- \"" + tree + "/$f\" \"$f\""
                                                + " 2>/dev/null || diff -u -- /dev/null \"$f\""
                                                + " 2>/dev/null; done | head -120"
                                            )
                                            var dr = bindings.run_capture(
                                                d2, cfg.repo, 8192, housekeeping_ms(deadline, 15000), False
                                            )
                                            var dtxt = String(dr[0].strip())
                                            if dtxt != "":
                                                if dtxt.byte_length() > 4000:
                                                    var dcap = String(dtxt[byte= : 4000])
                                                    dtxt = dcap^
                                                result += (
                                                    ',"diff":' + bindings.json_quote(dtxt)
                                                )
                                        if cf == "" and rc[1] == 0 and looks_write(cmd):
                                            result += (
                                                ',"warning":"exit 0 but no files'
                                                + ' changed; the edit may not have applied"'
                                            )
                                    # tree/marks are per-command temp state;
                                    # clean up even when the diff loop did not run
                                    var cl = "rm -f '" + mark + "' '" + mark + ".after'"
                                    if clone_ok:
                                        cl += "; rm -rf '" + tree + "'"
                                    _ = bindings.run_capture(
                                        cl, cfg.repo, 64, housekeeping_ms(deadline, 30000), False
                                    )
                                result += "}"
                        bindings.cjson_del(aj)
                push_msg(cfg, history, tool_msg(cid, result))
            # every call needs a tool result on the wire or the next request 400s
            var total = bindings.cjson_len(calls)
            for j in range(n, total):
                var call = bindings.cjson_arr(calls, j)
                var cid = bindings.cjson_str(bindings.cjson_get(call, "id"))
                push_msg(
                    cfg, history,
                    tool_msg(cid, '{"error":"call limit reached; not executed"}')
                )
            if doom:
                bindings.eprint("[idefix] loop guard stopped a repeated command")
                exit_code = 2
                break
        else:
            if content.find("<tool_call") >= 0:
                # the server returned markup it could not structure; the
                # model meant to call a tool, so re-ask instead of finishing
                bindings.eprint("[idefix] unparseable <tool_call> in reply; re-asking")
                push_msg(
                    cfg, history,
                    '{"role":"user","content":"Your reply contained a <tool_call> tag that could not be parsed. Re-issue it as a proper tool call, or answer without it."}',
                )
                if msg_owner:
                    bindings.cjson_del(msg_owner)
                bindings.cjson_del(root)
                continue
            final = content
            bindings.cjson_del(root)
            exit_code = 0
            if bindings.now_seconds() > deadline:
                bindings.eprint("[idefix] --max-seconds exceeded")
                exit_code = 2
            break
        if msg_owner:
            bindings.cjson_del(msg_owner)
        bindings.cjson_del(root)
        if bindings.now_seconds() > deadline:
            bindings.eprint("[idefix] --max-seconds exceeded")
            exit_code = 2
            break
        if cfg.max_prompt_tokens > 0 and st.last_prompt_tokens > cfg.max_prompt_tokens:
            bindings.eprint("[idefix] --max-prompt-tokens exceeded")
            exit_code = 2
            break
        if cfg.compact_at > 0 and st.last_prompt_tokens > cfg.compact_at:
            var (nh, cleared) = compact_history(history, cfg.compact_keep)
            if cleared > 0:
                history = nh
                bindings.eprint(
                    "[idefix] prompt_tokens=" + String(st.last_prompt_tokens)
                    + " over --compact-at " + String(cfg.compact_at)
                    + ": cleared " + String(cleared) + " bytes of old tool output"
                )
                journal(
                    cfg,
                    '{"ev":"compact","ts":' + String(bindings.now_seconds())
                    + ',"cleared":' + String(cleared) + "}",
                )
    else:
        exit_code = 2
    return final, exit_code


def finish(cfg: Config, history: String, st: TurnStats, final: String, code: Int):
    write_transcript(cfg.transcript, history)
    journal(
        cfg,
        '{"ev":"done","ts":' + String(bindings.now_seconds())
        + ',"exit":' + String(code)
        + ',"requests":' + String(st.requests)
        + ',"commands":' + String(st.commands)
        + ',"tokens":' + String(st.total_prompt_tokens + st.total_completion_tokens)
        + "}",
    )
    if cfg.notify != "":
        try:
            _ = bindings.run_capture(cfg.notify, cfg.repo, 8192, 30000, False)
        except:
            pass
    bindings.eprint(
        "[idefix] requests=" + String(st.requests)
        + " commands=" + String(st.commands)
        + " prompt_tokens=" + String(st.last_prompt_tokens)
        + " tokens=" + String(st.total_prompt_tokens) + "+" + String(st.total_completion_tokens)
        + " elapsed=" + String(bindings.now_seconds() - st.start_s) + "s"
        + " exit=" + String(code)
    )
    if final != "":
        print(final)
    external_call["exit", c_int](c_int(code))


def read_stdin() -> String:
    var out = String("")
    var buf = List[UInt8](capacity=8192)
    buf.resize(8192, 0)
    while True:
        var n = external_call["read", c_ssize_t](
            c_int(0), buf.unsafe_ptr(), c_size_t(8192)
        )
        if n <= 0:
            break
        out += String(unsafe_from_utf8=buf[: Int(n)])
    return out


def find_all(hay: String, needle: String) -> List[Int]:
    var hits = List[Int]()
    var off = 0
    while True:
        var i = hay.find(needle, off)
        if i < 0:
            break
        hits.append(i)
        off = i + 1
    return hits^


def count_lines(s: String, upto: Int) -> Int:
    var n = 1
    for i in range(min(upto, s.byte_length())):
        if s[byte= i] == "\n":
            n += 1
    return n


def run_edit(path: String) raises -> Int:
    # idefix edit FILE < blocks: aider-style <<<<<<< SEARCH/=======/>>>>>>>
    # REPLACE pairs on stdin. Applies all blocks in memory, then writes
    # once - a failed block changes nothing.
    var text = String("")
    try:
        text = read_file(path)
    except e:
        bindings.eprint("idefix edit: cannot read " + path + ": " + String(e))
        return 1
    var spec = read_stdin()
    var pos = 0
    var applied = 0
    var S = "<<<<<<< SEARCH"
    var M = "======="
    var E = ">>>>>>> REPLACE"
    while True:
        var sb = spec.find(S, pos)
        if sb < 0:
            break
        var mb = spec.find("\n" + M + "\n", sb)
        var eb = spec.find("\n" + E, mb if mb >= 0 else sb)
        if mb < 0 or eb < 0:
            bindings.eprint("idefix edit: malformed block (missing ======= or >>>>>>> REPLACE)" + EDIT_HINT)
            return 1
        var old = String(spec[byte= sb + S.byte_length() + 1 : mb])
        var new = String(spec[byte= mb + M.byte_length() + 2 : eb])
        var hits = find_all(text, old)
        if len(hits) != 1:
            var first = String(old.split("\n")[0])
            if first == "" and old.byte_length() > 1:
                first = String(old.split("\n")[1])
            var fhits = find_all(text, first)
            var near = String("")
            for i in range(min(len(fhits), 4)):
                near += "," + String(count_lines(text, fhits[i]))
            bindings.eprint(
                "idefix edit: SEARCH matched " + String(len(hits)) + " times in " + path
                + (" (anchors near lines " + near[byte=1:] + ")" if len(fhits) > 0 else "")
            )
            return 1
        text = String(
            text[byte= : hits[0]] + new + text[byte= hits[0] + old.byte_length() :]
        )
        applied += 1
        pos = eb + E.byte_length()
    if applied == 0:
        bindings.eprint("idefix edit: no SEARCH/REPLACE blocks on stdin" + EDIT_HINT)
        return 1
    # syntax gate: never write python that does not compile
    if path.endswith(".py"):
        var has_py = bindings.run_capture("command -v python3", ".", 64, 5000, False)
        if has_py[1] == 0 and String(has_py[0].strip()) != "":
            var tmp = path + ".maxedit-tmp"
            _ = bindings.write_file(tmp, text)
            var qtmp = "'" + tmp.replace("'", "'\\''") + "'"
            # compile() parses in memory; py_compile would litter __pycache__
            var chk = bindings.run_capture(
                "python3 -c 'import sys;"
                + "compile(open(sys.argv[1]).read(),sys.argv[1],\"exec\")' "
                + qtmp,
                ".", 4096, 15000, False,
            )
            _ = bindings.run_capture("rm -f " + qtmp, ".", 64, 5000, False)
            if chk[1] != 0:
                bindings.eprint("idefix edit: result does not compile:\n" + chk[0].strip())
                return 1
    if not bindings.write_file(path, text):
        bindings.eprint("idefix edit: cannot write " + path)
        return 1
    print("ok " + path + " (" + String(applied) + " block(s) applied)")
    return 0


def main() raises:
    _ = external_call["shim_install_signal_handlers", c_int]()
    var a0 = argv()
    if len(a0) >= 2 and String(a0[1]) == "edit":
        if len(a0) == 3:
            external_call["exit", c_int](c_int(run_edit(String(a0[2]))))
        bindings.eprint("usage: idefix edit FILE   (reads SEARCH/REPLACE blocks on stdin)")
        external_call["exit", c_int](c_int(64))
    var cfg = parse_args()
    var st = TurnStats()
    st.start_s = bindings.now_seconds()

    # session dir: create it; on failure state features turn off. The
    # journal path clears too unless it is a --resume file elsewhere.
    if cfg.session_dir != "" and not bindings.mkdir_p(cfg.session_dir):
        cfg.session_dir = ""
        if cfg.resume_file == "":
            cfg.journal_path = ""
        bindings.eprint("[idefix] cannot create session dir; journal/status off")

    var system = SYSTEM_PROMPT
    var repo_docs = String("")
    if not cfg.bare:
        system += SYSTEM_SUFFIX
        var doc_names = List[String]("AGENTS.md", "CLAUDE.md", __list_literal__=NoneType())
        for nm in doc_names:
            try:
                var d = read_file(cfg.repo + "/" + nm)
                if String(d.strip()) != "":
                    repo_docs += "\n\n" + nm + ":\n" + d
            except:
                pass
    if cfg.instructions != "":
        repo_docs += "\n\n" + cfg.instructions
    if repo_docs != "":
        system += "\n\nRepository instructions:" + repo_docs

    var initial_history = (
        '{"role":"system","content":' + bindings.json_quote(system) + '}'
    )
    var history = initial_history
    var exit_code = 0

    var resume_src = cfg.resume_file
    if resume_src == "" and cfg.cont:
        resume_src = cfg.journal_path
    if resume_src != "":
        try:
            history = rebuild_history(read_file(resume_src), initial_history)
            # the journal replays pre-compaction outputs at full fidelity, so
            # files may have changed since they were produced; say so once
            history += ',{"role":"user","content":"session resumed; earlier tool outputs may describe an older repo state. Re-run commands before relying on them."}'
            bindings.eprint("[idefix] resumed from " + resume_src)
        except e:
            if cfg.resume_file != "":
                die("cannot read resume source: " + String(e), 64)
            bindings.eprint("[idefix] no prior session; starting fresh")
    elif cfg.cont:
        die("--continue needs a session dir (see --state-dir)", 64)

    journal(
        cfg,
        '{"ev":"run","ts":' + String(bindings.now_seconds())
        + ',"model":' + bindings.json_quote(cfg.model)
        + ',"repo":' + bindings.json_quote(cfg.repo) + "}",
    )

    if cfg.task != "":
        var umsg = '{"role":"user","content":' + bindings.json_quote(cfg.task) + '}'
        push_msg(cfg, history, umsg)
        var (final, code) = run_turn(cfg, history, st)
        exit_code = code
        if final == "" and exit_code == 0:
            final = "(no final answer)"
        if final != "" and exit_code == 0:
            var amsg = '{"role":"assistant","content":' + bindings.json_quote(final) + '}'
            push_msg(cfg, history, amsg)
        finish(cfg, history, st, final, exit_code)

    # REPL: one shared session; each stdin line is a task in context.
    var tty = bindings.stdin_is_tty()
    if tty:
        bindings.eprint("[idefix] interactive mode: /reset clears, /quit|/exit or Ctrl-D exits, !CMD runs a shell command")
    while True:
        if tty:
            bindings.prompt("idefix> ")
        var line = String("")
        try:
            line = bindings.read_line()
        except e:
            if String(e) != "eof":
                bindings.eprint("[idefix] stdin read error: " + String(e))
            break
        var t = String(line.strip())
        if t == "":
            continue
        if t == "/quit" or t == "/exit":
            break
        if t == "/reset":
            history = initial_history
            journal(
                cfg,
                '{"ev":"reset","ts":' + String(bindings.now_seconds()) + "}",
            )
            bindings.eprint("[idefix] context reset")
            continue
        if not cfg.bare and String(t[byte= : 1]) == "!":
            var shell_cmd = String(t[byte=1:])
            if shell_cmd == "":
                bindings.eprint("[idefix] !cmd: empty command")
                continue
            try:
                var rc = bindings.run_capture(
                    shell_cmd, cfg.repo, cfg.max_output_bytes, cfg.max_command_ms, False
                )
                print(rc[0])
                if rc[1] != 0:
                    bindings.eprint("[idefix] !exit " + String(rc[1]))
                journal(
                    cfg,
                    '{"ev":"shell","ts":' + String(bindings.now_seconds())
                    + ',"cmd":' + bindings.json_quote(shell_cmd)
                    + ',"exit":' + String(rc[1]) + "}",
                )
            except e:
                bindings.eprint("[idefix] exec failed: " + String(e))
            continue
        var umsg2 = '{"role":"user","content":' + bindings.json_quote(t) + '}'
        push_msg(cfg, history, umsg2)
        var (final, code) = run_turn(cfg, history, st)
        if final == "" and code == 0:
            final = "(no final answer)"
        if final != "" and code == 0:
            var amsg2 = '{"role":"assistant","content":' + bindings.json_quote(final) + '}'
            push_msg(cfg, history, amsg2)
        if final != "":
            print(final)
        if code != 0:
            bindings.eprint("[idefix] turn ended with exit " + String(code))
        exit_code = code
    finish(cfg, history, st, "", exit_code)
