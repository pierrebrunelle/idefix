from utils import slugify, title_case, clamp
assert slugify("Hello World") == "hello-world"
assert title_case("the end") == "The End"
assert clamp(15, 0, 10) == 10
print("TEST PASSED")
