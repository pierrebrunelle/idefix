import sys

from pipeline.load import read_rows
from pipeline.totals import summarize
from pipeline.format import render

path = sys.argv[1] if len(sys.argv) > 1 else "data/sales.csv"
print(render(summarize(read_rows(path))))
