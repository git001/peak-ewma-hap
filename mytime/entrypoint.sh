#!/bin/sh
# Starts one MyTime role:
#
#   node   the four original services, each behind its own HAProxy sidecar,
#          a service and its sidecar pinned to the same core as in the
#          original service.sh and sidecar.sh. Every second it asks the
#          edge for "<algo> <cores>" (set by mytime/bench.sh); on a change
#          it restarts the sidecars with the new algorithm, as do-bench.sh
#          did, and pins the running services to the new cores.
#          Its kernel TCP counters (/proc/net/netstat, e.g. ListenOverflows)
#          are served on :9000/netstat for mytime/bench.sh, and one line
#          per second on :9000/samples (after run-timed.sh and tcp-sock.sh
#          of dpbench): epoch, CPU user sys idle iowait steal in % of the
#          whole VM (/proc/stat is not namespaced, steal shows noisy
#          neighbours), TCP sockets inuse orphan timewait of the pod.
#   edge   the edge HAProxy
#
# Environment:
#   EDGE         host of the edge                              edge
#   CORE_OFFSET  first core (local tests with several nodes)   0
#   STAT_CORES   cores of the :9000 server, away from the      (any)
#                services, e.g. 4-7
#   BACKLOG      listen backlog of the services; empty keeps   (5)
#                the 5 of the original (socketserver default)
# and those of gen-cfg.sh.
set -eu

role="${1:-node}"
[ $# -gt 0 ] && shift

EDGE="${EDGE:-edge}"
CORE_OFFSET="${CORE_OFFSET:-0}"
STAT_CORES="${STAT_CORES:-}"
BACKLOG="${BACKLOG:-}"

# service port script, in the order of the cores of the original
# (svc-*.conf: time on CPU 0, user 1, log 2, mytime 3)
SERVICES="2001:svc-time.py 2002:svc-user.py 2003:svc-log.py 2004:svc-mytime.py"

log() {
	echo "[$(date +%H:%M:%S)] $*"
}

# core of the n-th service (0..3) with <cores> cores: 4 = one core each,
# 2 = time+log on 0 and user+mytime on 1, 1 = all on core 0
core_of() {
	echo $((CORE_OFFSET + $1 % $2))
}

stop_pid() {
	[ -s "$1" ] || return 0
	pid=$(cat "$1")
	kill "$pid" 2>/dev/null || true
	i=0
	while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	rm -f "$1"
}

# with BACKLOG, the unchanged original script runs with another
# request_queue_size, which its ThreadedTCPServer inherits from TCPServer
WRAP='import runpy, socketserver, sys
socketserver.TCPServer.request_queue_size = int(sys.argv[1])
sys.argv = sys.argv[2:]
runpy.run_path(sys.argv[0], run_name="__main__")'

start_services() {
	n=0
	for s in $SERVICES; do
		port="${s%%:*}"
		side="http://127.0.0.3:2$port"
		core=$(core_of "$n" "$1")
		# taskset execs python3: $! is the service for pin_services
		if [ -n "$BACKLOG" ]; then
			taskset -c "$core" python3 -c "$WRAP" "$BACKLOG" "/opt/p2c/${s#*:}" \
				"127.0.0.2:1$port" "$side/GetTime" "$side/UserAttr" "$side/Log" \
				< /dev/null > /dev/null 2>&1 &
		else
			taskset -c "$core" python3 "/opt/p2c/${s#*:}" \
				"127.0.0.2:1$port" "$side/GetTime" "$side/UserAttr" "$side/Log" \
				< /dev/null > /dev/null 2>&1 &
		fi
		echo $! > "/tmp/service-$port.pid"
		n=$((n + 1))
	done
}

# the services are never restarted, as in the original: they set
# allow_reuse_address after bind(), so a new one cannot bind while the
# closed connections of the old one are in TIME_WAIT. All their threads
# move to the new cores instead.
pin_services() {
	n=0
	for s in $SERVICES; do
		taskset -a -c -p "$(core_of "$n" "$1")" "$(cat "/tmp/service-${s%%:*}.pid")" > /dev/null
		n=$((n + 1))
	done
}

# appends a line to /tmp/stat/samples, from the CPU counters since the
# previous call (in prev_cpu)
sample() {
	# not "cur": the main loop keeps the running algorithm in it
	now_cpu=$(awk '$1 == "cpu" { print $2 + $3, $4 + $7 + $8, $5, $6, $9; exit }' /proc/stat)
	if [ -n "${prev_cpu:-}" ]; then
		echo "$(date +%s) $prev_cpu $now_cpu $(awk '$1 == "TCP:" { print $3, $5, $7 }' /proc/net/sockstat)" |
			awk '{
				for (i = 2; i <= 6; i++) { d[i] = $(i + 5) - $i; t += d[i] }
				if (t <= 0) t = 1
				printf "%s %.1f %.1f %.1f %.1f %.1f %s %s %s\n", $1,
					100 * d[2] / t, 100 * d[3] / t, 100 * d[4] / t,
					100 * d[5] / t, 100 * d[6] / t, $12, $13, $14
			}' >> /tmp/stat/samples
	fi
	prev_cpu="$now_cpu"
}

start_sidecars() {
	n=0
	for s in $SERVICES; do
		port="${s%%:*}"
		/usr/local/bin/gen-cfg.sh sidecar "$port" "$1" "$1 $2" > "/tmp/sidecar-$port.cfg"
		taskset -c "$(core_of "$n" "$2")" haproxy -D -f "/tmp/sidecar-$port.cfg" \
			-p "/tmp/sidecar-$port.pid"
		n=$((n + 1))
	done
}

stop_sidecars() {
	for s in $SERVICES; do
		stop_pid "/tmp/sidecar-${s%%:*}.pid"
	done
}

case "$role" in
node)
	trap 'stop_sidecars; kill $(cat /tmp/service-*.pid) $(cat /tmp/stat.pid); exit 0' TERM INT
	mkdir -p /tmp/stat
	cp /proc/net/netstat /tmp/stat/netstat
	if [ -n "$STAT_CORES" ]; then
		taskset -c "$STAT_CORES" python3 -m http.server 9000 -d /tmp/stat \
			> /dev/null 2>&1 &
	else
		python3 -m http.server 9000 -d /tmp/stat > /dev/null 2>&1 &
	fi
	echo $! > /tmp/stat.pid
	cur=""
	cores=""
	while :; do
		sample
		# /proc files have no size, http.server would send them empty
		cp /proc/net/netstat /tmp/stat/netstat.new
		mv /tmp/stat/netstat.new /tmp/stat/netstat
		want=$(wget -q -T 2 -O - "http://$EDGE:8404/algo" 2>/dev/null || true)
		case "$want" in
		*" "[124]) ;;
		*) sleep 1; continue ;;
		esac
		if [ "$want" != "$cur" ]; then
			algo="${want% *}"
			c="${want##* }"
			log "switching to algorithm $algo on $c core(s)"
			stop_sidecars
			if [ -z "$cores" ]; then
				start_services "$c"
			elif [ "$c" != "$cores" ]; then
				pin_services "$c"
			fi
			cores="$c"
			start_sidecars "$algo" "$c"
			cur="$want"
		fi
		sleep 1
	done
	;;
edge)
	/usr/local/bin/gen-cfg.sh edge > /tmp/edge.cfg
	exec haproxy -W -db -f /tmp/edge.cfg "$@"
	;;
*)
	echo "usage: $0 node|edge" >&2
	exit 1
	;;
esac
