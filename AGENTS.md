# AGENTS.md

Guidance for AI coding agents (and humans) working with this repository.
The READMEs are the reference; this file is the short version, plus the
pitfalls that cost time while building it.

## What this repository is

Three test beds that compare HAProxy load balancing algorithms on the same
servers, locally with podman or on any Kubernetes cluster:

| Test bed | Directory | Servers are slow because | Load generator |
|---|---|---|---|
| Peak EWMA (Lua prototype and core patch) | `/` (`config/`, `lua/`, `scripts/`, `k8s/`) | some servers always have a fixed delay | h2load |
| MyTime, the 2019 "power of two" test of HAProxy | `mytime/` | CPU contention, many sidecar load balancers | haload (or h2load over h2c) |
| gRPC on a fleet of JVMs | `grpc/` | garbage collection pauses | ghz |

Results so far: see "Conclusion" in [README.md](README.md). In short,
`leastconn` held up in MyTime and gRPC; `random(3) peak-ewma` only won
on the first test bed.

`balance random(<draws>) peak-ewma` is **not in HAProxy**. It needs a
HAProxy source tree with the peak EWMA patches. With a stock HAProxy
(`HAPROXY_REF`, the default when there is no `src/haproxy.tar`):

- the first test bed and the gRPC test bed do not start, as
  `config/lb.cfg` and `grpc/gen-cfg.sh` always contain the `peak-ewma`
  backends; remove them to run without the patches;
- MyTime works, as it only renders the selected algorithm: leave `pe2`
  and `pe3` out of `ALGOS`.

## Repository map

| Path | Content |
|---|---|
| `containers/haproxy/` | image `peak-ewma-hap`: HAProxy, haterm, haload, Lua; base of the other images |
| `containers/h2load/` | image `peak-ewma-h2load` |
| `config/`, `lua/peak_ewma.lua` | first test bed: lb with one port per algorithm, shim in front of each haterm, the Lua prototype |
| `scripts/local.sh`, `scripts/bench.sh` | first test bed: build, local run, benchmark |
| `k8s/`, `kustomization.yaml` | first test bed on Kubernetes (namespace `peak-ewma`) |
| `mytime/` | MyTime: Containerfile, `gen-cfg.sh`, `entrypoint.sh`, `bench.sh`, `plot.sh`, `local.sh`, `get-all-results.sh`, `k8s/` (namespace `mytime`) |
| `grpc/` | gRPC: `service/` (Spring Boot), Containerfile (lb and client), `gen-cfg.sh`, `bench.sh`, `summary.py`, `plot.sh`, `plot-data.py`, `local.sh`, `get-all-results.sh`, `k8s/` (namespace `grpc`) |
| `results/` | git-ignored, one directory per run |
| `src/haproxy.tar` | git-ignored, the HAProxy tree that the image builds (see below) |

## Prerequisites

- podman (rootless works; the scripts use CPU quotas, not cpusets)
- for clusters: kubectl with kustomize, and node pools labelled
  `nodepool=<name>`
- python3 on the host for `grpc/summary.py` and `grpc/plot-data.py`
- gnuplot, or podman: the plot scripts fall back to an Alpine container

## Build

Order matters, the MyTime and gRPC images build on `peak-ewma-hap`:

```sh
scripts/local.sh src [<ref>]   # git archive of <ref> (default HEAD) of HAPROXY_GIT (../haproxy)
scripts/local.sh build         # peak-ewma-hap and peak-ewma-h2load
mytime/local.sh build          # peak-ewma-mytime
grpc/local.sh build            # peak-ewma-grpc-svc and peak-ewma-grpc
```

- `scripts/local.sh src` takes a **git ref**, not a path. Only committed
  changes end up in the archive. `scripts/local.sh src -` goes back to
  `HAPROXY_REF`.
- haload needs `USE_OPENSSL=1` and `<signal.h>` on musl; the HAProxy
  Containerfile passes `ADDINC="-include signal.h"`.
- **Do not publish the `peak-ewma-mytime` image.** It contains the
  services of haproxytech/bench-algo-p2c, which has no license file. The
  repository does not copy them either: the Containerfile clones them at
  build time. Keep the image in a private registry.

