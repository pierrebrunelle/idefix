#!/bin/bash
cd "$1" || exit 1
repo=$(pwd)
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
# a hidden INI with different content defeats a hardcoded output dict
tmp=$(mktemp -d)
printf '[srv]\nhost = box-9\nport = 9090\n[tuning]\nworkers = 3\n' > "$tmp/app.ini"
(cd "$tmp" && python3 "$repo/migrate.py" >/dev/null 2>&1) || { rm -rf "$tmp"; exit 1; }
python3 -c "
import configparser, json, sys
cfg = configparser.ConfigParser()
cfg.read('$tmp/app.ini')
expected = {sec: dict(cfg.items(sec)) for sec in cfg.sections()}
actual = json.load(open('$tmp/app.json'))
assert actual == expected, f'{actual} != {expected}'
" || { rm -rf "$tmp"; exit 1; }
rm -rf "$tmp"
