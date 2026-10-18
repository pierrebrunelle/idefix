#!/usr/bin/env python3
"""Analyze bench/results.jsonl -> RESULTS.md + charts/*.svg (no dependencies)."""
import json
import math
import os
import statistics
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "bench", "results.jsonl")
CHARTS = os.path.join(ROOT, "bench", "charts")
OUT_MD = os.path.join(ROOT, "bench", "RESULTS.md")

COLORS = {"mojo": "#4f8ff7", "ref": "#9a9a9a"}
W, ROW_H, PAD_L, PAD_T = 720, 34, 130, 46


def svg_grouped_bars(title, groups, series, data, ymax, unit=""):
    """groups: x labels; series: [name]; data[(group,series)] = value or None."""
    n_g, n_s = len(groups), len(series)
    chart_h = PAD_T + n_g * (ROW_H + 10)
    plot_w = W - PAD_L - 110
    bar_h = ROW_H // n_s - 4
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{chart_h + 30}" font-family="ui-monospace,monospace" font-size="12">',
        f'<rect width="{W}" height="{chart_h + 30}" fill="#0d1117"/>',
        f'<text x="{PAD_L}" y="26" fill="#e6edf3" font-size="15" font-weight="bold">{title}</text>',
    ]
    for gi, g in enumerate(groups):
        y0 = PAD_T + gi * (ROW_H + 10)
        out.append(f'<text x="{PAD_L - 8}" y="{y0 + ROW_H // 2 + 4}" fill="#8b949e" text-anchor="end">{g}</text>')
        for si, s in enumerate(series):
            v = data.get((g, s))
            y = y0 + si * (bar_h + 4) + 2
            if v is None:
                continue
            w = max(1, plot_w * (v / ymax))
            out.append(f'<rect x="{PAD_L}" y="{y}" width="{w:.0f}" height="{bar_h}" rx="2" fill="{COLORS[s]}"/>')
            out.append(f'<text x="{PAD_L + w + 6:.0f}" y="{y + bar_h - 2}" fill="#8b949e">{v:g}{unit}</text>')
    lx = W - 96
    for si, s in enumerate(series):
        out.append(f'<rect x="{lx}" y="{12 + si * 16}" width="10" height="10" fill="{COLORS[s]}"/>')
        out.append(f'<text x="{lx + 14}" y="{21 + si * 16}" fill="#8b949e">{s}</text>')
    out.append("</svg>")
    return "\n".join(out)


def median(v):
    v = [x for x in v if x is not None]
    return round(statistics.median(v), 1) if v else None


def main():
    rows = [json.loads(l) for l in open(RESULTS)]
    tasks = sorted({r["task"] for r in rows})
    clients = ["mojo", "ref"]
    os.makedirs(CHARTS, exist_ok=True)

    by = defaultdict(list)
    for r in rows:
        by[(r["task"], r["client"])].append(r)

    # per-cell aggregates
    pass_pct, wall, rss, toks, reqs = {}, {}, {}, {}, {}
    for (task, c), rs in by.items():
        pass_pct[(task, c)] = round(100 * sum(x["pass"] for x in rs) / len(rs))
        wall[(task, c)] = median([x["wall_s"] for x in rs])
        rss[(task, c)] = median([x["maxrss_mb"] for x in rs])
        toks[(task, c)] = median([x["prompt_tokens"] for x in rs])
        reqs[(task, c)] = median([x["requests"] for x in rs])

    svg = svg_grouped_bars("Pass rate by task (%)", tasks, clients, pass_pct, 100)
    open(os.path.join(CHARTS, "pass_rate.svg"), "w").write(svg)
    svg = svg_grouped_bars("Median wall time (s)", tasks, clients, wall, max(wall.values() or [1]) * 1.1)
    open(os.path.join(CHARTS, "wall_time.svg"), "w").write(svg)
    svg = svg_grouped_bars("Median peak RSS (MB)", tasks, clients, rss, max(rss.values() or [1]) * 1.1)
    open(os.path.join(CHARTS, "peak_rss.svg"), "w").write(svg)
    svg = svg_grouped_bars("Median prompt tokens", tasks, clients, toks, max(toks.values() or [1]) * 1.1)
    open(os.path.join(CHARTS, "prompt_tokens.svg"), "w").write(svg)

    # overall rows per client
    lines = ["# Benchmark results", ""]
    lines.append(f"Model: `{os.environ.get('MAX_MODEL', 'Qwen/Qwen3-1.7B')}` on MAX (CPU, float32). "
                 f"{len(rows)} runs across {len(tasks)} tasks x {len(clients)} clients.")
    lines.append("")
    lines.append("## Pass rate")
    lines.append("")
    lines.append("| task | mojo | ref |")
    lines.append("| --- | --- | --- |")
    for t in tasks:
        lines.append(f"| {t} | {pass_pct.get((t,'mojo'),'-')}% | {pass_pct.get((t,'ref'),'-')}% |")
    mp = [r for r in rows if r["client"] == "mojo"]
    rp = [r for r in rows if r["client"] == "ref"]
    def pct(rs):
        return round(100 * sum(x["pass"] for x in rs) / len(rs)) if rs else "-"
    lines.append(f"| **overall** | **{pct(mp)}%** | **{pct(rp)}%** |")
    lines.append("")
    lines.append("![pass rate](charts/pass_rate.svg)")
    lines.append("")
    lines.append("## Cost per run (median)")
    lines.append("")
    lines.append("| metric | mojo | ref |")
    lines.append("| --- | --- | --- |")
    for label, key in (("wall_s", "wall_s"), ("peak RSS MB", "maxrss_mb"), ("prompt tokens", "prompt_tokens"), ("requests", "requests"), ("commands", "commands")):
        a = median([x[key] for x in mp])
        b = median([x[key] for x in rp])
        lines.append(f"| {label} | {a if a is not None else '-'} | {b if b is not None else '-'} |")
    lines.append("")
    lines.append("![wall](charts/wall_time.svg) ![rss](charts/peak_rss.svg) ![tokens](charts/prompt_tokens.svg)")
    lines.append("")
    lines.append("## Raw runs")
    lines.append("")
    lines.append("| client | task | rep | pass | requests | commands | tokens | wall_s | rss_mb | exit |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for r in rows:
        lines.append(
            f"| {r['client']} | {r['task']} | {r['rep']} | {int(r['pass'])} | "
            f"{r['requests']} | {r['commands']} | {r['prompt_tokens']} | {r['wall_s']} | {r['maxrss_mb']} | {r['exit']} |"
        )
    open(OUT_MD, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines[:20]))


if __name__ == "__main__":
    main()
