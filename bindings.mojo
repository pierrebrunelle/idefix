# Thin FFI layer: libcurl POST, cJSON access, POSIX exec with bounds.

from std.ffi import external_call, c_char, c_int, c_long, c_size_t, c_ssize_t
from std.ffi.cstring import CStringSpan

comptime raw_ptr = OptionalPointer[NoneType, UntrackedOrigin[mut=True]]
comptime cstr_ptr = OptionalPointer[UInt8, ImmUntrackedOrigin]
comptime FILE_ptr = OptionalPointer[NoneType, UntrackedOrigin[mut=True]]

comptime CURLOPT_WRITEDATA = 10001
comptime CURLOPT_URL = 10002
comptime CURLOPT_TIMEOUT_MS = 155
comptime CURLOPT_POST = 47
comptime CURLOPT_POSTFIELDS = 10015
comptime CURLOPT_POSTFIELDSIZE = 60
comptime CURLOPT_HTTPHEADER = 10023
comptime CURLOPT_MAXFILESIZE_LARGE = 30117
comptime CURLINFO_RESPONSE_CODE = 0x200000 + 2

comptime WNOHANG = 1
comptime SIGKILL = 9
comptime SIGTERM = 15
comptime POLLIN = 0x0001
comptime POLLHUP = 0x0010
comptime POLLERR = 0x0008
comptime POLLNVAL = 0x0020


def eprint(s: String):
    var t = s
    var fmt = "%s\n"
    _ = external_call["dprintf", c_int, num_fixed_args=2](
        c_int(2), fmt.as_c_string_span().ptr(), t.as_c_string_span().ptr()
    )


def json_quote(s: String) -> String:
    var out = String('"')
    for i in range(s.byte_length()):
        var b = Int(s.as_bytes()[i])
        if b == 0x22 or b == 0x5C:
            out += String('\\') + String(chr(b))
        elif b == 0x0A:
            out += "\\n"
        elif b == 0x0D:
            out += "\\r"
        elif b == 0x09:
            out += "\\t"
        elif b < 0x20:
            out += "\\u00" + hex(b)[byte=2:]
        else:
            out += String(chr(b))
    return out + '"'


def http_post(url: String, body: String, bearer: String) raises -> Tuple[Int, String]:
    var u = url
    var b = body
    var h = external_call["curl_easy_init", raw_ptr]()
    if not h:
        raise Error("curl_easy_init failed")
    var hdr = "Content-Type: application/json"
    var slist = external_call["curl_slist_append", raw_ptr](
        raw_ptr(), hdr.as_c_string_span().ptr()
    )
    if bearer != "":
        var auth = "Authorization: Bearer " + bearer
        slist = external_call["curl_slist_append", raw_ptr](
            slist, auth.as_c_string_span().ptr()
        )
    _ = external_call["curl_easy_setopt", c_int, num_fixed_args=2](
        h, c_int(CURLOPT_URL), u.as_c_string_span().ptr()
    )
    _ = external_call["curl_easy_setopt", c_int, num_fixed_args=2](
        h, c_int(CURLOPT_POST), c_long(1)
    )
    var bc = b.as_c_string_span()
    _ = external_call["curl_easy_setopt", c_int, num_fixed_args=2](
        h, c_int(CURLOPT_POSTFIELDS), bc.ptr()
    )
    _ = external_call["curl_easy_setopt", c_int, num_fixed_args=2](
        h, c_int(CURLOPT_POSTFIELDSIZE), c_long(b.byte_length())
    )
    _ = external_call["curl_easy_setopt", c_int, num_fixed_args=2](
        h, c_int(CURLOPT_HTTPHEADER), slist
    )
    _ = external_call["curl_easy_setopt", c_int, num_fixed_args=2](
        h, c_int(CURLOPT_TIMEOUT_MS), c_long(120000)
    )
    _ = external_call["curl_easy_setopt", c_int, num_fixed_args=2](
        h, c_int(CURLOPT_MAXFILESIZE_LARGE), c_long(64 * 1024 * 1024)
    )
    var rbuf = cstr_ptr()
    var rsize: UInt = 0
    var fp = external_call["open_memstream", FILE_ptr](
        Pointer(to=rbuf), Pointer(to=rsize)
    )
    if not fp:
        _ = external_call["curl_easy_cleanup", c_int](h)
        raise Error("open_memstream failed")
    _ = external_call["curl_easy_setopt", c_int, num_fixed_args=2](
        h, c_int(CURLOPT_WRITEDATA), fp
    )
    var perf = external_call["curl_easy_perform", c_int](h)
    _ = external_call["fclose", c_int](fp)
    var code: Int = 0
    _ = external_call["curl_easy_getinfo", c_int, num_fixed_args=2](
        h, c_int(CURLINFO_RESPONSE_CODE), Pointer(to=code)
    )
    _ = external_call["curl_slist_free_all", c_int](slist)
    _ = external_call["curl_easy_cleanup", c_int](h)
    if perf != 0:
        return 0, "CURL_ERROR:" + String(Int(perf))
    if not rbuf:
        return code, ""
    var resp = String(unsafe_from_utf8_ptr=rbuf.value())
    _ = external_call["free", c_int](rbuf.value())
    return code, resp^


