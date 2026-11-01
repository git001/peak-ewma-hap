#!/bin/sh
# The 2019 test (do-bench.sh of https://github.com/haproxytech/bench-algo-p2c)
# against the MyTime edge: for each contention level and each algorithm, a
# fixed number of requests with clients added step by step, then the
# maximum load of every service.
#
# Load generators (GEN):
#   haload   HAProxy's load generator, closest to inject of 2019: HTTP/1.1,
#            users added over a soft start, a new connection whenever the
#            edge closes one (the services answer with HTTP/1.0 and close
#            the connection to mark the end of the response, which the
#            edge passes on to an HTTP/1 client)
#   h2load   speaks HTTP/2 (h2c) to the edge, because over HTTP/1 it does
#            not reconnect after such a close; over HTTP/2 the edge ends
#            the stream and the client connection stays. Behind the edge
#            everything is HTTP/1.0 as with haload.
#
# For each run it sets "<algo> <cores>" on the edge; the nodes restart their
# sidecars with it (and their services when the cores change), which also
# resets the counters, as the restart of the sidecars in do-bench.sh did.
#
# Files per run <algo>_cpu<cores>, for mytime/plot.sh:
#   .txt      output of the load generator
#   .series   second, completed requests, mean response time in ms
#   .load     node, service, maximum concurrent connections to the service
#             (smax of the inbound server of its sidecar, as do-report.sh),
#             requests
#   .pctl     (haload) percentiles: pctl tail invtail ttfbcnt ttfb(ms)
#             ttlbcnt ttlb(ms), for the percentile chart of mytime/plot.sh
#   .samples  node, epoch, CPU user sys idle iowait steal (% of the VM),
#             TCP sockets inuse orphan timewait, one line per node and
#             second of the run (:9000/samples of the nodes)
#
# The summary also counts, over all nodes, the connections the kernel
# dropped because a listen queue was full (ListenOverflows: the services
# of the original listen with a backlog of 5), the SYNs sent again
# (TCPSynRetrans), and the connection retries of the sidecars and of the
# edge (wretr: "timeout connect 4s" expired, or a reused connection was
# closed).
#
# Runs inside the MyTime image (haload) or the h2load image (h2load), with
# sh, awk, sort, curl and socat. Environment:
#
#   GEN          load generator: haload or h2load           haload
#   EDGE_HOST    edge host                                  edge
#   APP_COUNT    number of nodes                            6
#   APP_ADDR     printf format of the address of node i     app-%d.app
#   LEVELS       cores per node, one pass each              4 2 1
#   ALGOS        algorithms (see gen-cfg.sh)                rnd po2 rr lc ext pe2 pe3
#   CLIENTS      concurrent clients (inject -u 400)         400
#   RAMP         new clients per second (inject -s 500)     2
#   REQUESTS     requests per run (-n), "<n>" or            400000
#                "<cores>:<n> ..." per level
#   THREADS      threads of the load generator (-t)         2
#   PAUSE        seconds between the runs                   10
#   OUT          results directory                          /results
set -eu

GEN="${GEN:-haload}"
EDGE_HOST="${EDGE_HOST:-edge}"
APP_COUNT="${APP_COUNT:-6}"
APP_ADDR="${APP_ADDR:-app-%d.app}"
LEVELS="${LEVELS:-4 2 1}"
ALGOS="${ALGOS:-rnd po2 rr lc ext pe2 pe3}"
CLIENTS="${CLIENTS:-400}"
RAMP="${RAMP:-2}"
REQUESTS="${REQUESTS:-400000}"
THREADS="${THREADS:-2}"
PAUSE="${PAUSE:-10}"
OUT="${OUT:-/results}/$(date +%Y%m%d_%H%M%S)"

SUMMARY="${OUT}/summary.csv"
# service port name
SERVICES="2001:time 2002:user 2003:log 2004:mytime"

log() {
	echo "[$(date +%H:%M:%S)] $*" >&2
}

app_host() {
	# shellcheck disable=SC2059
	printf "$APP_ADDR" "$1"
}

requests_of() {
	case "$REQUESTS" in
	*:*) echo "$REQUESTS" | tr ' ' '\n' | awk -F: -v c="$1" '$1 == c { print $2 }' ;;
	*) echo "$REQUESTS" ;;
	esac
}

