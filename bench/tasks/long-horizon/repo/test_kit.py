from text import snake_to_camel, truncate
from nums import median, clamp
from store import parse_pairs, get_path

assert snake_to_camel("foo_bar") == "fooBar", snake_to_camel("foo_bar")
assert snake_to_camel("a_b_c") == "aBC"
assert truncate("hello world", 5) == "hello..."
assert truncate("hi", 5) == "hi", truncate("hi", 5)
assert median([3, 1, 2]) == 2, median([3, 1, 2])
assert median([10, 1, 4, 2]) == 3.0, median([10, 1, 4, 2])
assert clamp(5, 0, 10) == 5, clamp(5, 0, 10)
assert clamp(-3, 0, 10) == 0
assert parse_pairs("a=1,b=2") == {"a": "1", "b": "2"}, parse_pairs("a=1,b=2")
assert parse_pairs("") == {}
assert get_path({"a": {"b": 3}}, "a.b") == 3
assert get_path({"x": 1}, "x") == 1
print("TEST PASSED")