def cjson_parse(s: String) -> raw_ptr:
    var t = s
    return external_call["cJSON_Parse", raw_ptr](t.as_c_string_span())


def cjson_get(obj: raw_ptr, key: String) -> raw_ptr:
    var k = key
    return external_call["cJSON_GetObjectItemCaseSensitive", raw_ptr](
        obj, k.as_c_string_span()
    )


def cjson_str(item: raw_ptr) -> String:
    var p = external_call["cJSON_GetStringValue", cstr_ptr](item)
    if not p:
        return ""
    return String(unsafe_from_utf8_ptr=p.value())


def cjson_num(item: raw_ptr) -> Float64:
    return external_call["cJSON_GetNumberValue", Float64](item)


def cjson_print(item: raw_ptr) -> String:
    var p = external_call["cJSON_PrintUnformatted", cstr_ptr](item)
    if not p:
        return ""
    var s = String(unsafe_from_utf8_ptr=p.value())
    _ = external_call["cJSON_free", c_int](p.value())
    return s


def cjson_arr(obj: raw_ptr, i: Int) -> raw_ptr:
    return external_call["cJSON_GetArrayItem", raw_ptr](obj, c_int(i))


def cjson_len(obj: raw_ptr) -> Int:
    return Int(external_call["cJSON_GetArraySize", c_int](obj))


def cjson_del(p: raw_ptr):
    _ = external_call["cJSON_Delete", c_int](p)


def strip_think(content: String) -> String:
    # Drop <think>...</think> reasoning regions; an unclosed tag truncates.
    var out = content
    while True:
        var a = out.find("<think>")
        if a < 0:
            return out
        var b = out.find("</think>")
        if b < 0:
            return String(out[byte= : a])
        out = String(out[byte= : a]) + String(out[byte=b + 8 :])


def markup_calls_json(content: String) -> String:
    # Models without a server-side tool parser emit hermes-style
    # <tool_call>{"name":..,"arguments":{..}}</tool_call> markup in content.
    # Returns a comma-separated list of OpenAI tool_call objects, or "".
    var pos = 0
    var out = ""
    var n = 0
    while pos < content.byte_length():
        var a = content[byte=pos:].find("<tool_call>")
        if a < 0:
            break
        var start = pos + a + 11
        var b = content[byte=start:].find("</tool_call>")
        if b < 0:
            break
        var inner = String(content[byte=start : start + b])
        pos = start + b + 12
        var name = String("")
        var argstr = String("")
        var aj = cjson_parse(inner)
        if aj:
            name = cjson_str(cjson_get(aj, "name"))
            var arg_item = cjson_get(aj, "arguments")
            argstr = cjson_str(arg_item)
            if argstr == "" and arg_item:
                argstr = cjson_print(arg_item)
            cjson_del(aj)
        else:
            # Degraded form: "<name>\n<arg string or object>".
            var t = inner.strip()
            var nl = t.find("\n")
            if nl < 0:
                continue
            name = String(t[byte= : nl])
            var rest = String(t[byte=nl + 1 :])
            var rj = cjson_parse(rest)
            if rj:
                var rv = cjson_str(rj)
                if rv != "":
                    argstr = rv
                else:
                    argstr = cjson_print(rj)
                cjson_del(rj)
            else:
                argstr = rest
                var L = argstr.byte_length()
                if L >= 2 and argstr.find('"') == 0 and String(argstr[byte=L - 1 : L]) == '"':
                    var unq = String(argstr[byte=1 : L - 1])
                    argstr = unq^
        if name == "":
            continue
        if argstr == "" or argstr.find("{") != 0:
            argstr = '{"command":' + json_quote(argstr) + "}"
        if out != "":
            out += ","
        out += (
            '{"id":"call_mk' + String(n)
            + '","type":"function","function":{"name":' + json_quote(name)
            + ',"arguments":' + json_quote(argstr) + "}}"
        )
        n += 1
    return out


def now_seconds() -> Int:
    return Int(external_call["time", c_long](raw_ptr()))


def write_file(path: String, contents: String) -> Bool:
    var p = path
    var c = contents
    var fp = external_call["fopen", FILE_ptr](
        p.as_c_string_span().ptr(), "w".as_c_string_span().ptr()
    )
    if not fp:
        return False
    var cs = c.as_c_string_span()
    _ = external_call["fwrite", c_size_t](
        cs.ptr(), c_size_t(1), c_size_t(c.byte_length()), fp
    )
    _ = external_call["fclose", c_int](fp)
    return True