set_run() {
	echo "experimental-mode on; set var proc.algo str($1); set var proc.cores str($2)" |
		socat -t 2 stdio "tcp:${EDGE_HOST}:9100" > /dev/null 2>&1 || true
}

# set "<algo> <cores>" on the edge and wait until every sidecar runs it and
# the edge sees every node UP again; it is set again at each round, in case
# the edge was not up yet or restarted (it starts with "po2 4")
wait_run() {
	want="$1 $2"
	i=0
	while [ "$i" -lt 300 ]; do
		set_run "$1" "$2"
		ok=0
		n=0
		while [ "$n" -lt "$APP_COUNT" ]; do
			h=$(app_host "$n")
			for s in $SERVICES; do
				got=$(curl -fsS -m 2 "http://${h}:3${s%%:*}/algo" 2>/dev/null || true)
				[ "$got" = "$want" ] && ok=$((ok + 1))
			done
			n=$((n + 1))
		done
		up=$(curl -fsS -m 2 "http://${EDGE_HOST}:8404/stats;csv" 2>/dev/null |
			awk -F, '$1 == "mytime" && $2 ~ /^srv/ && $18 == "UP" { n++ } END { print n + 0 }')
		if [ "$ok" -eq $((APP_COUNT * 4)) ] && [ "$up" -eq "$APP_COUNT" ]; then
			return 0
		fi
		[ $((i % 10)) = 0 ] && log "waiting for \"$want\": $ok/$((APP_COUNT * 4)) sidecars, $up/$APP_COUNT nodes UP"
		sleep 1
		i=$((i + 1))
	done
	log "not ready after 300s"
	exit 1
}

# "<node> <service> <smax> <requests>" of the inbound server of every
# sidecar
load_all() {
	n=0
	while [ "$n" -lt "$APP_COUNT" ]; do
		h=$(app_host "$n")
		for s in $SERVICES; do
			curl -fsS -m 5 "http://${h}:3${s%%:*}/;csv" 2>/dev/null |
				awk -F, -v node="app-$n" -v svc="${s#*:}" '
					$1 == "inbound" && $2 == "srv" { print node, svc, $6, $8 }'
		done
		n=$((n + 1))
	done
}

# "<ListenOverflows> <TCPSynRetrans>" summed over the nodes (:9000/netstat)
tcp_counters() {
	n=0
	while [ "$n" -lt "$APP_COUNT" ]; do
		curl -fsS -m 5 "http://$(app_host "$n"):9000/netstat" 2>/dev/null
		n=$((n + 1))
	done | awk '
		$1 == "TcpExt:" && !h { for (i = 2; i <= NF; i++) k[i] = $i; h = 1; next }
		$1 == "TcpExt:" { for (i = 2; i <= NF; i++) v[k[i]] += $i; h = 0 }
		END { print v["ListenOverflows"] + 0, v["TCPSynRetrans"] + 0 }'
}

# the samples of all nodes between two dates: "<node> <sample line>"
samples() {
	n=0
	while [ "$n" -lt "$APP_COUNT" ]; do
		curl -fsS -m 10 "http://$(app_host "$n"):9000/samples" 2>/dev/null |
			awk -v node="app-$n" -v a="$1" -v b="$2" '$1 >= a && $1 <= b { print node, $0 }'
		n=$((n + 1))
	done
}

# connection retries (wretr) of all backends: of every sidecar with
# "nodes", of the edge with "edge"
retries() {
	if [ "$1" = edge ]; then
		curl -fsS -m 5 "http://${EDGE_HOST}:8404/stats;csv" 2>/dev/null
	else
		n=0
		while [ "$n" -lt "$APP_COUNT" ]; do
			for s in $SERVICES; do
				curl -fsS -m 5 "http://$(app_host "$n"):3${s%%:*}/;csv" 2>/dev/null
			done
			n=$((n + 1))
		done
	fi | awk -F, '$2 == "BACKEND" { r += $16 } END { print r + 0 }'
}

