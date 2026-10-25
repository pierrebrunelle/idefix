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
comptime CURLOPT_WRITEFUNCTION = 20011
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
    # Escapes ", \, control chars. Valid multibyte UTF-8 passes through;
    # invalid sequences become U+FFFD so binary tool output can't poison
    # the request body's UTF-8.
    var out = List[UInt8]()
    out.append(0x22)
    var bs = s.as_bytes()
    var i = 0
    while i < s.byte_length():
        var b = Int(bs[i])
        if b < 0x80:
            if b == 0x22 or b == 0x5C:
                out.append(0x5C)
                out.append(UInt8(b))
            elif b == 0x0A:
                out.append(0x5C); out.append(0x6E)
            elif b == 0x0D:
                out.append(0x5C); out.append(0x72)
            elif b == 0x09:
                out.append(0x5C); out.append(0x74)
            elif b < 0x20:
                var e = String("\\u00")
                if b < 16:
                    e += "0"
                e += String(hex(b)[byte=2:])
                for j in range(e.byte_length()):
                    out.append(e.as_bytes()[j])
            else:
                out.append(UInt8(b))
            i += 1
            continue
        var seqlen = 0
        if b >= 0xC2 and b <= 0xDF:
            seqlen = 2
        elif b >= 0xE0 and b <= 0xEF:
            seqlen = 3
        elif b >= 0xF0 and b <= 0xF4:
            seqlen = 4
        var ok = seqlen > 0 and i + seqlen <= s.byte_length()
        if ok:
            var b1 = Int(bs[i + 1])
            ok = b1 >= 0x80 and b1 <= 0xBF
            # E0/ED/F0/F4 tighten the first continuation range to exclude
            # overlongs, surrogates, and values past U+10FFFF.
            if ok and b == 0xE0:
                ok = b1 >= 0xA0
            elif ok and b == 0xED:
                ok = b1 <= 0x9F
            elif ok and b == 0xF0:
                ok = b1 >= 0x90
            elif ok and b == 0xF4:
                ok = b1 <= 0x8F
            for j in range(2, seqlen):
                var bj = Int(bs[i + j])
                if bj < 0x80 or bj > 0xBF:
                    ok = False
        if ok:
            for j in range(seqlen):
                out.append(bs[i + j])
            i += seqlen
        else:
            out.append(0xEF)
            out.append(0xBF)
            out.append(0xBD)
            i += 1
    out.append(0x22)
    return String(unsafe_from_utf8=out^)


