# Minimal native coding agent: one bash tool, one task loop, MAX endpoint.

from std.ffi import external_call, c_int
from std.os import getenv
from std.sys import argv

import bindings


comptime SYSTEM_PROMPT = """You are a coding agent working inside a repository on the user's machine. You have one tool: bash(command), which runs /bin/bash -c in the repository directory and returns the exit code and bounded output.

Rules:
- Act through the tool. Do not describe commands; issue them.
- Inspect before editing: read files, then change them. Write files with here-docs or scripts; verify changes with diffs or tests.
- Fix the root cause; do not skip tests or add workarounds.
- When the task is verifiably done, reply with a short summary of what changed and how it was verified. Do not call the tool again."""


comptime TOOLS = '{"type":"function","function":{"name":"bash","description":"Run a bash command in the repository directory. Returns exit code and bounded merged stdout/stderr output.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"The bash command to run"}},"required":["command"],"additionalProperties":false}}}'


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
    var notify: String
    var state_root: String
    var session_dir: String
    var cont: Bool
    var resume_file: String
    var journal_path: String
    var bare: Bool

    def __init__(out self):
        self.repo = "."
        self.instructions = ""
        self.task = ""
        self.base_url = "http://127.0.0.1:8000/v1"
        self.model = ""
        self.bearer = ""
        self.max_requests = 40
        self.max_seconds = 1800
        self.max_command_ms = 120000
        self.max_output_bytes = 65536
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
        self.notify = ""
        self.state_root = ""
        self.session_dir = ""
        self.cont = False
        self.resume_file = ""
        self.journal_path = ""
        self.bare = False


def usage() -> String:
    return "usage: max --repo DIR [flags] [TASK]   (no TASK -> interactive REPL on stdin)\n  env: MAX_BASE_URL (default http://127.0.0.1:8000/v1), MAX_MODEL (required), MAX_API_KEY, MAX_STATE_DIR\n  flags: --instructions FILE --max-requests N --max-seconds N --max-command-seconds N --max-output-bytes N --max-http-bytes N --max-prompt-tokens N --temperature F --transcript FILE --max-calls-per-response N -v\n         --compact-at N --compact-keep N --retries N --no-loop-guard --notify CMD --state-dir DIR --continue --resume FILE --bare\n  state: journal + status under --state-dir | $MAX_STATE_DIR | $HOME/.max; --continue resumes this repo's session\n  REPL: shared context across lines; /reset clears, /quit|/exit or Ctrl-D exits, !CMD runs a shell command"


def read_file(path: String) raises -> String:
    var p = path
    var fp = external_call["fopen", bindings.FILE_ptr](
        p.as_c_string_span().ptr(), "rb".as_c_string_span().ptr()
    )
    if not fp:
        raise Error("cannot open " + path)
    _ = external_call["fseek", c_int](fp, c_int(0), c_int(2))
    var sz = external_call["ftell", c_int](fp)
    _ = external_call["fseek", c_int](fp, c_int(0), c_int(0))
    var buf = List[UInt8](capacity=Int(sz) + 1)
    buf.resize(Int(sz), 0)
    _ = external_call["fread", c_int](
        buf.unsafe_ptr(), c_int(1), c_int(sz), fp
    )
    _ = external_call["fclose", c_int](fp)
    return String(unsafe_from_utf8=buf^)


