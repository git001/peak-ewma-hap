#!/bin/sh
# Runs h2load against each algorithm of the load balancer and summarizes
# throughput, latency percentiles and the share of each server.
#
# Runs inside the h2load image (sh, awk, sort, curl, socat). All settings
# come from the environment:
#
#   LB_HOST        load balancer host                  127.0.0.1
#   ALGOS          "<name>:<port> ..."                 random:8080 pewma:8081
#                                                      pewma3:8084 leastconn:8082
#                                                      pewmafull:8083 core2:8085
#                                                      core3:8086
#   DURATION       measured seconds per run            30
#   WARMUP         warm-up seconds per run             5
#   CLIENTS        h2load -c                           64
#   STREAMS        h2load -m (streams per client)      4
#   LOADS          "<clients>x<streams> ...": run everything once per load,
#                  e.g. "32x1 128x1"                    $CLIENTS x $STREAMS
#   THREADS        h2load -t                           2
#   REPEAT         runs per algorithm                  3
#   LB_STATS_HOST  name resolving to every load balancer pod (stats are
#                  summed over all of them)               $LB_HOST
#   LB_INSTANCES   load balancer pods to wait for          1
#   SLOW_EVERY     server be-<i> is slow if i % n == n-1    4
#   DEGRADE_CLI    "<host>:<port>" of a shim CLI: slow this server down
#                  DEGRADE_AT seconds into each run, restore it afterwards
#   DEGRADE_SERVER name of that server in the stats (be-<i>), for its share
#   DEGRADE_AT     seconds                             10
#   DEGRADE_DELAY  delay while degraded                200
#   RESTORE_DELAY  delay after the run                 5
#   OUT            results directory                   /results
set -eu

LB_HOST="${LB_HOST:-127.0.0.1}"
ALGOS="${ALGOS:-random:8080 pewma:8081 pewma3:8084 leastconn:8082 pewmafull:8083 core2:8085 core3:8086}"
DURATION="${DURATION:-30}"
WARMUP="${WARMUP:-5}"
CLIENTS="${CLIENTS:-64}"
STREAMS="${STREAMS:-4}"
THREADS="${THREADS:-2}"
REPEAT="${REPEAT:-3}"
LOADS="${LOADS:-${CLIENTS}x${STREAMS}}"
LB_STATS_HOST="${LB_STATS_HOST:-$LB_HOST}"
LB_INSTANCES="${LB_INSTANCES:-1}"
SLOW_EVERY="${SLOW_EVERY:-4}"
DEGRADE_CLI="${DEGRADE_CLI:-}"
DEGRADE_SERVER="${DEGRADE_SERVER:-}"
DEGRADE_AT="${DEGRADE_AT:-10}"
DEGRADE_DELAY="${DEGRADE_DELAY:-200}"
RESTORE_DELAY="${RESTORE_DELAY:-5}"
OUT="${OUT:-/results}/$(date +%Y%m%d_%H%M%S)"

SUMMARY="${OUT}/summary.csv"

log() {
	echo "[$(date +%H:%M:%S)] $*" >&2
}

# addresses of the load balancer pods (a headless service resolves to all)
lb_hosts() {
	case "$LB_STATS_HOST" in
	*[!0-9.]*)
		nslookup "$LB_STATS_HOST" 2>/dev/null |
			awk '/^Name:/ { f = 1 } f && /^Address/ { print $NF }' | sort -u ;;
	*)
		echo "$LB_STATS_HOST" ;;
	esac
}

# stats CSV of every load balancer pod, concatenated
stats_all() {
	for h in $(lb_hosts); do
		curl -fsS "http://${h}:8404/stats;csv" || true
	done
}

# total sessions per server of a backend, summed over the load balancer
# pods: "be-0=123 be-1=456 ..."
server_sessions() {
	stats_all | awk -F, -v be="$1" '
		$1 == be && $2 != "FRONTEND" && $2 != "BACKEND" { t[$2] += $8 }
		END { for (s in t) printf "%s=%s ", s, t[s] }'
}

