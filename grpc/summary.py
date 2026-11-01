#!/usr/bin/env python3
"""Summary of a gRPC test bed run: grpc/summary.py <results dir>

Reads <dir>/<index>/<algo>.json (ghz, with every request) of all clients,
<algo>.lb.csv or <algo>.sidecar.csv ("show stat") and the service logs
<dir>/svc-*.log (GC log of the JVM), prints one line per algorithm and
writes <dir>/summary.csv:

  requests, req/s     successful requests of all clients
  errors              failed requests, without the ones cancelled by ghz
                      when the duration ends ("end" column)
  mean .. max         latency of the successful requests (ms), exact
                      percentiles over all the requests of all clients
  share max/min       highest and lowest share of a server (in % of the
                      requests): central from the lb, sidecar summed over
                      the sidecars
  gc                  GC pauses of all services during the run: number,
                      sum and longest (ms)
"""
import csv
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

END_ABORT = "use of closed network connection"
ROUND = re.compile(r"_r\d+$")
GC_RE = re.compile(r"^\[([^\]]+)\]\[[^\]]+\] GC\(\d+\) Pause .* ([0-9.]+)ms$")


def parse_date(s):
    # ghz: 2026-11-01T10:35:44.123456789Z, JVM: 2026-11-01T10:35:44.123+0000
    s = s.replace("Z", "+00:00")
    m = re.match(r"(.*T\d\d:\d\d:\d\d)(\.\d+)?([+-]\d\d:?\d\d)$", s)
    frac = (m.group(2) or ".0")[:7]
    tz = m.group(3) if ":" in m.group(3) else m.group(3)[:3] + ":" + m.group(3)[3:]
    return datetime.fromisoformat(m.group(1) + frac + tz).timestamp()


def pct(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    i = min(len(sorted_vals) - 1, int(len(sorted_vals) * p / 100))
    return sorted_vals[i]


def servers(path, algo, field="stot"):
    """<field> per server of be_<algo> in a "show stat" dump"""
    res = {}
    if not os.path.exists(path):
        return res
    with open(path) as f:
        rows = list(csv.reader(f))
    if not rows:
        return res
    head = [h.lstrip("# ") for h in rows[0]]
    for r in rows[1:]:
        if len(r) < len(head):
            continue
        d = dict(zip(head, r))
        if d["pxname"] == "be_" + algo and d["svname"] not in ("FRONTEND", "BACKEND"):
            res[d["svname"]] = int(d[field] or 0)
    return res


def gc_pauses(rundir):
    pauses = []
    for log in glob.glob(os.path.join(rundir, "svc-*.log")):
        with open(log, errors="replace") as f:
            for line in f:
                m = GC_RE.match(line.strip())
                if m:
                    pauses.append((parse_date(m.group(1)), float(m.group(2))))
    return pauses


def main(rundir):
    clients = sorted(d for d in os.listdir(rundir)
                     if d.isdigit() and os.path.isdir(os.path.join(rundir, d)))
    algos = []
    for c in clients:
        for j in sorted(glob.glob(os.path.join(rundir, c, "*.json")),
                        key=os.path.getmtime):
            a = os.path.basename(j)[:-5]
            if a not in algos:
                algos.append(a)
    pauses = gc_pauses(rundir)

    cols = ["algo", "clients", "requests", "req_per_s", "errors", "end",
            "mean_ms", "p50_ms", "p90_ms", "p99_ms", "p999_ms", "max_ms",
            "share_max", "share_min", "gc_count", "gc_sum_ms", "gc_max_ms"]
    def stats(label, stems):
        lat, errors, end, rps, t0, t1 = [], 0, 0, 0.0, None, None
        srv = {}
        n = 0
        windows = []
        for a in stems:
            rps_run = 0.0
            for c in clients:
                j = os.path.join(rundir, c, a + ".json")
                if not os.path.exists(j):
                    continue
                n += 1
                with open(j) as f:
                    d = json.load(f)
                # "date" is the end of the run
                stop = parse_date(d["date"])
                start = stop - d["total"] / 1e9
                windows.append((start, stop))
                ok = 0
                for r in d.get("details") or []:
                    if r.get("status") == "OK":
                        lat.append(r["latency"] / 1e6)
                        ok += 1
                    elif END_ABORT in (r.get("error") or ""):
                        end += 1
                    else:
                        errors += 1
                rps_run += ok / (d["total"] / 1e9)
                lb = os.path.join(rundir, c, a + ".lb.csv")
                p = lb if os.path.exists(lb) else os.path.join(rundir, c, a + ".sidecar.csv")
                algo = ROUND.sub("", a).split("_")[-1]
                for sv, v in servers(p, algo).items():
                    srv[sv] = srv.get(sv, 0) + v
            rps += rps_run / len(stems)
        n //= max(1, len(stems))
        lat.sort()
        tot = sum(srv.values())
        shares = [100.0 * v / tot for v in srv.values()] if tot else [0.0]
        gc = [p for t, p in pauses if any(a <= t <= b for a, b in windows)]
        return [label, n, len(lat), round(rps), errors, end,
                round(sum(lat) / len(lat), 2) if lat else 0,
                round(pct(lat, 50), 2), round(pct(lat, 90), 2),
                round(pct(lat, 99), 2), round(pct(lat, 99.9), 2),
                round(lat[-1], 2) if lat else 0,
                round(max(shares), 1), round(min(shares), 1),
                len(gc), round(sum(gc)), round(max(gc), 1) if gc else 0]

    # one line per run, then per algorithm over all rounds
    algos = [a for a in algos if a != "warmup"]
    out = [stats(a, [a]) for a in algos]
    bases = []
    for a in algos:
        if ROUND.search(a) and ROUND.sub("", a) not in bases:
            bases.append(ROUND.sub("", a))
    for b in bases:
        out.append(stats(b + " (all)", [a for a in algos if ROUND.sub("", a) == b]))

    with open(os.path.join(rundir, "summary.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        w.writerows(out)
    widths = [max(len(str(x)) for x in col) for col in zip(cols, *out)]
    for row in [cols] + out:
        print("  ".join(str(x).rjust(w) for x, w in zip(row, widths)))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