def die(msg: String, code: Int):
    bindings.eprint("[max] " + msg)
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
                cfg.temperature = Float64(v)
                cfg.has_temperature = True
            elif arg == "--notify":
                cfg.notify = v
            elif arg == "--state-dir":
                cfg.state_root = v
            elif arg == "--resume":
                cfg.resume_file = v
            else:
                die("unhandled flag: " + arg, 64)
        elif arg == "--max-requests":
            i += 1; cfg.max_requests = Int(String(a[i]))
        elif arg == "--max-seconds":
            i += 1; cfg.max_seconds = Int(String(a[i]))
        elif arg == "--max-command-seconds":
            i += 1; cfg.max_command_ms = Int(String(a[i])) * 1000
        elif arg == "--max-output-bytes":
            i += 1; cfg.max_output_bytes = Int(String(a[i]))
        elif arg == "--max-http-bytes":
            i += 1  # accepted; curl cap is fixed at 64MB in bindings
        elif arg == "--max-prompt-tokens":
            i += 1; cfg.max_prompt_tokens = Int(String(a[i]))
        elif arg == "--max-calls-per-response":
            i += 1; cfg.max_calls_per_response = Int(String(a[i]))
        elif arg == "--compact-at":
            i += 1; cfg.compact_at = Int(String(a[i]))
        elif arg == "--compact-keep":
            i += 1; cfg.compact_keep = Int(String(a[i]))
        elif arg == "--retries":
            i += 1; cfg.retries = Int(String(a[i]))
        elif arg == "--no-loop-guard":
            cfg.loop_guard = False
        elif arg == "--continue":
            cfg.cont = True
        elif arg == "--bare":
            cfg.bare = True
        elif arg == "-h" or arg == "--help":
            print(usage())
            _ = external_call["exit", c_int](c_int(0))
        else:
            positional.append(arg)
        i += 1
    if len(positional) > 0:
        cfg.task = positional[len(positional) - 1]
    # no TASK -> REPL mode (validated after env checks)
    var env_base = getenv("MAX_BASE_URL")
    if env_base != "":
        cfg.base_url = env_base
    cfg.model = getenv("MAX_MODEL")
    if cfg.model == "":
        die("MAX_MODEL is not set. " + usage(), 64)
    cfg.bearer = getenv("MAX_API_KEY")
    var acc = cfg.repo
    var accrc = external_call["access", c_int](acc.as_c_string_span().ptr(), c_int(0))
    if accrc != 0:
        die("repo path does not exist: " + cfg.repo, 64)
    if cfg.bare:
        # bench-compat mode: every behavior added after the original loop off
        cfg.compact_at = 0
        cfg.retries = 0
        cfg.loop_guard = False
        cfg.notify = ""
        cfg.cont = False
        cfg.resume_file = ""
    if cfg.state_root == "":
        cfg.state_root = getenv("MAX_STATE_DIR")
    if cfg.state_root == "":
        var home = getenv("HOME")
        if home != "":
            cfg.state_root = home + "/.max"
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
        bindings.eprint("[max] " + s)


def write_transcript(path: String, history: String):
    if path == "":
        return
    var ok = bindings.write_file(path, "[" + history + "]")
    if not ok:
        bindings.eprint("[max] failed to write transcript: " + path)


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
    var history = system_msg
    for line in journal_text.split("\n"):
        var s = String(line)
        if s.find('"ev":"reset"') >= 0:
            history = system_msg
            continue
        if s.find('"ev":"msg"') < 0:
            continue
        var j = bindings.cjson_parse(s)
        if not j:
            continue
        var m = bindings.cjson_get(j, "m")
        if m:
            var mj = bindings.cjson_print(m)
            history += "," + mj
        bindings.cjson_del(j)
    return history


