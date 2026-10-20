#!/usr/bin/env python3
"""Analyze bench/results.jsonl -> RESULTS.md + charts/*.svg (no dependencies)."""
import json
import os
import random
import re
import statistics
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.environ.get("BENCH_RESULTS", os.path.join(ROOT, "bench", "results.jsonl"))
CHARTS = os.environ.get("BENCH_CHARTS", os.path.join(ROOT, "bench", "charts"))
OUT_MD = os.environ.get("BENCH_OUT_MD", os.path.join(ROOT, "bench", "RESULTS.md"))
LOGS_BASE = os.path.join(ROOT, "bench")

# A row is infra-poisoned when its log ends on a transport/endpoint failure:
# the run measured an outage, not the harness. CURL_ERROR:28 is excluded —
# it is a generation exceeding the request budget (server alive, real result).
INFRA_RE = re.compile(r"CURL_ERROR:(?!28\b)|InternalServerError|Connection\s+error")


def mark_infra(rows, logsdir):
    n = 0
    for r in rows:
        name = f"{r['client']}-{r['task']}-{r['rep']}.log"
        if r.get("run_id"):
            # logs are namespaced by run_id so batches never share a file
            paths = [os.path.join(logsdir, r["run_id"], name)]
        else:
            # legacy rows predate run_id: their logs lived in the dir for
            # their model or in the shared bench/logs
            paths = [os.path.join(logsdir, name),
                     os.path.join(LOGS_BASE, "logs", name)]
        tail = None
        for p in paths:
            try:
                with open(p, errors="replace") as f:
                    tail = f.readlines()[-15:]
                break
            except OSError:
                pass
        if tail is None or r["pass"] or not any(INFRA_RE.search(l) for l in tail):
            continue
        r["infra"] = True
        n += 1
    return n

COLORS = {"mojo": "#4f8ff7", "maxv2": "#8fd14f", "ref": "#9a9a9a", "aider": "#f7a24f",
          "opencode": "#a78bfa", "pi": "#2dd4bf", "dsh": "#f778ba"}
NAMES = {"mojo": "max", "maxv2": "max-v2", "ref": "python-loop", "aider": "aider",
         "opencode": "opencode", "pi": "pi", "dsh": "deepseek-harness"}
BG, FG, MUT, GRID = "#0d1117", "#e6edf3", "#8b949e", "#21262d"
random.seed(7)


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def svg_head(w, h, title):
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" font-family="ui-monospace,monospace" font-size="13">',
        f'<rect width="{w}" height="{h}" fill="{BG}"/>',
        f'<text x="24" y="30" fill="{FG}" font-size="16" font-weight="bold">{esc(title)}</text>',
    ]


def chart_bars(title, data, unit, w=720, suffix=""):
    """data: [(label, color, value, note)] horizontal bars."""
    row_h, pad_t, pad_l, pad_r = 46, 56, 150, 150
    h = pad_t + row_h * len(data) + 30
    vmax = max(v for _, _, v, _ in data) or 1
    plot_w = w - pad_l - pad_r
    out = svg_head(w, h, title)
    for i, (label, color, v, note) in enumerate(data):
        y = pad_t + i * row_h
        bw = max(2, plot_w * v / vmax)
        out.append(f'<text x="{pad_l - 12}" y="{y + 24}" fill="{MUT}" text-anchor="end">{esc(label)}</text>')
        out.append(f'<rect x="{pad_l}" y="{y + 4}" width="{bw:.0f}" height="26" rx="3" fill="{color}"/>')
        out.append(f'<text x="{pad_l + bw + 10:.0f}" y="{y + 23}" fill="{FG}" font-weight="bold">{v:g}{unit}</text>')
        if note:
            out.append(f'<text x="{pad_l + bw + 10 + 8 * len(str(round(v))) + 30:.0f}" y="{y + 23}" fill="{MUT}">{esc(note)}</text>')
    out.append("</svg>")
    return "\n".join(out)


