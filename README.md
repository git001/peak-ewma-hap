# Peak EWMA for HAProxy: Lua prototype, core patch and test bed

A prototype of the Peak EWMA load balancing algorithm (Finagle, Linkerd,
Envoy contrib) for HAProxy written in Lua, and a test bed that compares it
on the same servers with `balance random(2)`, `balance leastconn` and the
core implementation `balance random(<draws>) peak-ewma` proposed for
HAProxy. The Lua prototype runs in three variants: 2 random draws (the
power of two choices of Finagle), 3 random draws, and a comparison of all
servers ("pewmafull", the latency-aware counterpart of `leastconn`).

The questions it answers: does a latency-aware choice route around a slow
server better than the session count that `random(2)` and `leastconn`
use, and does the core implementation behave like the prototype?

Results and the story behind them: see [Results](#results) below.

The opposite case, slowness from CPU contention with many sidecar load
balancers, is the rebuild of the 2019 "power of two" test of HAProxy in
[mytime/](mytime/README.md).

Mailing list:

- [PATCH 0/2] backend: better use of the draws of balance random
  (https://www.mail-archive.com/haproxy@formilux.org/msg47703.html),
  found with this test bed
- the review of a first attempt in February 2026
  (https://www.mail-archive.com/haproxy@formilux.org/msg46569.html)

## How it works

```
h2load ──► lb :8080  balance random(2)           ─┐
           lb :8081  random(2) + Lua Peak EWMA   ─┼─► shim1 ─► haterm1   delay 5 ms
           lb :8082  balance leastconn           ─┤   shim2 ─► haterm2   delay 5 ms
           lb :8083  Lua Peak EWMA, all servers  ─┤
           lb :8084  Lua Peak EWMA, 3 draws      ─┤   shim3 ─► haterm3   delay 5 ms
           lb :8085  random(2) peak-ewma (core)  ─┤
           lb :8086  random(3) peak-ewma (core)  ─┤
           lb :8087  as 8085, weight 100         ─┤
           lb :8088  as 8086, weight 100         ─┘
                                                      shim4 ─► haterm4   delay 50 ms
```

- **haterm** is HAProxy's dummy HTTP server for benchmarks. It takes the
  response size (`s`) and the delay (`t`) from the query string of the
  request only; it runs no `http-request` rules.
- **shim** is a small HAProxy in front of each haterm. It sets
  `?s=<SIZE>&t=<DELAY>` on every request, so each server has its own
  latency. The delay can be changed at runtime over the CLI of the shim, to
  slow a server down during a run.
- **lb** has the same servers behind each algorithm, one port each. The
  ports 8085 to 8088 use the core implementation `balance random(<draws>)
  peak-ewma`, which needs an HAProxy built from the peak-ewma branch (see
  below), and compare it with the Lua prototype on the same servers.
  8087 and 8088 give all servers the weight 100, so that each server gets
  1600 points on the consistent hash ring instead of 16 and the random
  draws become almost uniform.

### The Lua part ([lua/peak_ewma.lua](lua/peak_ewma.lua))

```
backend be_pewma
    balance random(2)
    http-request lua.peak_ewma_pick be_pewma 2
    use-server %[var(txn.pe_pick)] if { var(txn.pe_pick) -m found }
    http-after-response lua.peak_ewma_record
```

- `peak_ewma_record` runs for every response, also for the errors HAProxy
  generates itself (503, 504): it takes `res.timer.hdr` (`%Tr`), or a
  penalty when there is no server response, and updates the EWMA of the
  server. A sample above the current average replaces it at once (the
  "peak"); otherwise it moves the average with a time-based weight. On
  read, the average decays towards 0 with the time constant, so a server
  that got no traffic because it was slow becomes attractive again.
- `peak_ewma_pick <backend> <choices>` compares `<choices>` distinct random
  servers and picks the one with the lowest cost
  `ewma * (sessions + pending + 1) / weight`. A server without a sample yet
  counts with `PE_DEFAULT_RTT_MS`.
  - `2` is the power of two choices (`be_pewma`, :8081). It stays robust
    with several load balancer instances, which all share the same view of
    the latency but only know their own sessions.
  - `0` compares all usable servers (`be_pewmafull`, :8083), as `leastconn`
    does. With one instance the session count in the cost is always
    current, so this is close to a latency-weighted `leastconn`.
- The EWMA lives in `proc.` variables, shared by all threads. The
  read-modify-write is not atomic; a lost sample does not matter for an
  estimate.
- If the picked server is down, `use-server` is skipped and
  `balance random(2)` chooses.

Settings of the load balancer (environment):

| Variable | Default | Meaning |
|---|---|---|
| `PE_TAU_MS` | 10000 | decay time constant |
| `PE_DEFAULT_RTT_MS` | 10 | cost of a server without sample |
| `PE_PENALTY_MS` | 30000 | sample for a failed response |
| `PE_REFRESH_MS` | 1000 | refresh of the server list per thread |
| `NBTHREAD` | 2 | threads of HAProxy |

Limits of the prototype: two Lua calls per request, millisecond resolution
of `%Tr`, the server list is refreshed once per second and thread.

## Container images

| Image | Containerfile | Content |
|---|---|---|
| `peak-ewma-hap` | [containers/haproxy](containers/haproxy/Containerfile) | HAProxy, haterm and haload (`src/haproxy.tar` if present, else `HAPROXY_REF`, default `v3.5-dev9`), Lua 5.4, OpenSSL (for haload), the configurations; roles `lb`, `shim`, `haterm` |
| `peak-ewma-mytime` | [mytime](mytime/Containerfile) | the image above plus Python and the services of the 2019 test, see [mytime/](mytime/README.md) |
| `peak-ewma-h2load` | [containers/h2load](containers/h2load/Containerfile) | h2load from nghttp2 1.70.0 with aws-lc v5.12.0, nghttp3 1.18.0, ngtcp2 1.25.0, plus curl and socat |

The h2load Containerfile is based on the one of the server-benchmark lab,
with current versions and a bounded build parallelism (`JOBS`).

## Local run with podman

All containers run in one pod. Each container has a CPU and memory limit
(see `LIM_*` in [scripts/local.sh](scripts/local.sh)): 4 × haterm with
1 CPU, 4 × shim with 0.5 CPU, the load balancer and h2load with 2 CPUs
each, about 10 CPUs and 3.5 GB in total. The builds are limited to 8 CPUs and 8 GB
(`BUILD_CPUS`, `BUILD_MEM`, `BUILD_JOBS`). Rootless podman only has the
cpu, io, memory and pids controllers, so the limits are CPU quotas, not
cpusets.

The core patch is only in a local branch, so it goes into the build as a
`git archive` (only committed changes, no build artefacts, nothing to push):

```
scripts/local.sh src 2026-10-30_Peak-EWMA # HAPROXY_GIT=../haproxy by default
scripts/local.sh src -                    # back to HAPROXY_REF
```

```
scripts/local.sh build
scripts/local.sh up                       # DELAYS="5 5 5 50" SIZE=1k by default
scripts/local.sh bench                    # all algorithms (ALGOS), 3 runs each
scripts/local.sh bench DURATION=60 CLIENTS=128
scripts/local.sh bench DEGRADE_CLI=127.0.0.1:9104 DEGRADE_DELAY=200
scripts/local.sh delay 4 100              # set server 4 to 100 ms by hand
scripts/local.sh down
```

The stats page is on http://127.0.0.1:8404/stats. Results go to
`results/<timestamp>/`: `summary.csv`, the h2load output and the
compressed per-request logs.

## On MKS (or any cluster)

The test measures latency, so the roles run on separate nodes: anything
that competes for CPU with the load balancer, h2load or the servers adds
latency spikes, and those are exactly what Peak EWMA reacts to. For the
same reason, every pod requests what it limits (Guaranteed QoS), and the
limits are high enough that CFS throttling does not add latency.

| Node pool | Nodes | Flavor | Pods | CPU per pod |
|---|---|---|---|---|
| `load` | 1 | c3-8 | the bench Job (h2load, `THREADS=2`) | 2 |
| `lb` | 2 | c3-8 | 2 × lb (`NBTHREAD=3`), one per node (anti-affinity) | 3 |
| `be` | 3 | c3-8 | be-0 .. be-31 (StatefulSet), spread evenly | 0.2 (haterm) + 0.1 (shim) |

C3 is the compute optimized family of OVHcloud (4 vCPU, 8 GB for c3-8);
check the sizes and prices in the OVHcloud price list. Every 8th server
(`SLOW_EVERY=8`: be-7, be-15, be-23, be-31) answers in 50 ms, the others in
5 ms. The lb Deployment uses the `Recreate` strategy, since a second pod
with 3 CPUs does not fit on a c3-8 during a rolling update.

The server names are FQDNs (`be-0.be.peak-ewma.svc.cluster.local`): the
resolvers of HAProxy do not apply the search domains of `resolv.conf`, and
the short name `be-0.be` would be looked up in the public DNS (`.be` is a
top level domain).

The manifests select the pools with `nodeSelector: nodepool: <pool>`.
Check the label your nodes carry (`kubectl get nodes --show-labels`) and
adapt it in [k8s/](k8s/) if it differs.

1. Push both container images to a registry the cluster can pull from and set their
   names in [kustomization.yaml](kustomization.yaml).
2. `kubectl apply -k .`
3. `kubectl -n peak-ewma logs -f job/bench`
4. Copy the results while the pod waits (`KEEP`, 600 s):
   `kubectl -n peak-ewma cp <bench-pod>:/results ./results`

To run it again: `kubectl -n peak-ewma delete job bench && kubectl apply -k .`

[k8s/bench-job.yaml](k8s/bench-job.yaml) slows a fast server (`be-2`) down
from 5 to 100 ms 10 s into each run (`DEGRADE_CLI`), runs 32 and 128
clients (`LOADS`), and only the Lua and core variants (`ALGOS`; remove the
line for all algorithms).

The shim CLI (`:9101`) has the admin level over TCP, so the bench job can
change the delay: this is a test setup, do not expose it.

## Reading the results

`summary.csv` has one line per run: requests per second, failed requests,
mean, p50, p90, p99, p99.9 and max latency in ms, and the share of each
server in the requests of that run.

With one slow server (`5 5 5 50`) a latency-aware choice should send fewer
requests to `s4` than `random(2)`, and the p99 should drop. With
`DEGRADE_CLI`, the interesting part is how fast each algorithm moves away
from the server that becomes slow, and how fast it comes back after the
run.

## Results

32 servers (4 at 50 ms, the others at 5 ms, be-2 slowed down during each
run), 2 load balancers, 128 clients, 3 runs of 30 s each on OVH MKS,
2026-10-30. "slow" is the share of the requests sent to the 4 slow
servers, "idle" the `Idle_pct` of the two load balancers.

| Algorithm | slow | mean | p99 | req/s | idle |
|---|---|---|---|---|---|
| random(2) | 4.0% | 8.2 ms | 52 ms | 15537 | 59/70% |
| leastconn | 2.0% | 7.0 ms | 51 ms | 18098 | 59/61% |
| Lua, 2 draws | 1.67% | 7.3 ms | 51 ms | 17298 | 57/59% |
| random(2) peak-ewma, weight 100 | 1.63% | 6.8 ms | 51 ms | 18674 | 61/62% |
| Lua, 3 draws | 0.23% | 6.5 ms | 13 ms | 19351 | 51/39% |
| random(3) peak-ewma, weight 100 | 0.40% | 6.2 ms | 8.3 ms | 20355 | 58/58% |
| Lua, all servers | 0.0% | 6.9 ms | 12 ms | 18286 | 24/10% |

Comparing all servers ("Lua, all servers", :8083) sends no request at all to
the slow servers, but it is not the best variant: all requests chase the
server that looks cheapest right now (herding), so the fast servers got
between 1.1% and 5.4% of the requests instead of about 3.6% with 32
clients, and the full scan in Lua costs the most CPU (10 to 24% idle at 128
clients, against about 60% for the core variants). 3 random draws come
close to it in distribution and beat it in throughput and p99, which is why
the core implementation has no "compare all servers" variant.

The core lines include the patch that draws again when a draw returns the
best server so far (msg47703 above). Without it and with weight 1, the core
implementation sent 2.5% (2 draws) and 0.5% (3 draws) of the requests to the
slow servers: `random` could draw the same server twice, and with 16 points
per server the shares of the hash ring range from 2.0% to 4.1%. The Lua
prototype draws distinct servers uniformly, which is why it did better at
first.

Lessons about the test bed itself:

- Check `Idle_pct` of the load balancer: the first runs with 64 clients
  and 4 streams on 2 threads measured its CPU, not the algorithms.
- The Lua prototype fails silently with variable names containing `-`
  (`set_var()` refuses them): the server names are sanitized now.
- h2load closes its connections at the end of each run: these client
  aborts must not count as server failures.

## License

MIT, see [LICENSE](LICENSE).
