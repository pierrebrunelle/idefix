import sys
args = sys.argv[1:]
text = args[-1]
if "--upper" in args:
    print(text)  # bug: flag ignored
else:
    print(text)
