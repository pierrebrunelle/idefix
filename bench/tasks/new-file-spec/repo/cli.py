from render import render_table

rows = [{"NAME": "Ada", "AGE": 36}, {"NAME": "Linus", "AGE": 55}]
print(render_table(rows, ["NAME", "AGE"]))