def is_ctx_error(resp: String) -> Bool:
    return resp.find("context") >= 0 or resp.find("too long") >= 0



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
    var i = 0
    while i < cfg.max_requests:
        if bindings.now_seconds() > deadline:
            bindings.eprint("[max] --max-seconds exceeded")
            exit_code = 2
            break
        var req_ms = (deadline - bindings.now_seconds()) * 1000
        var r = bindings.http_post(
            cfg.base_url + "/chat/completions", build_body(cfg, history), cfg.bearer, max(req_ms, 1)
        )
        st.requests += 1
        var code = r[0]
        var resp = r[1]
        vlog(cfg, "request " + String(st.requests) + " -> http " + String(code))
        var attempt = 0
        while (code == 0 or code >= 500) and attempt < cfg.retries:
            # transport error or server 5xx: backoff retry for long runs
            if bindings.now_seconds() > deadline:
                break
            attempt += 1
            bindings.eprint(
                "[max] http " + String(code) + ": retry "
                + String(attempt) + "/" + String(cfg.retries)
            )
            journal(
                cfg,
                '{"ev":"retry","ts":' + String(bindings.now_seconds())
                + ',"attempt":' + String(attempt) + ',"http":' + String(code) + "}",
            )
            bindings.sleep_ms(1000 * (1 << (attempt - 1)))
            req_ms = (deadline - bindings.now_seconds()) * 1000
            r = bindings.http_post(
                cfg.base_url + "/chat/completions", build_body(cfg, history), cfg.bearer, max(req_ms, 1)
            )
            st.requests += 1
            code = r[0]
            resp = r[1]
        if code == 0 and bindings.now_seconds() > deadline:
            bindings.eprint("[max] --max-seconds exceeded")
            exit_code = 2
            break
        if code == 400 and is_ctx_error(resp):
            # context overflow: clear old tool output and retry this request once
            var (nh, cleared) = compact_history(history, cfg.compact_keep)
            if cleared > 0:
                history = nh
                bindings.eprint("[max] context overflow: compacted " + String(cleared) + " bytes")
                journal(
                    cfg,
                    '{"ev":"compact","ts":' + String(bindings.now_seconds())
                    + ',"cleared":' + String(cleared) + "}",
                )
                req_ms = (deadline - bindings.now_seconds()) * 1000
                r = bindings.http_post(
                    cfg.base_url + "/chat/completions", build_body(cfg, history), cfg.bearer, max(req_ms, 1)
                )
                st.requests += 1
                code = r[0]
                resp = r[1]
        if code != 200:
            bindings.eprint("[max] http " + String(code) + ": " + resp[byte= : min(resp.byte_length(), 300)])
            exit_code = 3
            break
        var root = bindings.cjson_parse(resp)
        if not root:
            bindings.eprint("[max] response is not JSON")
            exit_code = 3
            break
        write_status(cfg, st, "")
        var usage_ = bindings.cjson_get(root, "usage")
        if usage_:
            st.last_prompt_tokens = Int(bindings.cjson_num(bindings.cjson_get(usage_, "prompt_tokens")))
            st.total_prompt_tokens += st.last_prompt_tokens
            st.total_completion_tokens += Int(bindings.cjson_num(bindings.cjson_get(usage_, "completion_tokens")))
        var choices = bindings.cjson_get(root, "choices")
        if not choices or bindings.cjson_len(choices) == 0:
            bindings.eprint("[max] response has no choices")
            bindings.cjson_del(root)
            exit_code = 3
            break
        var choice0 = bindings.cjson_arr(choices, 0)
        var fr = bindings.cjson_str(bindings.cjson_get(choice0, "finish_reason"))
        if fr == "length":
            bindings.eprint("[max] warning: finish_reason=length (truncated)")
        var msg = bindings.cjson_get(choice0, "message")
        if not msg:
            bindings.cjson_del(root)
            bindings.eprint("[max] response has no message")
            exit_code = 3
            break
        var calls = bindings.cjson_get(msg, "tool_calls")
        var content = bindings.strip_think(
            bindings.cjson_str(bindings.cjson_get(msg, "content"))
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
                asst = '{"role":"assistant"'
                var cont = bindings.cjson_get(msg, "content")
                if cont:
                    var cj = bindings.cjson_print(cont)
                    if cj != "null":
                        asst += ',"content":' + cj
                asst += ',"tool_calls":' + bindings.cjson_print(calls) + "}"
            push_msg(cfg, history, asst)
            var n = bindings.cjson_len(calls)
            if n > cfg.max_calls_per_response:
                n = cfg.max_calls_per_response
            for j in range(n):
                var call = bindings.cjson_arr(calls, j)
                var cid = bindings.cjson_str(bindings.cjson_get(call, "id"))
                var fn_ = bindings.cjson_get(call, "function")
                var name = bindings.cjson_str(bindings.cjson_get(fn_, "name"))
                var argsj = bindings.cjson_str(bindings.cjson_get(fn_, "arguments"))
                var result = String("")
                if name != "bash":
                    result = '{"error":"unknown tool: ' + name + '"}'
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
                                    st.last_cmd = cmd
                                    st.cmd_repeats = 0
                            var rc = bindings.run_capture(
                                cmd, cfg.repo, cfg.max_output_bytes, cfg.max_command_ms
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
                                    + String(count) + ' times in a row"'
                                )
                                journal(
                                    cfg,
                                    '{"ev":"loop","ts":' + String(bindings.now_seconds())
                                    + ',"cmd":' + bindings.json_quote(cmd)
                                    + ',"count":' + String(count) + "}",
                                )
                            result += "}"
                        bindings.cjson_del(aj)
                push_msg(cfg, history, tool_msg(cid, result))
            # fill unexecuted calls beyond cap with error results
            var total = bindings.cjson_len(calls)
            for j in range(n, total):
                var call = bindings.cjson_arr(calls, j)
                var cid = bindings.cjson_str(bindings.cjson_get(call, "id"))
                push_msg(
                    cfg, history,
                    tool_msg(cid, '{"error":"call limit reached; not executed"}')
                )
        else:
            final = content
            bindings.cjson_del(root)
            exit_code = 0
            break
        if msg_owner:
            bindings.cjson_del(msg_owner)
        bindings.cjson_del(root)
        if bindings.now_seconds() > deadline:
            bindings.eprint("[max] --max-seconds exceeded")
            exit_code = 2
            break
        if cfg.max_prompt_tokens > 0 and st.last_prompt_tokens > cfg.max_prompt_tokens:
            bindings.eprint("[max] --max-prompt-tokens exceeded")
            exit_code = 2
            break
        if cfg.compact_at > 0 and st.last_prompt_tokens > cfg.compact_at:
            var (nh, cleared) = compact_history(history, cfg.compact_keep)
            if cleared > 0:
                history = nh
                bindings.eprint(
                    "[max] prompt_tokens=" + String(st.last_prompt_tokens)
                    + " over --compact-at " + String(cfg.compact_at)
                    + ": cleared " + String(cleared) + " bytes of old tool output"
                )
                journal(
                    cfg,
                    '{"ev":"compact","ts":' + String(bindings.now_seconds())
                    + ',"cleared":' + String(cleared) + "}",
                )
        i += 1
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
            _ = bindings.run_capture(cfg.notify, cfg.repo, 8192, 30000)
        except:
            pass
    bindings.eprint(
        "[max] requests=" + String(st.requests)
        + " commands=" + String(st.commands)
        + " prompt_tokens=" + String(st.last_prompt_tokens)
        + " tokens=" + String(st.total_prompt_tokens) + "+" + String(st.total_completion_tokens)
        + " elapsed=" + String(bindings.now_seconds() - st.start_s) + "s"
        + " exit=" + String(code)
    )
    if final != "":
        print(final)
    external_call["exit", c_int](c_int(code))


def main() raises:
    _ = external_call["shim_install_signal_handlers", c_int]()
    var cfg = parse_args()
    var st = TurnStats()
    st.start_s = bindings.now_seconds()

    # session dir: create it; on failure state features quietly turn off
    if cfg.session_dir != "" and not bindings.mkdir_p(cfg.session_dir):
        cfg.session_dir = ""

    var system = SYSTEM_PROMPT
    var repo_docs = String("")
    if not cfg.bare:
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

    # resume: replay msg events from a journal into history
    var resume_src = cfg.resume_file
    if resume_src == "" and cfg.cont:
        resume_src = cfg.journal_path
    if resume_src != "":
        try:
            history = rebuild_history(read_file(resume_src), initial_history)
            bindings.eprint("[max] resumed from " + resume_src)
        except e:
            if cfg.resume_file != "":
                die("cannot read resume source: " + String(e), 64)
            bindings.eprint("[max] no prior session; starting fresh")
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
        bindings.eprint("[max] interactive mode: /reset clears, /quit|/exit or Ctrl-D exits, !CMD runs a shell command")
    while True:
        if tty:
            bindings.prompt("max> ")
        var line = String("")
        try:
            line = bindings.read_line()
        except e:
            if String(e) != "eof":
                bindings.eprint("[max] stdin read error: " + String(e))
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
            bindings.eprint("[max] context reset")
            continue
        if not cfg.bare and t.byte_length() > 1 and String(t[byte= : 1]) == "!":
            var shell_cmd = String(t[byte=1:])
            try:
                var rc = bindings.run_capture(
                    shell_cmd, cfg.repo, cfg.max_output_bytes, cfg.max_command_ms
                )
                print(rc[0])
                if rc[1] != 0:
                    bindings.eprint("[max] !exit " + String(rc[1]))
                journal(
                    cfg,
                    '{"ev":"shell","ts":' + String(bindings.now_seconds())
                    + ',"cmd":' + bindings.json_quote(shell_cmd)
                    + ',"exit":' + String(rc[1]) + "}",
                )
            except e:
                bindings.eprint("[max] exec failed: " + String(e))
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
            bindings.eprint("[max] turn ended with exit " + String(code))
        exit_code = code
    finish(cfg, history, st, "", exit_code)
