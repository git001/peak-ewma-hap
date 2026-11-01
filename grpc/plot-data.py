#!/usr/bin/env python3
"""Data files for grpc/plot.sh: grpc/plot-data.py <results dir>

Writes <dir>/plot/<mode>_<algo>.{pctl,series} and <mode>.share, all rounds
of an algorithm together, from the ghz files of all clients and the
"show stat" dumps (see grpc/summary.py):

  .pctl     "<percentile> <latency ms>", exact over all requests
  .series   "<second> <p99 ms> <mean ms>" per second of the run, the
            seconds of the rounds and clients are merged
  .share    "<server> <share % of algo 1> <share % of algo 2> ...", with
            the algorithms in the header line
  .smax     one block per algorithm (in the order of the header line):
            "<server> <smax of source 1> <smax of source 2> ...", the
            sources being the lb (central) or the sidecar of each client,
            the highest value of the rounds
"""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from summary import ROUND, parse_date, servers  # noqa: E402

PCTS = [0, 10, 20, 30, 40, 50, 60, 70, 75, 80, 85, 90, 92, 94, 95, 96, 97,
        98, 99, 99.3, 99.5, 99.7, 99.8, 99.9, 99.93, 99.95, 99.97, 99.99,
        99.995, 99.999]


def main(rundir):
    out = os.path.join(rundir, "plot")
    os.makedirs(out, exist_ok=True)
    clients = sorted(d for d in os.listdir(rundir)
                     if d.isdigit() and os.path.isdir(os.path.join(rundir, d)))
    runs = {}
    for c in clients:
        for j in glob.glob(os.path.join(rundir, c, "*.json")):
            stem = os.path.basename(j)[:-5]
            if stem == "warmup":
                continue
            runs.setdefault(ROUND.sub("", stem), []).append((c, stem, j))

    shares = {}
    smax = {}
    for base, files in sorted(runs.items()):
        mode, algo = base.rsplit("_", 1)
        lat = []
        per_sec = {}
        srv = {}
        for c, stem, j in files:
            with open(j) as f:
                d = json.load(f)
            start = parse_date(d["date"]) - d["total"] / 1e9
            for r in d.get("details") or []:
                if r.get("status") != "OK":
                    continue
                ms = r["latency"] / 1e6
                lat.append(ms)
                sec = int(parse_date(r["timestamp"]) - start)
                per_sec.setdefault(sec, []).append(ms)
            lb = os.path.join(rundir, c, stem + ".lb.csv")
            p = lb if os.path.exists(lb) else os.path.join(rundir, c, stem + ".sidecar.csv")
            for sv, v in servers(p, algo).items():
                srv[sv] = srv.get(sv, 0) + v
            # central: only the lb balances, the sidecars are unused
            m = smax.setdefault(mode, {}).setdefault(algo, {})
            if p == lb or mode != "central":
                src = "lb" if p == lb else c
                for sv, v in servers(p, algo, "smax").items():
                    m[(sv, src)] = max(m.get((sv, src), 0), v)
        lat.sort()
        with open(os.path.join(out, base + ".pctl"), "w") as f:
            for p in PCTS:
                i = min(len(lat) - 1, int(len(lat) * p / 100))
                f.write(f"{p} {lat[i]:.3f}\n")
            f.write(f"100 {lat[-1]:.3f}\n")
        with open(os.path.join(out, base + ".series"), "w") as f:
            for sec in sorted(per_sec):
                v = sorted(per_sec[sec])
                f.write(f"{sec} {v[int(len(v) * 0.99)]:.3f} {sum(v) / len(v):.3f}\n")
        tot = sum(srv.values())
        if tot:
            shares.setdefault(mode, {})[algo] = {s: 100.0 * v / tot for s, v in srv.items()}

    for mode, per_algo in shares.items():
        algos = sorted(per_algo)
        names = sorted({s for a in algos for s in per_algo[a]},
                       key=lambda s: int(re.sub(r"\D", "", s) or 0))
        with open(os.path.join(out, mode + ".share"), "w") as f:
            f.write("server " + " ".join(algos) + "\n")
            for s in names:
                f.write(s + " " + " ".join(f"{per_algo[a].get(s, 0):.2f}" for a in algos) + "\n")
        srcs = sorted({k[1] for a in algos for k in smax[mode][a]})
        with open(os.path.join(out, mode + ".smax"), "w") as f:
            f.write("# sources: " + " ".join(srcs) + "\n")
            for a in algos:
                for s in names:
                    f.write(s + " " + " ".join(str(smax[mode][a].get((s, x), 0)) for x in srcs) + "\n")
                f.write("\n\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
