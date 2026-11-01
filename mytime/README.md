# MyTime: the 2019 "power of two" test, rebuilt on Kubernetes

A rebuild of the test that Willy Tarreau described in
[Test driving "power of two random choices" load balancing](https://www.haproxy.com/blog/power-of-two-load-balancing)
(HAProxy blog, February 2019), with the original services and settings of
[haproxytech/bench-algo-p2c](https://github.com/haproxytech/bench-algo-p2c)
(commit `cab55f8`), extended with the core `balance random(<draws>)
peak-ewma` of this repository.

The original repository has no license file, so its files are not copied
here: [Containerfile](Containerfile) clones it at build time.

The opposite of the test bed in the repository root: there, the slow
servers get a fixed delay; here, slowness comes from CPU contention, it
depends on the load and moves around, and many sidecar load balancers each
see only their own share of the traffic.

## The application

```
                         ┌─────────────── node app-<i> (x6) ───────────────┐
h2load/haload ──► edge ──┼─► sidecar :2004 ──► mytime ─┬─► sidecar ──► ...  │
                (lc)     │                             │   (outbound,       │
                         │   sidecar :2003 ──► log ────┤    the algorithm   │
                         │   sidecar :2002 ──► user    │    under test)     │
                         │   sidecar :2001 ──► time    │                    │
                         └──────────────────────────────────────────────────┘
```

- Four Python services (`svc-*.py` of the original, `http.server`, CPython
  with the GIL): **mytime** calls user, time and log; **log** calls user
  and time. They answer with HTTP/1.0 and close the connection, and open a
  new connection (`urllib`) for each call.
- Each service has its own **HAProxy sidecar** (one per service, four per
  node): *inbound* `:200X` to the local service on `127.0.0.2:1200X`,
  *outbound* `127.0.0.3:2200X` for the calls of the service, routed by path
  to the services of all six nodes. **The outbound backends run the
  algorithm under test.** Stats on `:3200X`.
- A service and its sidecar are pinned to one core with `taskset`, as
  `service.sh` and `sidecar.sh` of the original. Contention levels: 4
  cores (one per service), 2 cores (time+log, user+mytime) or 1 core for
  all four.
- The **edge** HAProxy balances the clients over the mytime service of
  the six nodes with `leastconn`, as `edge.cfg` of the original, for all
  algorithms.
- Fairness ("maximum server load") is `smax` of the inbound server of each
  sidecar, as `do-report.sh` of the original.

Algorithms (names of the original files `sidecar.cfg.<name>`):

| Name | `balance` | |
|---|---|---|
| `rnd` | `random(1)` | |
| `po2` | `random` (2 draws) | power of two choices |
| `rr` | `roundrobin` | |
| `lc` | `leastconn` | |
| `ext` | `leastconn` on the edge | the sidecars send everything through the edge |
| `pe2` | `random(2) peak-ewma` | needs the peak-ewma branch |
| `pe3` | `random(3) peak-ewma` | needs the peak-ewma branch |

## Files

| File | |
|---|---|
| [Containerfile](Containerfile) | `peak-ewma-mytime`: the HAProxy image of the test bed plus Python, taskset, curl and the original services |
| [gen-cfg.sh](gen-cfg.sh) | HAProxy configuration of a sidecar or of the edge, with the settings of the original |
| [entrypoint.sh](entrypoint.sh) | roles `node` (services, sidecars, switching, counters) and `edge` |
| [bench.sh](bench.sh) | all runs: each contention level with each algorithm |
| [plot.sh](plot.sh) | the charts, with gnuplot |
| [local.sh](local.sh) | local run with podman |
| [kustomization.yaml](kustomization.yaml), [k8s/](k8s/) | MKS (or any cluster) |
| [get-all-results.sh](get-all-results.sh) | copies the results and the cluster state, draws the charts |

## How a run works

The bench sets `"<algo> <cores>"` on the edge (CLI `:9100`, `set var`).
Each node polls it on `:8404/algo` every second and, on a change,
restarts its sidecars with the new algorithm, as `do-bench.sh` restarted
them, which also resets their counters, and moves the running services to
the new cores (`taskset -a -p`). The services are never restarted: the
original sets `allow_reuse_address` after `bind()`, so a new service
cannot bind while the closed connections of the old one are in
TIME_WAIT.

Then a fixed number of requests (`REQUESTS`) runs with 400 clients, a new
one every 500 ms (`inject -u 400 -s 500` of the original), so that a
better algorithm finishes sooner.

### Load generators (`GEN`)

- **haload** (default): HAProxy's own load generator (`make haload`),
  built from the same tree as HAProxy. Its options are close to `inject`
  of 2019 (`-u`, `-s`, `-F`, `-ll`), it speaks HTTP/1.1 and opens a new
  connection whenever the edge closes one, which is after each response:
  one connection per request, like inject.
- **h2load**: speaks HTTP/2 (h2c) to the edge. Over HTTP/1 it does not
  reconnect after the close of an HTTP/1.0 response without a length and
  counts the rest of the run as errors; HAProxy cannot turn such a
  response into a keep-alive one either (it drops a `content-length` set
  with `http-response set-header`). Over HTTP/2 the edge ends the stream
  and the client connection stays.

### Switches

| Variable | Where | | Default |
|---|---|---|---|
| `LEVELS` | bench Job | cores per node, one pass each | `4 2 1` |
| `ALGOS` | bench Job | algorithms | `rnd po2 rr lc ext pe2 pe3` |
| `REQUESTS` | bench Job | requests per run, also per level `"4:600000 2:400000 1:250000"` | |
| `GEN` | bench Job | `haload` or `h2load` (then also the h2load image) | `haload` |
| `MESH_PROTO` | app and edge | protocol between the proxies: `h1` as in 2019, or `h2` (h2c, `proto h2` without `ssl`, so no TLS) on long-lived multiplexed connections as in today's service meshes; the services always speak HTTP/1.0 to their own sidecar | `h1` |
| `BACKLOG` | app | listen backlog of the services; empty keeps the 5 of the original (socketserver default), a value runs the unchanged script with another `request_queue_size` | empty |
| `WEIGHT` | app and edge | weight of all servers | `1` (original) |

## Results and charts

Per run `<algo>_cpu<cores>`: `.txt` (load generator), `.series` (per
second), `.pctl` (haload percentiles), `.load` (smax per node and
service), `.samples` (per node and second: CPU of the VM including
**steal**, TCP sockets inuse/orphan/timewait of the pod). The summary adds
the connections dropped by full listen queues (`ListenOverflows`), the
SYNs sent again (`TCPSynRetrans`), the connection retries of the sidecars
and the edge (`wretr`), and the CPU steal.

Charts per level ([plot.sh](plot.sh)): the three of the original
(requests per second, response time, load per server), plus the response
time over the percentiles on a log scale (after `graph-h1load-pct.sh` of
[dpbench](https://github.com/dpbench/dpbench)) and the CPU steal.

## Local run with podman

```sh
scripts/local.sh src                  # HEAD of ../haproxy (HAPROXY_GIT)
scripts/local.sh build                # HAProxy image (with haterm, haload)
mytime/local.sh build
APP_COUNT=3 mytime/local.sh up        # node i pins to host cores 4i..4i+3
mytime/local.sh bench APP_COUNT=3 LEVELS=4 ALGOS='po2 pe2' CLIENTS=60 RAMP=20 REQUESTS=8000
mytime/plot.sh results/mytime/<dir> 4
mytime/local.sh down
```

## On MKS (or any cluster)

Node pools with the label `nodepool=<name>`: `app` 6 nodes with 8 vCPU
(c3-16, one test node each), `lb` 1 node (c3-16, the edge: a c3-8 has
too small a conntrack table and too little CPU for `ext`), `load` 1 node
(c3-8, the load generator). That is 60 vCPU: check the quota of the
project first.

1. Raise the connection tracking table of every node. With HTTP/1 and a
   connection per request on every hop, the default table fills up and
   the kernel drops SYNs (see below). This creates a privileged debug pod
   per node; the setting lasts until the node is replaced:
   ```sh
   for n in $(kubectl get nodes -o name); do
     kubectl debug "$n" --profile=sysadmin -it --image=docker.io/alpine:3.23 -- \
       sh -c 'sysctl -w net.netfilter.nf_conntrack_max=524288 net.netfilter.nf_conntrack_tcp_timeout_time_wait=30'
   done
   kubectl get pods -o name | grep node-debugger | xargs kubectl delete
   ```
2. Push the image (`peak-ewma-mytime`, built as above) and make the
   package public.
3. `kubectl apply -k mytime/`
4. Follow the run: `kubectl -n mytime logs -f job/bench`
5. `mytime/get-all-results.sh <label>` while the bench pod still runs
   (it stays `KEEP` seconds after the last run).
6. `kubectl -n mytime delete job bench` before the next
   `kubectl apply -k mytime/`. Do not apply while the Job runs: the
   ConfigMap with `bench.sh` would change under the running script.

## What we learned so far

- **The node's conntrack table decides the tail latency with HTTP/1.**
  Every request opens a new connection on every hop (the services answer
  with HTTP/1.0 and close). At about 1500 requests per second the edge
  opens about as many connections per second, and conntrack keeps each
  closed one 120 s: the table of the `lb` node (131072 entries on a c3-8)
  was full, the kernel dropped SYNs, and the clients waited for the SYN
  retransmit (1 s, then the `timeout connect 4s` of the original and a
  retry). p99 was about 1 s and p99.9 about 4 s for every algorithm, the
  health checks of the edge timed out (`L4TOUT`), and the `ext` run, which
  sends all the traffic through the edge, broke down. The counters inside
  the pods showed nothing: conntrack is counted per network namespace,
  only `kubectl debug node` showed it. After the change of step 1 the
  throughput went from about 1500 to over 2300 requests per second, but
  the load generator changed at the same time (h2load to haload), so
  this part still needs a run with h2load to be confirmed.
- **The listen backlog of 5 of the original services** drops connections
  too when a service is busy (`ListenOverflows`), but far fewer.
- **No network saturation**: about 0.7 MB/s and 7000 packets per second
  per pod, no drops on the interfaces, no data retransmits.
- `/proc/stat` is not namespaced: the CPU of a pod's samples is that of
  the whole VM, which makes the steal of noisy neighbours visible.
- Building haload showed two build bugs in HAProxy: `src/haload.c`
  includes `<openssl/ssl.h>` unconditionally (`doc/haload.txt` says it
  builds without `USE_OPENSSL`) and uses `SIGINT`/`SIG_DFL` without
  `<signal.h>` (fails with musl). The HAProxy image works around both
  (`USE_OPENSSL=1`, `ADDINC="-include signal.h"`).

## Differences to the original

- Kubernetes pods instead of six ARM boards; the services and their
  sidecars of a node in one container, pinned with `taskset`.
- The algorithm is switched at runtime instead of copying
  `sidecar.cfg.<name>` and restarting the sidecars by ssh; the sidecars
  are restarted all the same.
- The servers are DNS names of the StatefulSet (FQDNs: the resolvers of
  HAProxy do not apply the search domains), no health checks in the
  sidecars, as in the original.
- haload or h2load instead of inject; with h2load the first hop is HTTP/2.
- HAProxy 3.5-dev with the peak-ewma branch instead of 2.0-dev.