def http_post(
    url: String,
    body: String,
    bearer: String,
    timeout_ms: Int = 600000,
    max_bytes: Int = 0,
) raises -> Tuple[Int, String]:
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
        h, c_int(CURLOPT_TIMEOUT_MS), c_long(timeout_ms)
    )
    if max_bytes > 0:
        _ = external_call["curl_easy_setopt", c_int, num_fixed_args=2](
            h, c_int(CURLOPT_MAXFILESIZE_LARGE), c_long(max_bytes)
        )
    # The shim write callback is a second bound on the response body:
    # MAXFILESIZE relies on libcurl internals (bytecount tracking) that
    # older libcurls only applied with a known Content-Length.
    _ = external_call["shim_http_cap", c_int](c_size_t(max_bytes))
    var wcb = external_call["shim_write_cb_ptr", raw_ptr]()
    _ = external_call["curl_easy_setopt", c_int, num_fixed_args=2](
        h, c_int(CURLOPT_WRITEFUNCTION), wcb
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
        if rbuf:
            _ = external_call["free", c_int](rbuf.value())
        var msg = "CURL_ERROR:" + String(Int(perf))
        # 63 = CURLE_FILESIZE_EXCEEDED (MAXFILESIZE, Content-Length path);
        # shim_http_capped = our write callback (chunked path). Both mean
        # the --max-http-bytes cap fired.
        if Int(perf) == 63 or external_call["shim_http_capped", c_int]() != 0:
            msg += " (response exceeds --max-http-bytes)"
        return 0, msg
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
    # cJSON_GetNumberValue returns NaN for missing/non-number items; callers
    # Int() the result, so give them 0 instead of NaN.
    var v = external_call["cJSON_GetNumberValue", Float64](item)
    if v != v:
        return 0.0
    return v


def cjson_print(item: raw_ptr) -> String:
    var p = external_call["cJSON_PrintUnformatted", cstr_ptr](item)
    if not p:
        return ""
    var s = String(unsafe_from_utf8_ptr=p.value())
    _ = external_call["cJSON_free", c_int](p.value())
    return s


def cjson_replace_str(obj: raw_ptr, key: String, new_str: String) -> Bool:
    var k = key
    var v = new_str
    var node = external_call["cJSON_CreateString", raw_ptr](
        v.as_c_string_span().ptr()
    )
    if not node:
        return False
    return external_call["cJSON_ReplaceItemInObject", c_int](
        obj, k.as_c_string_span().ptr(), node
    ) != 0


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
        var trimmed = String(argstr.strip())
        if trimmed.find("{") == 0:
            argstr = trimmed
        else:
            argstr = '{"command":' + json_quote(trimmed) + "}"
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


def now_ms() -> Int:
    # gettimeofday into a 16-byte timeval; ms resolution for timeouts.
    var tv = List[UInt8](capacity=16)
    tv.resize(16, 0)
    _ = external_call["gettimeofday", c_int, num_fixed_args=2](
        tv.unsafe_ptr(), raw_ptr()
    )
    var p64 = tv.unsafe_ptr().unsafe_bitcast[Int64]()
    return Int(p64.unsafe_load(0)) * 1000 + Int(p64.unsafe_load(1)) // 1000


def stdin_is_tty() -> Bool:
    return external_call["isatty", c_int](c_int(0)) != 0


def prompt(s: String):
    # fd 2: stderr keeps stdout pipeable for piped consumers.
    var t = s
    var fmt = "%s"
    _ = external_call["dprintf", c_int, num_fixed_args=2](
        c_int(2), fmt.as_c_string_span().ptr(), t.as_c_string_span().ptr()
    )


def read_line() raises -> String:
    # Raises "eof" at end of input, "read error" on a stdin failure; an
    # empty line returns "".
    var p = external_call["shim_read_line", cstr_ptr]()
    if not p:
        if external_call["shim_stdin_error", c_int]() != 0:
            raise Error("read error")
        raise Error("eof")
    return String(unsafe_from_utf8_ptr=p.value())


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


def mkdir_p(path: String, mode: Int = 0o700) -> Bool:
    # mkdir -p: create each '/'-separated prefix, then verify the path exists.
    var pp = path
    for i in range(1, path.byte_length() + 1):
        if i != path.byte_length() and Int(path.as_bytes()[i]) != 0x2F:
            continue
        var pre = String(path[byte= : i])
        _ = external_call["mkdir", c_int, num_fixed_args=2](
            pre.as_c_string_span().ptr(), c_int(mode)
        )
    return external_call["access", c_int](
        pp.as_c_string_span().ptr(), c_int(0)
    ) == 0


def append_file(path: String, contents: String) -> Bool:
    var p = path
    var c = contents
    var fp = external_call["fopen", FILE_ptr](
        p.as_c_string_span().ptr(), "a".as_c_string_span().ptr()
    )
    if not fp:
        return False
    var cs = c.as_c_string_span()
    _ = external_call["fwrite", c_size_t](
        cs.ptr(), c_size_t(1), c_size_t(c.byte_length()), fp
    )
    _ = external_call["fclose", c_int](fp)
    return True


def is_dir(path: String) -> Bool:
    var p = path
    var d = external_call["opendir", raw_ptr](p.as_c_string_span().ptr())
    if not d:
        return False
    _ = external_call["closedir", c_int](d.value())
    return True


def realpath(path: String) -> String:
    var p = path
    var buf = external_call["calloc", raw_ptr](c_size_t(4096), c_size_t(1))
    if not buf:
        return path
    var r = external_call["realpath", cstr_ptr](
        p.as_c_string_span().ptr(), buf.value()
    )
    var out = path
    if r:
        out = String(unsafe_from_utf8_ptr=r.value())
    _ = external_call["free", c_int](buf.value())
    return out


def fnv1a_hex(s: String) -> String:
    var h: UInt64 = 14695981039346656037
    for i in range(s.byte_length()):
        h = (h ^ UInt64(Int(s.as_bytes()[i]))) * 1099511628211
    var out = String("")
    var v = h
    for _ in range(16):
        var nib = Int(v & 15)
        var c = String(chr(48 + nib)) if nib < 10 else String(chr(87 + nib))
        out = c + out
        v = v >> 4
    return out


def sleep_ms(ms: Int):
    # usleep's useconds_t is 32-bit; clamp so ms*1000 cannot overflow it.
    var m = min(ms, 2_000_000)
    if m > 0:
        _ = external_call["usleep", c_int](c_int(m * 1000))


def strip_markup(content: String) -> String:
    # Drop <tool_call>...</tool_call> regions for display; an unclosed tag
    # truncates. The wire copy keeps the markup for markup_calls_json().
    var out = content
    while True:
        var a = out.find("<tool_call>")
        if a < 0:
            return String(out.strip())
        var b = out.find("</tool_call>")
        if b < 0:
            return String(out[byte= : a].strip())
        out = String(out[byte= : a]) + String(out[byte=b + 12 :])


def c_argv(mut args: List[String]) raises -> raw_ptr:
    # strdup each arg: a c-string span ptr can dangle after the expression
    # that produces it, so store owned copies.
    var ptrs = List[UInt64]()
    for i in range(len(args)):
        var dup = external_call["strdup", cstr_ptr](
            args[i].as_c_string_span().ptr()
        )
        ptrs.append(UInt64(Int(dup.value())))
    ptrs.append(0)
    var mem = external_call["calloc", raw_ptr](c_size_t(len(args) + 1), c_size_t(8))
    if not mem:
        raise Error("calloc failed")
    var p64 = mem.value().unsafe_bitcast[UInt64]()
    for i in range(len(ptrs)):
        p64.unsafe_store(i, ptrs[i])
    return mem


def self_dir() -> String:
    # max_self_exe wraps _NSGetExecutablePath (Darwin) / /proc/self/exe
    # (Linux); calling the Darwin symbol directly would not link on Linux
    var buf = external_call["calloc", raw_ptr](c_size_t(4096), c_size_t(1))
    if not buf:
        return ""
    var out = String("")
    if external_call["max_self_exe", c_int](buf.value(), c_size_t(4096)) == 0:
        var p = String(unsafe_from_utf8_ptr=buf.value().unsafe_bitcast[UInt8]())
        var sl = p.rfind("/")
        if sl > 0:
            out = String(p[byte= : sl])
    _ = external_call["free", c_int](buf.value())
    return out


def file_exists(var path: String) -> Bool:
    return external_call["access", c_int](path.as_c_string_span().ptr(), c_int(0)) == 0


def pid() -> Int:
    return Int(external_call["getpid", c_int]())


def run_capture(
    command: String,
    cwd: String,
    cap: Int,
    timeout_ms: Int,
    scrub_env: Bool,
    profile: String = "",
    path_dir: String = "",
) raises -> Tuple[String, Int, Int]:
    var args: List[String]
    if profile == "":
        args = List[String]("/bin/bash", "-c", command, __list_literal__=NoneType())
    else:
        args = List[String](
            "/usr/bin/sandbox-exec", "-p", profile, "/bin/bash", "-c", command,
            __list_literal__=NoneType(),
        )
    var argv = c_argv(args)
    var fds_mem = external_call["calloc", raw_ptr](c_size_t(2), c_size_t(4))
    var pi = fds_mem.value().unsafe_bitcast[c_int]()
    if external_call["pipe", c_int](pi) != 0:
        raise Error("pipe failed")
    var rfd = pi.unsafe_load(0)
    var wfd = pi.unsafe_load(1)
    _ = external_call["free", c_int](fds_mem.value())
    var pid = external_call["fork", c_int]()
    if pid < 0:
        _ = external_call["close", c_int](wfd)
        _ = external_call["close", c_int](rfd)
        _ = external_call["free", c_int](argv.value())
        raise Error("fork failed")
    if pid == 0:
        _ = external_call["setpgid", c_int](c_int(0), c_int(0))
        _ = external_call["dup2", c_int](wfd, c_int(1))
        _ = external_call["dup2", c_int](wfd, c_int(2))
        _ = external_call["close", c_int](rfd)
        var devnull = "/dev/null"
        var dn = external_call["open", c_int, num_fixed_args=2](
            devnull.as_c_string_span().ptr(), c_int(0)
        )
        if dn < 0:
            _ = external_call["_exit", c_int](c_int(126))
        _ = external_call["dup2", c_int](dn, c_int(0))
        var dir = cwd
        if external_call["chdir", c_int](dir.as_c_string_span().ptr()) != 0:
            _ = external_call["_exit", c_int](c_int(126))
        var exe = args[0]
        if scrub_env:
            var envp = external_call["shim_scrubbed_env", raw_ptr]()
            if path_dir != "":
                var slots = envp.value().unsafe_bitcast[cstr_ptr]()
                var i = 0
                while True:
                    var e = slots[i]
                    if not e:
                        break
                    var s = String(unsafe_from_utf8_ptr=e.value())
                    if s.find("PATH=") == 0:
                        var news = String("PATH=" + path_dir + ":" + s[byte=5:])
                        slots[i] = external_call["strdup", cstr_ptr](
                            news.as_c_string_span().ptr()
                        )
                        break
                    i += 1
            _ = external_call["execve", c_int](
                exe.as_c_string_span().ptr(), argv, envp
            )
        else:
            _ = external_call["execv", c_int](exe.as_c_string_span().ptr(), argv)
        _ = external_call["_exit", c_int](c_int(127))
    # Parent also setpgid()s so the kill group exists before the child gets
    # to it; otherwise a signal in that window misses the still-grouped child.
    _ = external_call["setpgid", c_int](pid, pid)
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
    var start_ms = now_ms()
    var done_ms = 0
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
                # Trim once per batch: keep the newest tail_cap bytes.
                if len(tail) > tail_cap:
                    discarded += len(tail) - tail_cap
                    var keep = List[UInt8](capacity=tail_cap)
                    for i in range(len(tail) - tail_cap, len(tail)):
                        keep.append(tail[i])
                    tail = keep^
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
                done_ms = now_ms()
            elif now_ms() - start_ms > timeout_ms:
                timed_out = True
                _ = external_call["kill", c_int](c_int(-pid), c_int(SIGTERM))
                _ = external_call["usleep", c_int](c_int(200000))
                _ = external_call["kill", c_int](c_int(-pid), c_int(SIGKILL))
                _ = external_call["waitpid", c_int](
                    pid, Pointer(to=status), c_int(0)
                )
                child_done = True
                done_ms = now_ms()
        else:
            if now_ms() - done_ms > 3000:
                break
    _ = external_call["close", c_int](rfd)
    _ = external_call["free", c_int](pfd_mem.value())
    _ = external_call["free", c_int](argv.value())
    if not child_done:
        # Loop exited on an error path with the child still running: never
        # leave it behind or block on it.
        _ = external_call["kill", c_int](c_int(-pid), c_int(SIGKILL))
        _ = external_call["waitpid", c_int](pid, Pointer(to=status), c_int(0))
    _ = external_call["shim_track_pgid", c_int](c_int(0))
    var wst = Int(status)
    var code = (wst >> 8) & 0xFF
    var sig = wst & 0x7F
    if sig != 0 and sig != 0x7F:
        code = 128 + sig
    if timed_out:
        code = 124
    var out = String(unsafe_from_utf8=head^) + String(unsafe_from_utf8=tail^)
    return out^, code, discarded
