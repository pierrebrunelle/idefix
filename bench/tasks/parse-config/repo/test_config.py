from config import parse_config

with open("sample.cfg") as f:
    cfg = parse_config(f.read())
assert cfg == {"host": "localhost", "port": "8080", "debug": "true"}, cfg
print("TEST PASSED")
