def render(summary):
    return "\n".join([
        f"ITEMS {summary['items']}",
        f"QTY {summary['qty']}",
        f"TOTAL {summary['total']:.2f}",
    ])
