#!/bin/bash
cd "$1" || exit 1
rm -f app.json
python3 migrate.py >/dev/null 2>&1 || exit 1
python3 -c "
import configparser, json
cfg = configparser.ConfigParser()
cfg.read('app.ini')
expected = {sec: dict(cfg.items(sec)) for sec in cfg.sections()}
actual = json.load(open('app.json'))
assert actual == expected, f'{actual} != {expected}'
"