## Run locally

```sh
scripts/local.sh up && scripts/local.sh bench && scripts/local.sh down
mytime/local.sh up && mytime/local.sh bench LEVELS=4 'ALGOS=po2 lc' && mytime/local.sh down
grpc/local.sh up && CLIENTS=2 grpc/local.sh bench WARMUP=10s DURATION=15s 'ALGOS=lc pe3' && grpc/local.sh down
```

Arguments with spaces must be quoted as a whole (`'ALGOS=lc pe3'`).

## Run on a cluster

Read the "On MKS" section of the README of the test bed first. Rules that
apply to all three:

1. **Raise conntrack on every node first** for MyTime (HTTP/1, a new
   connection per request on every hop). With the default table the
   kernel drops SYNs and every algorithm shows the same 1 s / 4 s tail.
   The command is in [mytime/README.md](mytime/README.md).
2. Run **one test bed at a time**; their pods compete for the same nodes.
3. `kubectl apply -k <dir>/`, then follow `kubectl -n <ns> logs -f job/bench`.
4. Copy the results **while the bench pod still runs** (it waits `KEEP`
   seconds after the last run): `mytime/get-all-results.sh <label>` or
   `grpc/get-all-results.sh <label>`; for the first test bed
   `kubectl -n peak-ewma cp <bench-pod>:/results ./results`.
5. `kubectl -n <ns> delete job bench` before the next apply. Never apply
   while the Job runs: the ConfigMap with `bench.sh` would change under
   the running script.

Cluster changes (apply, delete, debug pods with sysctl) affect shared
infrastructure: an agent should propose them and let a human run them,
unless told otherwise. The `get-all-results.sh` scripts only read
(`kubectl get`, `logs`, `cp`, `top`, `exec` of `show stat`).

## Reading the results

- First test bed: `summary.csv`, "slow" is the share of the requests on
  the slow servers (the degraded `be-2` is reported separately).
- MyTime: `summary.csv` per level; `listen_overflows` (connections the
  services dropped) and `max_load` (smax) explain most differences.
  Charts: `mytime/plot.sh <dir> <cores>`.
- gRPC: `grpc/summary.py <dir>` (exact percentiles over all clients,
  share per server, GC pauses per run), charts with `grpc/plot.sh <dir>`.
- One run per cell (MyTime) or one pass (gRPC): differences of a few
  percent are within the noise. Compare against a reference algorithm
  run **on the same cluster**, not against numbers of another cluster.

## Pitfalls found while building it

- **Check `Idle_pct` of the load balancer** (`show info`). A saturated
  load balancer measures its own CPU, not the algorithms.
- **HAProxy resolvers ignore the search domains** of `resolv.conf`: use
  FQDNs (`<pod>.<service>.<ns>.svc.cluster.local`).
- **Lua variable names** only allow letters, digits, `_` and `.`;
  `set_var()` fails silently otherwise.
- **h2load** closes its connections at the end of a run (client aborts,
  not server errors), and cannot handle the HTTP/1.0 close-delimited
  responses of MyTime over HTTP/1.
- **ghz**: `date` in its JSON report is the *end* of the run, and `-z`
  cancels the requests still in flight when the duration ends (reported
  as "end", not as errors, by `summary.py`). The ghz binary is only run
  inside the container, downloaded with a SHA-256 check.
- **`show stat` counters are cumulative**: the gRPC bench clears them
  after each run.
- **podman volumes shared by several containers** need `:z`, not `:Z`.
- **`/proc/stat` is not namespaced**: the CPU samples of a pod are those
  of the whole VM, which makes CPU steal visible.
- **The listen backlog of 5** of the original MyTime services decides the
  tail: SYN retransmits after 1 s and 3 s, visible as steps in the
  percentile charts and as `ListenOverflows`.

## Conventions

- Documentation in English, lines wrapped at about 72 to 80 characters.
- Keep measured results, source reading and configuration advice apart,
  and say which one a statement is.
- No prices in the documentation.
- Do not commit `results/`, `src/haproxy.tar`, or anything that contains
  the original MyTime services.
