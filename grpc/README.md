# gRPC with a fleet of JVMs

The case peak EWMA was built for in Finagle: services on JVMs, which become
slow for a while without having more requests (garbage collection), and
balancers that each only see their own share of the traffic. Does `random
peak-ewma` beat `leastconn` here?

**Result: no.** With GC pauses of 20 to 50 ms, leastconn and peak EWMA are
within 1 ms at p99, with one central HAProxy as well as with one sidecar
per client. See [Results](#results).

## The test bed

```
                 MODE central                          MODE sidecar
 ghz x 6 ──► lb (HAProxy) ──► svc-0..11    ghz ─► HAProxy (localhost) ─┐
                                           ghz ─► HAProxy (localhost) ─┼─► svc-0..11
                                           ...   (one per client)     ─┘
```

- **Services**: [service/](service/), Spring Boot 4.1 with its gRPC server
  (Netty, h2c on 9090, no TLS), Java 25. One unary call `work.Work/Run`
  burns `cpu_us` of CPU (2 ms), allocates `alloc_kb` of garbage (256 KiB)
  and replaces one entry of a cache of `RETAIN_MB` (100 MiB). The replaced
  entries have been promoted, so the old generation fills up and the JVM
  runs full collections on its own, about 3 per second and service on MKS.
  All services run with the same settings (256 MiB heap, Parallel GC): a
  typical fleet, the pauses fall at random on all of them.
- **HAProxy**: [gen-cfg.sh](gen-cfg.sh), one backend `be_<algo>` per
  algorithm (`rr`, `lc`, `rnd`, `po2`, `pe2`, `pe3`), all servers with
  `proto h2` and weight 100. The gRPC metadata `x-algo` selects the
  backend, so one configuration serves all the runs, without any reload.
- **Clients**: ghz, one connection per client (as a gRPC client usually
  does) with up to 64 concurrent requests, at a fixed rate. Each client
  pod also runs its own HAProxy on 127.0.0.1, used in the `sidecar` runs.
- **Runs** ([bench.sh](bench.sh)): client 0 sets the start date on the lb
  (`proc.start`), the others wait for it, so all clients run at the same
  time. An unmeasured warmup (JIT, heap sizing), then for each topology
  each algorithm for `DURATION`, in `REPEAT` rounds with the order of the
  algorithms rotated.

| Name | `balance` |
|---|---|
| `lc` | `leastconn` |
| `po2` | `random(2)` |
| `pe2` | `random(2) peak-ewma` |
| `pe3` | `random(3) peak-ewma` |
| `rr`, `rnd` | `roundrobin`, `random(1)` (warmup, not measured by default) |

## Files

| File | |
|---|---|
| [service/](service/) | the gRPC service and its [Containerfile](service/Containerfile) (`peak-ewma-grpc-svc`) |
| [Containerfile](Containerfile) | `peak-ewma-grpc`: the HAProxy image of this repository plus ghz; roles `lb` and `client` |
| [gen-cfg.sh](gen-cfg.sh), [entrypoint.sh](entrypoint.sh) | HAProxy configuration and roles |
| [bench.sh](bench.sh) | one client: synchronized ghz runs, `show stat` after each run |
| [summary.py](summary.py) | one line per run and per algorithm: exact percentiles over all requests of all clients, share of each server, GC pauses during the run |
| [plot-data.py](plot-data.py), [plot.sh](plot.sh) | the charts |
| [local.sh](local.sh) | local run with podman |
| [kustomization.yaml](kustomization.yaml), [k8s/](k8s/) | MKS (or any cluster), namespace `grpc` |
| [get-all-results.sh](get-all-results.sh) | copies the results and the GC logs, prints the summary, draws the charts |

### Switches of the bench Job

| Variable | | Default |
|---|---|---|
| `MODES` | topologies, one after the other | `central sidecar` |
| `ALGOS` | algorithms | `lc po2 pe2 pe3` |
| `WARMUP`, `DURATION`, `PAUSE`, `REPEAT` | warmup, length of a run, pause, rounds | `60s`, `60s`, `15`, `2` |
| `RPS`, `CONC`, `CONNS` | rate, concurrent requests and connections per client | `1300`, `64`, `1` |
| `CPU_US`, `ALLOC_KB` | work per request on the service | `2000`, `256` |

The JVM settings are `JAVA_OPTS` and `RETAIN_MB` of the services in
[k8s/svc.yaml](k8s/svc.yaml).

## Local run with podman

```sh
scripts/local.sh src && scripts/local.sh build   # HAProxy image
grpc/local.sh build
grpc/local.sh up
CLIENTS=2 grpc/local.sh bench WARMUP=10s DURATION=15s 'ALGOS=lc pe3' CONC=8
grpc/plot.sh results/grpc/<dir>
grpc/local.sh down
```

## On MKS (or any cluster)

Node pools as for [MyTime](../mytime/README.md): `app` (6 x c3-16, two
services with 2 CPU each per node), `lb` (c3-16, the central HAProxy and
some clients), `load` (c3-8, the other clients). The MyTime pods must not
run at the same time.

1. Push `peak-ewma-grpc-svc` and `peak-ewma-grpc` and make the packages
   public.
2. `kubectl apply -k grpc/`
3. Follow client 0: `kubectl -n grpc logs -f job/bench` (about 23 minutes
   with the defaults)
4. `grpc/get-all-results.sh <label>` while the client pods still run
   (`KEEP`)
5. `kubectl delete namespace grpc`

## Results

OVH MKS, 2026-11-01, HAProxy 3.5-dev10 with the peak EWMA patches: 12
services, 6 clients at 1300 requests per second each (7800 in total,
about 65 % of the CPU of the services), 2 rounds of 60 s per algorithm,
about 936000 requests per line. GC: about 3 full collections per second
and service, 20 to 50 ms each, the same number in every run.

| | mean | p90 | p99 | p99.9 | max | share max/min | smax per server |
|---|---|---|---|---|---|---|---|
| central lc | **3.36 ms** | **3.39** | **24.4** | 33.7 | 49.3 | 8.4 / 8.3 % | **5** |
| central pe3 | 3.44 ms | 3.52 | 24.7 | **32.5** | 42.7 | 9.6 / 7.7 % | 7-12 |
| central pe2 | 3.60 ms | 3.66 | 27.2 | 34.1 | 44.9 | 9.1 / 7.7 % | 9-13 |
| central po2 | 4.21 ms | 4.24 | 33.4 | 42.4 | 62.8 | 8.4 / 8.3 % | 15-21 |
| sidecar lc | **3.45 ms** | **3.53** | 23.3 | 28.1 | 36.5 | 8.4 / 8.3 % | **12** |
| sidecar po2 | 3.61 ms | 3.90 | **23.2** | **27.5** | 39.5 | 8.3 / 8.3 % | 18-21 |
| sidecar pe2 | 3.63 ms | 3.91 | 23.5 | 28.2 | 37.7 | 9.4 / 7.5 % | 16-27 |
| sidecar pe3 | 3.63 ms | 3.94 | 23.9 | 32.0 | 49.1 | 9.0 / 7.6 % | 16-25 |

(smax in sidecar mode: the sum over the six sidecars.) Compare within a
topology only: `central` ran first, while the JVMs still collected more.

- **No advantage for peak EWMA**, neither with the full view of a central
  balancer nor with the partial view of a sidecar. In sidecar mode all
  four are within 1 ms at p99; leastconn has the best mean in both.
- **Why**: a GC pause hits the requests already on the server, no
  algorithm avoids that. What an algorithm can do is to stop sending to a
  server that is paused. Its outstanding requests rise at once, and
  leastconn, which compares all 12 servers, never let more than 5 requests
  pile up on a server (central). Peak EWMA sees the outstanding requests
  too, but compares only 2 or 3 drawn servers, and its estimate of the
  paused server only rises with the first slow response, when the pause is
  over: up to 12 piled up, with plain random(2) up to 21. With the central
  balancer random(2) peak-ewma beat plain random(2), so the estimate adds
  something, but not enough to make up for the sample. These runs do not
  separate the sample size from the late signal. Two runs would:
  random(3) without peak-ewma shows what the third draw brings, and peak
  EWMA over all 12 servers (the Lua prototype with 0 draws) what the
  estimate brings without a sample.
- In the percentile chart of the sidecar mode, the step of the GC pauses
  (from 3 ms to over 20 ms) starts at about p96 with leastconn and p94
  with the others: fewer requests run into a pause.
- Peak EWMA spreads the requests less evenly (7.5 to 9.6 % per server
  instead of 8.3 %): with identical services this is noise of the
  estimates, not a gain.
- `random(2)` alone with one central balancer is the weakest (p99 33 ms):
  two draws too often both hit loaded servers.

Not tested yet: long pauses (a large heap with pauses of seconds, the
Finagle case of the early 2010s), e.g. `-Xmx2g` with `RETAIN_MB=1500`.

Charts per topology in the results directory: `pctl_<mode>.png`
(response time over the percentiles), `p99_<mode>.png` (p99 of each
second), `share_<mode>.png` (share of each server) and
`load-per-server_<mode>.png` (smax of each server, stacked per sidecar).