def c_argv(mut args: List[String]) raises -> raw_ptr:
    var ptrs = List[UInt64]()
    for i in range(len(args)):
        ptrs.append(UInt64(Int(args[i].as_c_string_span().ptr())))
    ptrs.append(0)
    var mem = external_call["calloc", raw_ptr](c_size_t(len(args) + 1), c_size_t(8))
    if not mem:
        raise Error("calloc failed")
    var p64 = mem.value().unsafe_bitcast[UInt64]()
    for i in range(len(ptrs)):
        p64.unsafe_store(i, ptrs[i])
    return mem


def run_capture(
    command: String, cwd: String, cap: Int, timeout_ms: Int
) raises -> Tuple[String, Int, Int]:
    var args = List[String]("/bin/bash", "-c", command, __list_literal__=NoneType())
    var argv = c_argv(args)
    var fds_mem = external_call["calloc", raw_ptr](c_size_t(2), c_size_t(4))
    var pi = fds_mem.value().unsafe_bitcast[c_int]()
    if external_call["pipe", c_int](pi) != 0:
        raise Error("pipe failed")
    var rfd = pi.unsafe_load(0)
    var wfd = pi.unsafe_load(1)
    _ = external_call["free", c_int](fds_mem.value())
    var pid = external_call["fork", c_int]()
    if pid == 0:
        _ = external_call["setpgid", c_int](c_int(0), c_int(0))
        _ = external_call["dup2", c_int](wfd, c_int(1))
        _ = external_call["dup2", c_int](wfd, c_int(2))
        _ = external_call["close", c_int](rfd)
        var devnull = "/dev/null"
        var dn = external_call["open", c_int, num_fixed_args=2](
            devnull.as_c_string_span().ptr(), c_int(0)
        )
        _ = external_call["dup2", c_int](dn, c_int(0))
        var dir = cwd
        _ = external_call["chdir", c_int](dir.as_c_string_span().ptr())
        var bash = "/bin/bash"
        _ = external_call["execv", c_int](bash.as_c_string_span().ptr(), argv)
        _ = external_call["_exit", c_int](c_int(127))
    _ = external_call["shim_track_pgid", c_int](pid)
    _ = external_call["close", c_int](wfd)
    var head_cap = cap // 2
    var tail_cap = cap - head_cap
    var head = List[UInt8]()
    var tail = List[UInt8]()
    var discarded = 0
    var buf = List[UInt8](capacity=8192)
    buf.resize(8192, 0)
    var pfd_mem = external_call["calloc", raw_ptr](c_size_t(1), c_size_t(8))
    var pfd32 = pfd_mem.value().unsafe_bitcast[Int32]()
    var pfd16 = pfd_mem.value().unsafe_bitcast[Int16]()
    var status: c_int = 0
    var timed_out = False
    var child_done = False
    var elapsed_ms = 0
    var post_done_ms = 0
    while True:
        pfd32.unsafe_store(0, Int32(rfd))
        pfd16.unsafe_store(2, Int16(POLLIN))
        pfd16.unsafe_store(3, Int16(0))
        var pr = external_call["poll", c_int](pfd_mem.value(), c_int(1), c_int(50))
        if pr < 0:
            break
        var rev = Int(pfd16.unsafe_load(3)) & 0xFFFF
        if pr > 0 and (rev & POLLIN) != 0:
            var n = external_call["read", c_ssize_t](
                rfd, buf.unsafe_ptr(), c_size_t(8192)
            )
            var start = 0
            if n > 0:
                if len(head) < head_cap:
                    var take = min(head_cap - len(head), Int(n))
                    for i in range(take):
                        head.append(buf[i])
                    start = take
                for i in range(start, Int(n)):
                    tail.append(buf[i])
                while len(tail) > tail_cap:
                    _ = tail.pop(0)
                    discarded += 1
            else:
                break
        elif pr > 0 and (rev & (POLLHUP | POLLERR | POLLNVAL)) != 0:
            break
        if not child_done:
            var w = external_call["waitpid", c_int](
                pid, Pointer(to=status), c_int(WNOHANG)
            )
            if w == pid:
                child_done = True
            else:
                if pr == 0:
                    elapsed_ms += 50
                if elapsed_ms > timeout_ms:
                    timed_out = True
                    _ = external_call["kill", c_int](c_int(-pid), c_int(SIGTERM))
                    _ = external_call["usleep", c_int](c_int(200000))
                    _ = external_call["kill", c_int](c_int(-pid), c_int(SIGKILL))
                    _ = external_call["waitpid", c_int](
                        pid, Pointer(to=status), c_int(0)
                    )
                    child_done = True
        else:
            post_done_ms += 50
            if post_done_ms > 3000:
                break
    _ = external_call["close", c_int](rfd)
    _ = external_call["free", c_int](pfd_mem.value())
    _ = external_call["free", c_int](argv.value())
    if not child_done:
        _ = external_call["waitpid", c_int](pid, Pointer(to=status), c_int(0))
    _ = external_call["shim_track_pgid", c_int](c_int(0))
    var code = (Int(status) >> 8) & 0xFF
    if timed_out:
        code = 124
    var out = String(unsafe_from_utf8=head^) + String(unsafe_from_utf8=tail^)
    return out^, code, discarded
