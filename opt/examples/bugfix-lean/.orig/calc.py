def pct_change(old, new):
    # bug: crashes on old=0, wrong sign convention for negative base
    return (new - old) / old * 100
