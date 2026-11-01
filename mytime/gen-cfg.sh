#!/bin/sh
# Writes the HAProxy configuration of a sidecar or of the edge to stdout,
# with the settings of sidecar.cfg.* and edge.cfg of the original test
# (https://github.com/haproxytech/bench-algo-p2c). Only the addresses, the
# DNS resolution of Kubernetes and the algorithm differ.
#
#   gen-cfg.sh sidecar <port> <algo> <tag>   sidecar of the service on <port>
#   gen-cfg.sh edge
#
# Sidecar of the service on port P (2001 time, 2002 user, 2003 log,
# 2004 mytime), as in the original:
#   :P               inbound, to the local service on 127.0.0.2:1P
#   127.0.0.3:2P     outbound, the calls of the local service, routed by
#                    path to the services of all nodes: here <algo> works
#   :3P              stats ("/;csv"), "/algo" returns <tag>
#
# Algorithms (the names of the original files sidecar.cfg.<name>, plus the
# core peak EWMA):
#   rnd  random(1)        po2  random (2 draws)      rr  roundrobin
#   lc   leastconn        ext  through the edge (leastconn, full view)
#   pe2  random(2) peak-ewma                         pe3 random(3) peak-ewma
#
# Environment:
#   APP_COUNT   number of nodes                            6
#   APP_ADDR    printf format of the address of node i     app-%d.app.mytime.svc.cluster.local
#   EDGE_ADDR   address of the edge                        edge.mytime.svc.cluster.local
#   WEIGHT      weight of all servers (original: 1)        1
#   MESH_PROTO  protocol between the proxies (edge ->       h1
#               sidecars, sidecar -> sidecar): h1 as in
#               2019, or h2 (h2c: "proto h2" without "ssl",
#               no TLS), multiplexed on long-lived
#               connections as in today's service meshes.
#               The services always speak HTTP/1.0 to their
#               own sidecar, as in the original.
#   NBTHREAD    threads of the edge                        2
set -eu

APP_COUNT="${APP_COUNT:-6}"
APP_ADDR="${APP_ADDR:-app-%d.app.mytime.svc.cluster.local}"
EDGE_ADDR="${EDGE_ADDR:-edge.mytime.svc.cluster.local}"
WEIGHT="${WEIGHT:-1}"
NBTHREAD="${NBTHREAD:-2}"
MESH_PROTO="${MESH_PROTO:-h1}"

case "$MESH_PROTO" in
h1) PROTO="" ;;
h2) PROTO=" proto h2" ;;
*) echo "unknown MESH_PROTO $MESH_PROTO" >&2; exit 1 ;;
esac

balance_of() {
	case "$1" in
	rnd) echo "random(1)" ;;
	po2) echo "random" ;;
	rr) echo "roundrobin" ;;
	lc | ext) echo "leastconn" ;;
	pe2) echo "random(2) peak-ewma" ;;
	pe3) echo "random(3) peak-ewma" ;;
	*) echo "unknown algorithm $1" >&2; exit 1 ;;
	esac
}

# servers of all nodes for one service port
servers() {
	i=0
	while [ "$i" -lt "$APP_COUNT" ]; do
		# shellcheck disable=SC2059
		echo "    server srv$((i + 1)) $(printf "$APP_ADDR" "$i"):$1$PROTO"
		i=$((i + 1))
	done
}

resolvers() {
	cat <<EOF
# in Kubernetes the pods may not resolve yet at start; the resolvers of
# HAProxy do not apply the search domains, hence the FQDNs
resolvers dns
    parse-resolv-conf
    hold valid 10s

EOF
}

sidecar() {
	port="$1"
	algo="$2"
	tag="$3"
	cat <<EOF
global
    stats socket /tmp/sock-$port mode 600 level admin
    stats timeout 1h

EOF
	resolvers
	cat <<EOF
defaults
    mode http
    timeout connect 4s
    timeout queue  10s
    timeout client 10s
    timeout server 10s
    monitor-uri /health
    balance $(balance_of "$algo")
    option dontlog-normal
    option tcp-smart-connect
    default-server weight $WEIGHT resolvers dns init-addr last,libc,none

listen inbound
    bind :$port
    option http-buffer-request
    server srv 127.0.0.2:1$port

frontend outbound
    bind 127.0.0.3:2$port
    use_backend mytime  if { path_beg /MyTime   }
    use_backend log     if { path_beg /Log      }
    use_backend user    if { path_beg /UserAttr }
    use_backend time    if { path_beg /GetTime  }

EOF
	for b in mytime:2004 log:2003 user:2002 time:2001; do
		echo "backend ${b%%:*}"
		if [ "$algo" = ext ]; then
			echo "    server lb $EDGE_ADDR:${b##*:}$PROTO"
		else
			servers "${b##*:}"
		fi
		echo
	done
	cat <<EOF
frontend stats
    bind :3$port
    http-request return status 200 content-type text/plain string "$tag" if { path /algo }
    stats uri /
EOF
}

edge() {
	cat <<EOF
global
    nbthread $NBTHREAD
    stats socket /tmp/sock-edge mode 600 level admin
    # for mytime/bench.sh: the algorithm and the cores of the next run,
    # set with "set var" on this socket, read by the nodes on /algo
    stats socket ipv4@0.0.0.0:9100 level admin
    stats timeout 1h
    set-var proc.algo str(po2)
    set-var proc.cores str(4)

EOF
	resolvers
	cat <<EOF
defaults
    mode http
    timeout connect 4s
    timeout queue  10s
    timeout client 20s
    timeout server 20s
    monitor-uri /health
    option httpchk /health
    # check-proto: the same health checks with both MESH_PROTO
    default-server check inter 1s check-proto h1 resolvers dns init-addr last,libc,none
    balance leastconn
    http-reuse always
    option dontlog-normal
    option http-buffer-request
    option tcp-smart-connect

EOF
	for b in mytime:2004 log:2003 user:2002 time:2001; do
		echo "listen ${b%%:*}"
		echo "    bind :${b##*:}"
		echo "    default-server port 3${b##*:}"
		servers "${b##*:}"
		echo
	done
	cat <<EOF
frontend stats
    bind :8404
    http-request return status 200 content-type text/plain lf-string "%[var(proc.algo)] %[var(proc.cores)]" if { path /algo }
    stats uri /stats
    stats show-legends
EOF
}

case "${1:-}" in
sidecar) sidecar "$2" "$3" "$4" ;;
edge) edge ;;
*) sed -n '2,30p' "$0" >&2; exit 1 ;;
esac