# busiest node / mean of the requests per service: "mytime=1.02 ..."
fairness() {
	awk '
		{ t[$2] += $4; c[$2]++; if ($4 > m[$2]) m[$2] = $4 }
		END {
			split("mytime log time user", o, " ")
			for (i = 1; i <= 4; i++)
				printf "%s%s=%.2f", (i > 1 ? " " : ""), o[i],
					t[o[i]] ? m[o[i]] * c[o[i]] / t[o[i]] : 0
		}' "$1"
}

# requests per second and mean response time per second of the run, by
# completion time, from an h2load --log-file
series() {
	# the log is not sorted: the first pass finds the start of the run
	awk -F'\t' '
		NR == FNR { if (NR == 1 || $1 < t0) t0 = $1; next }
		{ s = int(($1 + $3 - t0) / 1000000); n[s]++; sum[s] += $3; if (s > m) m = s }
		END { for (s = 0; s <= m; s++) printf "%d %d %.3f\n", s, n[s], n[s] ? sum[s] / n[s] / 1000 : 0 }
	' "$1" "$1"
}

# latency percentiles in ms from an h2load --log-file
# (columns: start time, status, duration in microseconds)
percentiles() {
	awk -F'\t' '{ print $3 }' "$1" | sort -n | awk '
		{ v[NR] = $1; sum += $1 }
		END {
			if (NR == 0) { print "0,0,0,0,0,0"; exit }
			p50 = v[int(NR * 0.50) > 0 ? int(NR * 0.50) : 1]
			p90 = v[int(NR * 0.90) > 0 ? int(NR * 0.90) : 1]
			p99 = v[int(NR * 0.99) > 0 ? int(NR * 0.99) : 1]
			p999 = v[int(NR * 0.999) > 0 ? int(NR * 0.999) : 1]
			printf "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n", sum / NR / 1000,
				p50 / 1000, p90 / 1000, p99 / 1000, p999 / 1000, v[NR] / 1000
		}'
}

# h2load with a log of every request; sets dur rps ok ko lat
run_h2load() {
	log "$tag: h2load -c $CLIENTS -t $THREADS -n $req --rate=$RAMP"
	h2load -c "$CLIENTS" -m 1 -t "$THREADS" -n "$req" --rate="$RAMP" \
		--log-file="$OUT/$tag.log" \
		"http://${EDGE_HOST}:2004/MyTime/bob" > "$OUT/$tag.txt" 2>&1 || true
	series "$OUT/$tag.log" > "$OUT/$tag.series"
	dur=$(awk '/^finished in/ { gsub(/[s,]/, "", $3); print $3 }' "$OUT/$tag.txt")
	rps=$(awk '/^finished in/ { gsub(",", ""); print $4 }' "$OUT/$tag.txt")
	ok=$(awk '/^requests:/ { for (i = 1; i <= NF; i++) if ($(i + 1) ~ /^succeeded/) print $i }' "$OUT/$tag.txt")
	ko=$(awk '/^requests:/ { for (i = 1; i <= NF; i++) if ($(i + 1) ~ /^failed/) print $i }' "$OUT/$tag.txt")
	lat=$(percentiles "$OUT/$tag.log")
	gzip -f "$OUT/$tag.log"
}

