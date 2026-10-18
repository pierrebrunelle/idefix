def slugify(s):
    return s.lower().replace(" ", "-")

def title_case(s):
    return " ".join(w.capitalize() for w in s.split())

def clamp(x, lo, hi):
    return max(lo, min(hi, x))
