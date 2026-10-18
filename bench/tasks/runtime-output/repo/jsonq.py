import json, sys
data = json.loads(open(sys.argv[0]).read())
print(data[sys.argv[1]])
