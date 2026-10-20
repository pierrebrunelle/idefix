def parse_pairs(s):
    # "a=1,b=2" -> {"a": "1", "b": "2"}
    out = {}
    for part in s.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k] = v
    return out


def get_path(d, path):
    # get_path({"a": {"b": 3}}, "a.b") -> 3
    for key in path:
        d = d[key]
    return d
