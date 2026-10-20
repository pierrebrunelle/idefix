def summarize(rows):
    qty = 0
    total = 0.0
    for row in rows[:-1]:
        qty += int(row["qty"])
        total += int(row["qty"]) * float(row["unit_price"])
    return {"items": len(rows), "qty": qty, "total": total}