def chart_strip(title, groups, w=760):
    """Jittered per-run dots + median line per group. groups: [(label,color,[vals])]."""
    row_h, pad_t, pad_l, pad_r = 64, 56, 150, 90
    allv = [v for _, _, vs in groups for v in vs]
    vmax = max(allv) if allv else 1
    h = pad_t + row_h * len(groups) + 34
    plot_w = w - pad_l - pad_r
    out = svg_head(w, h, title)
    for xfrac in range(0, 5):
        x = pad_l + plot_w * xfrac / 4
        out.append(f'<line x1="{x:.0f}" y1="{pad_t - 8}" x2="{x:.0f}" y2="{h - 30}" stroke="{GRID}"/>')
        out.append(f'<text x="{x:.0f}" y="{h - 12}" fill="{MUT}" text-anchor="middle">{vmax * xfrac / 4:.0f}s</text>')
    for i, (label, color, vs) in enumerate(groups):
        yc = pad_t + i * row_h + row_h // 2
        out.append(f'<text x="{pad_l - 12}" y="{yc + 4}" fill="{MUT}" text-anchor="end">{esc(label)}</text>')
        for v in vs:
            x = pad_l + plot_w * v / vmax
            y = yc + random.uniform(-14, 14)
            out.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="4" fill="{color}" fill-opacity="0.45"/>')
        if vs:
            m = statistics.median(vs)
            x = pad_l + plot_w * m / vmax
            out.append(f'<line x1="{x:.0f}" y1="{yc - 18}" x2="{x:.0f}" y2="{yc + 18}" stroke="{color}" stroke-width="3"/>')
            out.append(f'<text x="{min(x + 8, w - 70):.0f}" y="{yc - 22}" fill="{color}" font-weight="bold">{m:.0f}s</text>')
    out.append("</svg>")
    return "\n".join(out)


def chart_scatter(title, points, w=760, h=420):
    """points: [(label, color, x=median wall, y=pass pct)]."""
    pad_l, pad_b, pad_t, pad_r = 90, 50, 56, 40
    xs = [p[2] for p in points]
    vmax = max(xs) if xs else 1
    out = svg_head(w, h, title)
    for i in range(5):
        x = pad_l + (w - pad_l - pad_r) * i / 4
        out.append(f'<line x1="{x:.0f}" y1="{pad_t}" x2="{x:.0f}" y2="{h - pad_b}" stroke="{GRID}"/>')
        out.append(f'<text x="{x:.0f}" y="{h - pad_b + 18}" fill="{MUT}" text-anchor="middle">{vmax * i / 4:.0f}s</text>')
        y = pad_t + (h - pad_t - pad_b) * i / 4
        out.append(f'<line x1="{pad_l}" y1="{y:.0f}" x2="{w - pad_r}" y2="{y:.0f}" stroke="{GRID}"/>')
        out.append(f'<text x="{pad_l - 10}" y="{y + 4:.0f}" fill="{MUT}" text-anchor="end">{100 - 25 * i}%</text>')
    for label, color, xv, yv in points:
        x = pad_l + (w - pad_l - pad_r) * xv / vmax
        y = pad_t + (h - pad_t - pad_b) * (1 - yv / 100)
        out.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="9" fill="{color}"/>')
        out.append(f'<text x="{x + 14:.0f}" y="{y + 5:.0f}" fill="{FG}">{esc(label)}</text>')
    out.append(f'<text x="{pad_l}" y="{h - 4}" fill="{MUT}">median wall time per task (s)  |  pass rate</text>')
    out.append("</svg>")
    return "\n".join(out)