# haload as inject -u <users> -s <ramp-up> -F -l; its raw report (-ll -hs)
# has one line per second: time conns tot_conn tot_req tot_bytes err thr
# cps rps Bps bps ttfb(us) ttlb(us) 1xx 2xx 3xx 4xx 5xx, and -P adds the
# percentiles "pctl tail invtail ttfbcnt ttfb(ms) ttlbcnt ttlb(ms)" at the
# end. Sets dur rps ok ko lat.
run_haload() {
	soft=$((CLIENTS / RAMP))
	# haload takes an address, not a name
	ip=$(getent hosts "$EDGE_HOST" 2>/dev/null | awk '{ print $1; exit }')
	[ -n "$ip" ] || ip=$(nslookup "$EDGE_HOST" 2>/dev/null |
		awk '/^Name:/ { f = 1 } f && /^Address/ { print $NF; exit }')
	log "$tag: haload -h1 -u $CLIENTS -s $soft -F -t $THREADS -n $req ($EDGE_HOST = $ip)"
	haload -ll -hs -P -F -t "$THREADS" -u "$CLIENTS" -s "$soft" -n "$req" \
		-h1 "http://${ip:-$EDGE_HOST}:2004/MyTime/bob" > "$OUT/$tag.txt" 2>&1 || true
	# the per-second lines: 18 fields, starting with the date
	awk 'NF == 18 && $1 ~ /^[0-9]+$/' "$OUT/$tag.txt" > "$OUT/$tag.sec"
	awk 'NR == 1 { t0 = $1 - 1 }
		{ printf "%d %s %.3f\n", $1 - t0, $9, $13 == "-" ? 0 : $13 / 1000 }' \
		"$OUT/$tag.sec" > "$OUT/$tag.series"
	set -- $(awk '
		NR == 1 { t0 = $1 - 1 }
		{ t = $1; req = $4; err = $6; ok += $15; ko += $17 + $18
		  if ($13 != "-") { w += $9; sum += $9 * $13 } }
		END { d = t - t0; printf "%d %.2f %d %d %.3f\n", d, d ? req / d : 0, ok, err + ko, w ? sum / w / 1000 : 0 }
	' "$OUT/$tag.sec")
	dur="$1" rps="$2" ok="$3" ko="$4" mean="$5"
	lat="$mean,$(awk '
		$1 == "#pctl" { p = 1; next }
		p && NF == 7 {
			if (!a && $1 >= 50) a = $7
			if (!b && $1 >= 90) b = $7
			if (!c && $1 >= 99) c = $7
			if (!d && $1 >= 99.9) d = $7
			m = $7
		}
		END { printf "%.3f,%.3f,%.3f,%.3f,%.3f", a, b, c, d, m }' "$OUT/$tag.txt")"
	awk '$1 == "#pctl" { p = 1; next } p && NF == 7' "$OUT/$tag.txt" > "$OUT/$tag.pctl"
	gzip -f "$OUT/$tag.txt"
}

mkdir -p "$OUT"
echo "cores,algo,requests,duration_s,req_per_s,succeeded,failed,mean_ms,p50_ms,p90_ms,p99_ms,p999_ms,max_ms,max_load,listen_overflows,syn_retrans,retries_sidecars,retries_edge,steal_avg,steal_max,timewait_max,fairness" > "$SUMMARY"
log "results in $OUT ($GEN)"

for cores in $LEVELS; do
	req=$(requests_of "$cores")
	for algo in $ALGOS; do
		tag="${algo}_cpu${cores}"

		wait_run "$algo" "$cores"

		set -- $(tcp_counters) $(retries edge)
		tcp0_ovf="$1" tcp0_syn="$2" edge0="$3"
		t0=$(date +%s)
		"run_$GEN"
		samples "$t0" "$(date +%s)" > "$OUT/$tag.samples"
		set -- $(awk '{ s += $7; n++; if ($7 > m) m = $7; if ($10 > tw) tw = $10 }
			END { printf "%.1f %.1f %d\n", n ? s / n : 0, m, tw }' "$OUT/$tag.samples")
		steal_avg="$1" steal_max="$2" tw_max="$3"
		load_all > "$OUT/$tag.load"
		set -- $(tcp_counters) $(retries edge) $(retries nodes)
		ovf=$(($1 - tcp0_ovf)) syn=$(($2 - tcp0_syn)) redge=$(($3 - edge0)) rside="$4"

		# the highest bar of the load chart: the busiest node, all services
		top=$(awk '{ t[$1] += $3 } END { for (n in t) if (t[n] > m) m = t[n]; print m + 0 }' "$OUT/$tag.load")
		fair=$(fairness "$OUT/$tag.load")

		echo "${cores},${algo},${req},${dur:-0},${rps:-0},${ok:-0},${ko:-0},${lat},${top},${ovf},${syn},${rside},${redge},${steal_avg},${steal_max},${tw_max},${fair}" >> "$SUMMARY"
		log "$tag: ${dur:-0}s ${rps:-0} req/s ok=${ok:-0} failed=${ko:-0}, mean,p50,p90,p99,p999,max ms = $lat, max load $top, listen overflows $ovf, syn retrans $syn, retries sidecars $rside edge $redge, steal avg/max $steal_avg/$steal_max %, timewait max $tw_max, requests max/mean $fair"
		sleep "$PAUSE"
	done
done

column -s, -t "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
