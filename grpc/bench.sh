#!/bin/sh
# One client of the gRPC test bed: runs ghz once per algorithm, at the same
# time as all the other clients.
#
# Client 0 sets the start date on the central load balancer (proc.start),
# the others wait for it; run k then starts at start + k * (DURATION +
# PAUSE) on every client. The algorithm is selected with the gRPC metadata
# "x-algo" (see gen-cfg.sh), so nothing is restarted between the runs.
#
#   central   ghz -> load balancer -> services
#   sidecar   ghz -> own HAProxy on 127.0.0.1 -> services: each client only
#             knows its own streams and response times
#
# Per run in OUT/<index>/: <algo>.json (ghz, with every request),
# <algo>.sidecar.csv and, on client 0, <algo>.lb.csv ("show stat"); with
# REPEAT > 1 the runs are named <algo>_r<round>; all prefixed with <mode>_.
#
# Environment:
#   MODES       topologies, one after the other              "central sidecar"
#   LB_HOST     the central load balancer                   lb
#   INDEX       index of this client (JOB_COMPLETION_INDEX)  0
#   ALGOS       algorithms (backends be_<algo>)             "lc po2 pe2 pe3"
#   WARMUP      unmeasured run before (x-algo rr), 0 = none 60s
#   DURATION    duration of a run                           60s
#   REPEAT      rounds, the order of ALGOS rotates           1
#   PAUSE       seconds between two runs                    15
#   CONC        concurrent requests of this client          16
#   CONNS       connections of this client                  1
#   RPS         requests per second of this client, 0 = as fast as possible   0
#   CPU_US      CPU per request on the service (us)         2000
#   ALLOC_KB    garbage per request on the service (KiB)    256
#   KEEP        seconds to stay after the last run          3600
#   OUT         results                                     /results
set -eu

MODES="${MODES:-central sidecar}"
LB_HOST="${LB_HOST:-lb}"
INDEX="${INDEX:-${JOB_COMPLETION_INDEX:-0}}"
ALGOS="${ALGOS:-lc po2 pe2 pe3}"
WARMUP="${WARMUP:-60s}"
DURATION="${DURATION:-60s}"
REPEAT="${REPEAT:-1}"
PAUSE="${PAUSE:-15}"
CONC="${CONC:-16}"
CONNS="${CONNS:-1}"
RPS="${RPS:-0}"
CPU_US="${CPU_US:-2000}"
ALLOC_KB="${ALLOC_KB:-256}"
KEEP="${KEEP:-3600}"
OUT="${OUT:-/results}/$INDEX"

mkdir -p "$OUT"

log() {
	echo "[$(date -u +%H:%M:%S)] client $INDEX: $*"
}

cli() {
	echo "$2" | socat -t 5 - "TCP:$1:9100"
}

secs() {
	case "$1" in
	*m) echo $((${1%m} * 60)) ;;
	*s) echo "${1%s}" ;;
	*) echo "$1" ;;
	esac
}

for mode in $MODES; do
	case "$mode" in
	central|sidecar) ;;
	*) echo "MODES: central or sidecar, not $mode" >&2; exit 1 ;;
	esac
done

# the start date: set by client 0, a past value is one of an earlier run
if [ "$INDEX" = 0 ]; then
	start=$(($(date +%s) + 30))
	until cli "$LB_HOST" "experimental-mode on; set var proc.start int($start)" > /dev/null 2>&1; do
		sleep 1
	done
	cli "$LB_HOST" "clear counters all" > /dev/null
else
	start=0
	while [ "$start" -le "$(date +%s)" ]; do
		sleep 1
		start=$(curl -fsS "http://$LB_HOST:8404/start" 2>/dev/null || echo 0)
	done
fi
log "start at $(date -u -d "@$start" +%H:%M:%S), modes $MODES"

# run <name> <algo> <start date> <duration>: one ghz run, then the counters
# of the backend are saved and cleared for the next run
run() {
	now=$(date +%s)
	[ "$3" -gt "$now" ] && sleep $(($3 - now))
	log "$1: ghz -c $CONC --connections $CONNS -z $4 --rps $RPS (x-algo $2)"
	ghz --insecure --proto /opt/grpc/work.proto --call work.Work/Run \
		-d "{\"cpu_us\":$CPU_US,\"alloc_kb\":$ALLOC_KB}" \
		--metadata "{\"x-algo\":\"$2\"}" \
		-c "$CONC" --connections "$CONNS" -z "$4" --rps "$RPS" \
		-O json -o "$OUT/$1.json" "$target" || log "$1: ghz failed"
	cli 127.0.0.1 "show stat" > "$OUT/$1.sidecar.csv" || true
	cli 127.0.0.1 "clear counters all" > /dev/null || true
	if [ "$INDEX" = 0 ] && [ "$target" != 127.0.0.1:50051 ]; then
		cli "$LB_HOST" "show stat" > "$OUT/$1.lb.csv" || true
		cli "$LB_HOST" "clear counters all" > /dev/null || true
	fi
	log "$1: done"
}

# an unmeasured warmup (JIT, heap sizing), then REPEAT rounds, each one
# with the order of the algorithms rotated by one
at=$start
target="$LB_HOST:50051"
if [ "$(secs "$WARMUP")" -gt 0 ]; then
	run warmup rr "$at" "$WARMUP"
	at=$((at + $(secs "$WARMUP") + PAUSE))
fi
step=$(($(secs "$DURATION") + PAUSE))
for mode in $MODES; do
	target="$LB_HOST:50051"
	[ "$mode" = sidecar ] && target="127.0.0.1:50051"
	set -- $ALGOS
	r=1
	while [ "$r" -le "$REPEAT" ]; do
		for algo in "$@"; do
			name="${mode}_$algo"
			[ "$REPEAT" -gt 1 ] && name="${name}_r$r"
			run "$name" "$algo" "$at" "$DURATION"
			at=$((at + step))
		done
		first=$1
		shift
		set -- "$@" "$first"
		r=$((r + 1))
	done
done

touch "$OUT/done"
log "all runs done, staying ${KEEP}s"
sleep "$KEEP"