set_delay() {
	host="${DEGRADE_CLI%:*}"
	port="${DEGRADE_CLI##*:}"
	echo "experimental-mode on; set var proc.delay str($1)" | \
		socat -t 2 stdio "tcp:${host}:${port}" >/dev/null
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

# shares between two snapshots: the slow servers (SLOW_EVERY), the degraded
# server, the fastest and the busiest server, and each server when there
# are at most 8: "slow=3.1% degraded=0.9% ..."
shares() {
	echo "$1" "|" "$2" | awk -v every="$SLOW_EVERY" -v deg="$DEGRADE_SERVER" '
		{
			before = 1
			for (i = 1; i <= NF; i++) {
				if ($i == "|") { before = 0; continue }
				split($i, kv, "=")
				if (before) b[kv[1]] = kv[2]; else { a[kv[1]] = kv[2]; n[++c] = kv[1] }
			}
			for (i = 1; i <= c; i++) { d[n[i]] = a[n[i]] - b[n[i]]; tot += d[n[i]] }
			if (!tot) { print "no-traffic"; exit }
			for (i = 1; i <= c; i++) {
				idx = n[i]; sub(/^be-/, "", idx)
				p = d[n[i]] * 100 / tot
				if (every > 0 && idx % every == every - 1) { slow += p; ns++ }
				else if (n[i] == deg) dg = p
				else { if (mx == "" || p > mx) mx = p; if (mn == "" || p < mn) mn = p }
			}
			printf "slow=%.1f%%(%d) ", slow, ns
			if (deg != "") printf "degraded=%.1f%% ", dg
			printf "fast_min=%.2f%% fast_max=%.2f%%", mn, mx
			if (c <= 8)
				for (i = 1; i <= c; i++)
					printf " %s=%.1f%%", n[i], d[n[i]] * 100 / tot
		}'
}

# wait until every load balancer pod answers and sees every server of the
# first backend UP (the pods may start in any order)
wait_ready() {
	be="be_${ALGOS%%:*}"
	i=0
	while [ "$i" -lt 180 ]; do
		lbs=$(lb_hosts | wc -l)
		down=$(stats_all 2>/dev/null | awk -F, -v be="$be" '
			$1 == be && $2 != "FRONTEND" && $2 != "BACKEND" { n++; if ($18 != "UP") d++ }
			END { print (n ? d + 0 : -1) }') || down=-1
		[ "${down:--1}" = 0 ] && [ "$lbs" -ge "$LB_INSTANCES" ] && return 0
		[ $((i % 10)) = 0 ] && log "waiting: $lbs/$LB_INSTANCES load balancers, servers of $be not UP: $down"
		sleep 1
		i=$((i + 1))
	done
	log "load balancer not ready after 180s"
	exit 1
}

wait_ready
mkdir -p "$OUT"
echo "load,algo,run,req_per_s,succeeded,failed,mean_ms,p50_ms,p90_ms,p99_ms,p999_ms,max_ms,server_share" > "$SUMMARY"
log "results in $OUT"

for load in $LOADS; do
CLIENTS="${load%x*}"
STREAMS="${load#*x}"
run=1
while [ "$run" -le "$REPEAT" ]; do
	for a in $ALGOS; do
		name="${a%%:*}"
		port="${a##*:}"
		be="be_${name}"
		tag="${name}_c${CLIENTS}m${STREAMS}_run${run}"

		before=$(server_sessions "$be")
		degrader=""
		if [ -n "$DEGRADE_CLI" ]; then
			( sleep $((WARMUP + DEGRADE_AT)); set_delay "$DEGRADE_DELAY" ) &
			degrader=$!
		fi

		log "$tag: h2load -c $CLIENTS -m $STREAMS -t $THREADS -D $DURATION"
		h2load -c "$CLIENTS" -m "$STREAMS" -t "$THREADS" \
			--warm-up-time="$WARMUP" -D "$DURATION" \
			--log-file="$OUT/$tag.log" \
			"http://${LB_HOST}:${port}/" > "$OUT/$tag.txt" 2>&1 || true

		if [ -n "$degrader" ]; then
			wait "$degrader" || true
			set_delay "$RESTORE_DELAY"
		fi
		after=$(server_sessions "$be")

		rps=$(awk '/^finished in/ { gsub(",", ""); print $4 }' "$OUT/$tag.txt")
		ok=$(awk '/^requests:/ { for (i = 1; i <= NF; i++) if ($(i + 1) ~ /^succeeded/) print $i }' "$OUT/$tag.txt")
		ko=$(awk '/^requests:/ { for (i = 1; i <= NF; i++) if ($(i + 1) ~ /^failed/) print $i }' "$OUT/$tag.txt")
		lat=$(percentiles "$OUT/$tag.log")
		share=$(shares "$before" "$after")

		echo "${load},${name},${run},${rps:-0},${ok:-0},${ko:-0},${lat},${share}" >> "$SUMMARY"
		log "$tag: ${rps:-0} req/s, mean,p50,p90,p99,p999,max ms = $lat, $share"
		# the log files get large, keep only the summary of each run
		gzip -f "$OUT/$tag.log"
	done
	run=$((run + 1))
done
done

column -s, -t "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
