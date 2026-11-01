#!/bin/sh
# HAProxy configuration of the gRPC test bed, on stdout. The same for the
# central load balancer and for the sidecar of each client:
#
#   frontend grpc   h2c on BIND, the gRPC metadata "x-algo" selects the
#                   backend be_<algo>, so that one configuration serves all
#                   the runs without any reload
#   be_<algo>       the same SVC_COUNT services, one backend per algorithm
#   stats           on :8404, "/start" returns proc.start (see bench.sh)
#   CLI             on CLI_BIND (set var proc.start, show stat)
#
# Environment:
#   SVC_COUNT   number of services                          4
#   SVC_ADDR    address of service i, %d = 0..SVC_COUNT-1   svc-%d:9090
#   BIND        address of the gRPC frontend                :50051
#   CLI_BIND    address of the CLI                          ipv4@127.0.0.1:9100
#   NBTHREAD    threads                                     2
#   WEIGHT      weight of all servers                       100
#   MAXCONN     maxconn of each server, 0 = none            0
set -eu

SVC_COUNT="${SVC_COUNT:-4}"
SVC_ADDR="${SVC_ADDR:-svc-%d:9090}"
BIND="${BIND:-:50051}"
CLI_BIND="${CLI_BIND:-ipv4@127.0.0.1:9100}"
NBTHREAD="${NBTHREAD:-2}"
WEIGHT="${WEIGHT:-100}"
MAXCONN="${MAXCONN:-0}"

servers() {
	i=0
	while [ "$i" -lt "$SVC_COUNT" ]; do
		# shellcheck disable=SC2059
		printf '    server svc%d %s\n' "$i" "$(printf "$SVC_ADDR" "$i")"
		i=$((i + 1))
	done
}

backend() {
	cat <<EOF

backend be_$1
    balance $2
    default-server proto h2 weight $WEIGHT maxconn $MAXCONN resolvers dns init-addr last,libc,none
$(servers)
EOF
}

cat <<EOF
global
    nbthread $NBTHREAD
    stats socket $CLI_BIND level admin
    set-var proc.start int(0)

resolvers dns
    parse-resolv-conf
    hold valid 10s

defaults
    mode http
    timeout connect 4s
    timeout client 30s
    timeout server 30s
    option dontlog-normal

frontend grpc
    bind $BIND proto h2
    use_backend be_%[req.hdr(x-algo)] if { req.hdr(x-algo) -m reg ^[a-z0-9]+\$ }
    default_backend be_lc

frontend stats
    bind :8404
    http-request return status 200 content-type text/plain lf-string "%[var(proc.start)]\n" if { path /start }
    stats enable
    stats uri /
    stats refresh 5s
EOF

backend rr roundrobin
backend lc leastconn
backend rnd 'random(1)'
backend po2 'random(2)'
backend pe2 'random(2) peak-ewma'
backend pe3 'random(3) peak-ewma'
