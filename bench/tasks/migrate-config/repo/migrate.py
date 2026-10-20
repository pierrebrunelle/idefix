import configparser
import json

cfg = configparser.ConfigParser()
cfg.read("app.ini")
out = {}
for sec in cfg.sections():
    for k, v in cfg.items(sec):
        out[k] = v.lower()
json.dump(out, open("app.json", "w"), indent=2)
