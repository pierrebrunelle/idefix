from slug import slugify

assert slugify("Hello World") == "hello-world"
assert slugify("Hello,  World!") == "hello-world", slugify("Hello,  World!")
assert slugify("  spaced   out  ") == "spaced-out"
print("TEST PASSED")
