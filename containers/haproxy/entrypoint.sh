#!/bin/sh
# Starts one of the three roles of the image: lb, shim or haterm.
# All settings come from the environment, see README.md.
set -eu

role="${1:-lb}"
[ $# -gt 0 ] && shift

export NBTHREAD="${NBTHREAD:-2}"

case "$role" in
lb)
	# BE_COUNT servers be-0 .. be-<n-1>; BE_ADDR is a printf format of the
	# address, which gets the index plus BE_ADDR_OFFSET
	BE_COUNT="${BE_COUNT:-4}"
	BE_ADDR="${BE_ADDR:-127.0.0.1:%d}"
	BE_ADDR_OFFSET="${BE_ADDR_OFFSET:-9001}"
	i=0
	: > /tmp/servers.cfg
	while [ "$i" -lt "$BE_COUNT" ]; do
		# shellcheck disable=SC2059
		addr=$(printf "$BE_ADDR" $((i + BE_ADDR_OFFSET)))
		printf '    server be-%d %s\n' "$i" "$addr" >> /tmp/servers.cfg
		i=$((i + 1))
	done
	awk -v f=/tmp/servers.cfg '
		/^[ \t]*# @SERVERS@$/ { while ((getline l < f) > 0) print l; close(f); next }
		{ print }' /etc/haproxy/lb.cfg > /tmp/lb.cfg
	exec haproxy -W -db -f /tmp/lb.cfg "$@"
	;;
shim)
	# the delay may also be "<n>r" (random between 0 and n ms). In a
	# StatefulSet, the ordinal i of pod <name>-<i> chooses the delay:
	#   DELAYS="5 5 5 50"   the i-th value
	#   SLOW_EVERY=8        DELAY_SLOW when i % 8 == 7, else DELAY_FAST
	i="${HOSTNAME##*-}"
	if [ -z "${DELAY:-}" ] && [ -n "${DELAYS:-}" ]; then
		DELAY=$(echo "$DELAYS" | awk -v i="$i" '{ print $(i + 1) }')
	elif [ -z "${DELAY:-}" ] && [ -n "${SLOW_EVERY:-}" ]; then
		if [ $((i % SLOW_EVERY)) -eq $((SLOW_EVERY - 1)) ]; then
			DELAY="${DELAY_SLOW:-50}"
		else
			DELAY="${DELAY_FAST:-5}"
		fi
	fi
	export DELAY="${DELAY:-5}"
	export SIZE="${SIZE:-1k}"
	export SHIM_PORT="${SHIM_PORT:-9001}"
	export SHIM_CLI_PORT="${SHIM_CLI_PORT:-9101}"
	export HATERM_ADDR="${HATERM_ADDR:-127.0.0.1:8001}"
	exec haproxy -W -db -f /etc/haproxy/shim.cfg "$@"
	;;
haterm)
	# haterm only stops on SIGUSR1 (soft stop), podman and Kubernetes
	# send SIGTERM: forward it
	haterm -L "${HATERM_LISTEN:-127.0.0.1:8001}" \
		-G "nbthread ${NBTHREAD}" "$@" &
	pid=$!
	trap 'kill -USR1 "$pid"' TERM INT
	wait "$pid" || wait "$pid"
	;;
*)
	exec "$role" "$@"
	;;
esac
