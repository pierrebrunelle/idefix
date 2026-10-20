import csv


def read_rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))
