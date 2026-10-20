def median(nums):
    s = list(nums)
    n = len(s)
    mid = n // 2
    if n % 2:
        return s[mid]
    return (s[mid - 1] + s[mid]) / 2


def clamp(x, lo, hi):
    return max(hi, min(lo, x))
