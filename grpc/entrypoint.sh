#!/bin/sh
# Roles of the gRPC test bed image:
#
#   lb       the central HAProxy, CLI on 0.0.0.0:9100 for the clients
#   client   a sidecar HAProxy on 127.0.0.1:50051 (CLI 127.0.0.1:9100), then
#            bench.sh (BENCH, e.g. from a ConfigMap); the sidecar is only
#            used in the "sidecar" runs
#
# The environment of gen-cfg.sh applies to both.
set -eu

cfg=/tmp/haproxy.cfg

case "${1:-client}" in
lb)
	CLI_BIND="ipv4@0.0.0.0:9100" /opt/grpc/gen-cfg.sh > "$cfg"
	exec haproxy -W -db -f "$cfg"
	;;
client)
	BIND="127.0.0.1:50051" CLI_BIND="ipv4@127.0.0.1:9100" \
		/opt/grpc/gen-cfg.sh > "$cfg"
	haproxy -D -f "$cfg" -p /tmp/haproxy.pid
	exec sh "${BENCH:-/opt/grpc/bench.sh}"
	;;
*)
	exec "$@"
	;;
esac
