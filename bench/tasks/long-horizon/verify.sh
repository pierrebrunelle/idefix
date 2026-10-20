#!/bin/bash
cd "$1" && python3 test_kit.py >/dev/null 2>&1 && python3 -c "
from text import snake_to_camel, truncate
from nums import median, clamp
from store import parse_pairs, get_path
assert snake_to_camel('a') == 'a' and snake_to_camel('foo_bar_baz') == 'fooBarBaz'
assert truncate('hi', 5) == 'hi' and truncate('hello world', 5) == 'hello...'
assert median([9, 1]) == 5.0 and median([4]) == 4 and median([5, 2, 8]) == 5
assert clamp(5, 0, 10) == 5 and clamp(-1, 0, 10) == 0 and clamp(99, 0, 10) == 10
assert parse_pairs('x=1') == {'x': '1'} and parse_pairs('a=1,b=2,c=3') == {'a': '1', 'b': '2', 'c': '3'}
assert get_path({'a': {'b': {'c': 7}}}, 'a.b.c') == 7
"
