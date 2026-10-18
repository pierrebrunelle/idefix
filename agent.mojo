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


def usage() -> String:
    return "usage: agent --repo DIR [flags] TASK\n  env: MAX_BASE_URL (default http://127.0.0.1:8000/v1), MAX_MODEL (required), MAX_API_KEY\n  flags: --instructions FILE --max-requests N --max-seconds N --max-command-seconds N --max-output-bytes N --max-http-bytes N --max-prompt-tokens N --temperature F --transcript FILE --max-calls-per-response N -v"


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
    bindings.eprint("[agent] " + msg)
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
        elif arg == "--repo" or arg == "--instructions" or arg == "--transcript" or arg == "--temperature":
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
            else:
                cfg.temperature = Float64(v)
                cfg.has_temperature = True
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
        elif arg == "-h" or arg == "--help":
            die(usage(), 0)
        else:
            positional.append(arg)
        i += 1
    if len(positional) == 0:
        die("missing TASK. " + usage(), 64)
    cfg.task = positional[len(positional) - 1]
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
    if cfg.instructions != "":
        try:
            cfg.instructions = read_file(cfg.instructions)
        except e:
            die("cannot read instructions file: " + String(e), 64)
    return cfg^


def vlog(cfg: Config, s: String):
    if cfg.verbose:
        bindings.eprint("[agent] " + s)


def write_transcript(path: String, history: String):
    if path == "":
        return
    var ok = bindings.write_file(path, "[" + history + "]")
    if not ok:
        bindings.eprint("[agent] failed to write transcript: " + path)


def main() raises:
    _ = external_call["shim_install_signal_handlers", c_int]()
    var cfg = parse_args()
    var system = SYSTEM_PROMPT
    if cfg.instructions != "":
        system += "\n\nRepository instructions:\n" + cfg.instructions
    var history = (
        '{"role":"system","content":'
        + bindings.json_quote(system)
        + '},{"role":"user","content":'
        + bindings.json_quote(cfg.task)
        + '}'
    )
    var deadline = bindings.now_seconds() + cfg.max_seconds
    var exit_code = 0
    var final = ""
    var prompt_tokens = 0
    var commands = 0
    var requests = 0
    var i = 0
    while i < cfg.max_requests:
        var temp = String("")
        if cfg.has_temperature:
            temp = ',"temperature":' + String(cfg.temperature)
        var body = (
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
        var r = bindings.http_post(cfg.base_url + "/chat/completions", body, cfg.bearer)
        requests += 1
        var code = r[0]
        var resp = r[1]
        vlog(cfg, "request " + String(requests) + " -> http " + String(code))
        if code == 0:
            # transport error: one retry
            r = bindings.http_post(cfg.base_url + "/chat/completions", body, cfg.bearer)
            code = r[0]
            resp = r[1]
        if code != 200:
            bindings.eprint("[agent] http " + String(code) + ": " + resp[byte= : min(resp.byte_length(), 300)])
            exit_code = 3
            break
        var root = bindings.cjson_parse(resp)
        if not root:
            bindings.eprint("[agent] response is not JSON")
            exit_code = 3
            break
        var usage_ = bindings.cjson_get(root, "usage")
        if usage_:
            prompt_tokens = Int(bindings.cjson_num(bindings.cjson_get(usage_, "prompt_tokens")))
        var choices = bindings.cjson_get(root, "choices")
        if not choices or bindings.cjson_len(choices) == 0:
            bindings.eprint("[agent] response has no choices")
            bindings.cjson_del(root)
            exit_code = 3
            break
        var choice0 = bindings.cjson_arr(choices, 0)
        var fr = bindings.cjson_str(bindings.cjson_get(choice0, "finish_reason"))
        if fr == "length":
            bindings.eprint("[agent] warning: finish_reason=length (truncated)")
        var msg = bindings.cjson_get(choice0, "message")
        if not msg:
            bindings.cjson_del(root)
            bindings.eprint("[agent] response has no message")
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
            history += "," + asst
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
                        if cmd == "":
                            result = '{"error":"missing or empty command"}'
                        else:
                            commands += 1
                            vlog(cfg, "bash: " + cmd[byte= : min(cmd.byte_length(), 120)])
                            var rc = bindings.run_capture(
                                cmd, cfg.repo, cfg.max_output_bytes, cfg.max_command_ms
                            )
                            result = (
                                '{"exit_code":'
                                + String(rc[1])
                                + ',"output":'
                                + bindings.json_quote(rc[0])
                                + ',"discarded_bytes":'
                                + String(rc[2])
                                + "}"
                            )
                        bindings.cjson_del(aj)
                history += (
                    ',{"role":"tool","tool_call_id":'
                    + bindings.json_quote(cid)
                    + ',"content":'
                    + bindings.json_quote(result)
                    + "}"
                )
            # fill unexecuted calls beyond cap with error results
            var total = bindings.cjson_len(calls)
            for j in range(n, total):
                var call = bindings.cjson_arr(calls, j)
                var cid = bindings.cjson_str(bindings.cjson_get(call, "id"))
                history += (
                    ',{"role":"tool","tool_call_id":'
                    + bindings.json_quote(cid)
                    + ',"content":'
                    + bindings.json_quote('{"error":"call limit reached; not executed"}')
                    + "}"
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
            bindings.eprint("[agent] --max-seconds exceeded")
            exit_code = 2
            break
        if cfg.max_prompt_tokens > 0 and prompt_tokens > cfg.max_prompt_tokens:
            bindings.eprint("[agent] --max-prompt-tokens exceeded")
            exit_code = 2
            break
        i += 1
    else:
        exit_code = 2
    if final == "" and exit_code == 0:
        final = "(no final answer)"
    write_transcript(cfg.transcript, history)
    bindings.eprint(
        "[agent] requests=" + String(requests)
        + " commands=" + String(commands)
        + " prompt_tokens=" + String(prompt_tokens)
        + " exit=" + String(exit_code)
    )
    print(final)
    external_call["exit", c_int](c_int(exit_code))
