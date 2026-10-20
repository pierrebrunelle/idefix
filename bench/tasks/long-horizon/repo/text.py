def snake_to_camel(s):
    parts = s.split("_")
    return parts[0].title() + "".join(p.title() for p in parts[1:])


def truncate(s, n):
    if len(s) > n:
        return s[:n] + "..."
    return s + "..."
