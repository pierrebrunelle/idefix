def parse_config(text):
    cfg = {}
    for line in text.splitlines():
        if line.startswith("#") or not line:
            continue
        key, _, val = line.partition("=")
        cfg[key] = val
    return cfg