def chart_grouped(title, groups, series, data, ymax, unit="", w=760):
    pad_t, pad_l, pad_r = 56, 130, 110
    n_s = len(series)
    if not n_s or not groups:
        return "\n".join(svg_head(w, 90, title) + ["</svg>"])
    # row height scales with series count so bars never drop below 4px
    bar_h = max(4, 26 // n_s)
    row_h = n_s * (bar_h + 4)
    # pack the legend into lines under the chart; item width tracks label
    # length so any series count fits on the canvas
    items = [(s, NAMES.get(s, s)) for s in series]
    llines, lx = [[]], pad_l
    for s, lbl in items:
        iw = 14 + 7 * len(lbl) + 14
        if lx + iw > w - 10 and llines[-1]:
            llines.append([])
            lx = pad_l
        llines[-1].append((s, lbl, iw))
        lx += iw
    h = pad_t + len(groups) * (row_h + 10) + 30 + 16 * len(llines)
    plot_w = w - pad_l - pad_r
    out = svg_head(w, h, title)
    for gi, g in enumerate(groups):
        y0 = pad_t + gi * (row_h + 10)
        out.append(f'<text x="{pad_l - 8}" y="{y0 + row_h // 2 + 4}" fill="{MUT}" text-anchor="end">{esc(g)}</text>')
        for si, s in enumerate(series):
            v = data.get((g, s))
            y = y0 + si * (bar_h + 4) + 2
            if v is None:
                continue
            bw = max(1, plot_w * v / ymax)
            out.append(f'<rect x="{pad_l}" y="{y}" width="{bw:.0f}" height="{bar_h}" rx="2" fill="{COLORS.get(s, MUT)}"/>')
            out.append(f'<text x="{pad_l + bw + 6:.0f}" y="{y + max(bar_h - 2, bar_h // 2 + 4)}" fill="{MUT}">{v:g}{unit}</text>')
    ly = h - 16 * len(llines) - 4
    for line in llines:
        lx = pad_l
        for s, lbl, iw in line:
            out.append(f'<rect x="{lx}" y="{ly}" width="10" height="10" fill="{COLORS.get(s, MUT)}"/>')
            out.append(f'<text x="{lx + 14}" y="{ly + 9}" fill="{MUT}" font-size="11">{esc(lbl)}</text>')
            lx += iw
        ly += 16
    out.append("</svg>")
    return "\n".join(out)


def median(v):
    v = [x for x in v if x is not None]
    return round(statistics.median(v), 1) if v else None


def emit_board(valid_rows, all_rows, model, cdir, cpre, n_infra):
    tasks = sorted({r["task"] for r in valid_rows})
    order = ["mojo", "maxv2", "ref", "aider", "pi", "dsh", "opencode"]
    # clients come from valid rows: a harness with no valid rows has no
    # measurable column, and deriving from valid_rows keeps len(per[c]) > 0
    clients = ([c for c in order if any(r["client"] == c for r in valid_rows)]
               + sorted({r["client"] for r in valid_rows} - set(order)))
    os.makedirs(cdir, exist_ok=True)

    by = defaultdict(list)
    for r in valid_rows:
        by[(r["task"], r["client"])].append(r)
    per = defaultdict(list)
    for r in valid_rows:
        per[r["client"]].append(r)

    pass_pct, wall, rss, toks, reqs = {}, {}, {}, {}, {}
    for (task, c), rs in by.items():
        pass_pct[(task, c)] = round(100 * sum(x["pass"] for x in rs) / len(rs))
        wall[(task, c)] = median([x["wall_s"] for x in rs])
        rss[(task, c)] = median([x["maxrss_mb"] for x in rs])
        toks[(task, c)] = median([x["prompt_tokens"] for x in rs])

    def ymax(d):
        v = [x for x in d.values() if x is not None]
        return (max(v) if v else 1) * 1.1

    # leaderboard charts
    lb = sorted(clients, key=lambda c: -sum(x["pass"] for x in per[c]))
    bars = [
        (NAMES.get(c, c), COLORS.get(c, MUT),
         round(100 * sum(x["pass"] for x in per[c]) / len(per[c])),
         f"{sum(x['pass'] for x in per[c])}/{len(per[c])}")
        for c in lb
    ]
    open(os.path.join(cdir, "leaderboard.svg"), "w").write(
        chart_bars(f"Success rate by harness - {model.split('/')[-1]}", bars, "%"))
    wbars = [(NAMES.get(c, c), COLORS.get(c, MUT), median([x["wall_s"] for x in per[c]]) or 0, "")
             for c in lb]
    open(os.path.join(cdir, "median_time.svg"), "w").write(
        chart_bars(f"Median time per task - {model.split('/')[-1]}", wbars, "s"))
    tbars = [(NAMES.get(c, c), COLORS.get(c, MUT), median([x["prompt_tokens"] for x in per[c] if x["pass"]]) or 0, "")
             for c in lb]
    open(os.path.join(cdir, "tokens_per_success.svg"), "w").write(
        chart_bars(f"Median prompt tokens per success - {model.split('/')[-1]}", tbars, ""))
    open(os.path.join(cdir, "wall_strip.svg"), "w").write(
        chart_strip(f"Wall-clock per run - {model.split('/')[-1]} (dots = runs, bar = median)",
                    [(NAMES.get(c, c), COLORS.get(c, MUT), [x["wall_s"] for x in per[c]]) for c in lb]))
    pts = [(NAMES.get(c, c), COLORS.get(c, MUT), median([x["wall_s"] for x in per[c]]) or 0,
            round(100 * sum(x["pass"] for x in per[c]) / len(per[c]))) for c in lb]
    open(os.path.join(cdir, "pareto.svg"), "w").write(
        chart_scatter(f"Pass rate vs speed - {model.split('/')[-1]} (top-left is best)", pts))
    open(os.path.join(cdir, "pass_rate.svg"), "w").write(
        chart_grouped(f"Pass rate by task (%) - {model.split('/')[-1]}", tasks, clients, pass_pct, 100))
    open(os.path.join(cdir, "peak_rss.svg"), "w").write(
        chart_grouped(f"Median peak RSS (MB) - {model.split('/')[-1]}", tasks, clients, rss, ymax(rss)))

    lines = [f"## `{model}`",
             ""]
    lines.append(f"{len(valid_rows)} valid runs ({len(all_rows)} total): {len(tasks)} tasks x "
                 f"{max(r['rep'] for r in all_rows)} reps x {len(clients)} harnesses.")
    if n_infra:
        lines.append(f"**{n_infra} runs excluded: their logs end on a transport/"
                     f"endpoint error (server outage), not a task outcome.**")
    lines.append("")
    lines.append("## Leaderboard")
    lines.append("")
    lines.append("| harness | pass rate | median wall | peak RSS | median tokens |")
    lines.append("| --- | --- | --- | --- | --- |")
    for c in lb:
        rs = per[c]
        lines.append(
            f"| {NAMES.get(c, c)} | {sum(x['pass'] for x in rs)}/{len(rs)} "
            f"({round(100 * sum(x['pass'] for x in rs) / len(rs))}%) | "
            f"{median([x['wall_s'] for x in rs])}s | {median([x['maxrss_mb'] for x in rs])} MB | "
            f"{median([x['prompt_tokens'] for x in rs])} |"
        )
    lines += ["", f"![leaderboard]({cpre}/leaderboard.svg)", "",
              f"![time]({cpre}/median_time.svg) ![strip]({cpre}/wall_strip.svg)", "",
              f"![pareto]({cpre}/pareto.svg) ![tokens]({cpre}/tokens_per_success.svg)", "",
              "### Methodology notes", "",
              "- max and python-loop talk to MAX on :8000 with a text-command",
              "  protocol; aider uses its edit-format prompts on :8000. pi and",
              "  deepseek-harness use native OpenAI tool calling, which this MAX serve",
              "  build cannot parse (no hermes tool parser), so they run through",
              "  bench/toolcall_proxy.py on :8001, which rewrites <tool_call> text into",
              "  structured tool_calls. Wall times include the proxy hop.",
              "- max-v2 is the same max binary without --bare: journal,",
              "  compaction and retries stay on, so it measures the shipped",
              "  product rather than the raw wire protocol."]
    if "dsh" in clients:
        lines += [
            "- deepseek-harness rows: the model reads the ~6k-token Cordis plugin system",
            "  prompt and may generate refusal-style text instead of tool calls; such",
            "  runs die at the 420s watchdog inside a single completion. A 0% here is a",
            "  model x harness interaction, not a verdict on dsh on bigger models."]
    lines += [
        "- Timeout rows count in medians; 'requests=None' means the run was killed",
        "  before its first LLM call returned.",
        "- Known-failure kinds come from row fields; 'exit-3' covers both",
        "  verify deaths and wire/API deaths the log-tail check could not see.",
        "", "### Pass rate by task", ""]
    lines.append("| task | " + " | ".join(NAMES.get(c, c) for c in clients) + " |")
    lines.append("| --- |" + " --- |" * len(clients))
    for t in tasks:
        lines.append(f"| {t} | " + " | ".join(f"{pass_pct.get((t, c), '-')}%"
                                              for c in clients) + " |")
    lines += ["", f"![pass rate]({cpre}/pass_rate.svg) ![rss]({cpre}/peak_rss.svg)", ""]

    fails = [r for r in valid_rows if not r["pass"]]
    if fails:
        sig_n, sig_tasks = defaultdict(int), defaultdict(set)
        for r in fails:
            if r.get("tampered"):
                kind = "tampered"
            elif r.get("timeout") or r.get("exit") == 143:
                kind = "timeout"
            elif r.get("exit"):
                kind = f"exit-{r['exit']}"
            elif r.get("requests") is None:
                kind = "no-requests"
            else:
                kind = "verify-fail"
            key = (r["client"], kind)
            sig_n[key] += 1
            sig_tasks[key].add(r["task"])
        lines += ["### Known failures", "",
                  "| harness | failure | runs | tasks |",
                  "| --- | --- | --- | --- |"]
        for (c, k), n in sorted(sig_n.items(), key=lambda x: (-x[1], x[0])):
            lines.append(f"| {NAMES.get(c, c)} | {k} | {n} | {', '.join(sorted(sig_tasks[c, k]))} |")
        lines.append("")

    lines += ["### Raw runs", ""]
    lines.append("| harness | task | rep | pass | requests | commands | tokens | wall_s | rss_mb | exit |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for r in all_rows:
        flags = (" infra" if r.get("infra") else "") + (" tampered" if r.get("tampered") else "") \
            + (" timeout" if r.get("timeout") else "")
        lines.append(
            f"| {NAMES.get(r['client'], r['client'])} | {r['task']} | {r['rep']} | {int(r['pass'])} | "
            f"{r['requests']} | {r['commands']} | {r['prompt_tokens']} | {r['wall_s']} | {r['maxrss_mb']} | {r['exit']}{flags} |"
        )
    lines.append("")
    return lines


def main():
    rows = [json.loads(l) for l in open(RESULTS)]
    models = []
    for r in rows:
        m = r.get("model") or ""
        if m not in models:
            models.append(m)
    lines = ["# Benchmark results", "",
             "Local MAX serving (`max serve`, single replica). Harness versions:",
             "pi 1.3.0, deepseek-harness 0.2.0-rc.2, aider 0.86.2. Verified by each",
             "task's independent `verify.sh`; tokens are usage-reported, not scored.",
             ""]
    for model in models:
        slug = re.sub(r"[^a-z0-9]+", "-", (model.split("/")[-1] or "model").lower()).strip("-") or "model"
        board = [r for r in rows if (r.get("model") or "") == model]
        n_infra = mark_infra(
            board,
            os.environ.get("BENCH_LOGS") or os.path.join(LOGS_BASE, f"logs-{slug}"))
        valid = [r for r in board if not r.get("infra")]
        lines += emit_board(
            valid, board,
            model or "unknown",
            os.path.join(CHARTS, slug),
            f"charts/{slug}",
            n_infra,
        )
    open(OUT_MD, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines[:30]))


if __name__ == "__main__":
    main()
