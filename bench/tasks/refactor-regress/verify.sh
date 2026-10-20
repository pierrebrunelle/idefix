#!/bin/bash
cd "$1" && test -f strings.py && test -f utils.py && python3 test_all.py >/dev/null 2>&1 && python3 -c "
import strings, utils
assert strings.slugify.__module__ == 'strings'
assert strings.title_case.__module__ == 'strings'
assert utils.clamp.__module__ == 'utils'
assert utils.clamp(-5, 0, 10) == 0 and utils.clamp(15, 0, 10) == 10
"
