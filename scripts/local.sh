#!/bin/sh
# Local test with podman: one pod, all containers share its network.
# CPU and memory are limited per container so the host is not overloaded.
#
#   scripts/local.sh src [<ref>]      take HAProxy from a local branch: git
#                                     archive of <ref> (default HEAD) of
#                                     $HAPROXY_GIT into src/haproxy.tar
#   scripts/local.sh src -            remove it, build HAPROXY_REF again
#   scripts/local.sh build            build both images
#   scripts/local.sh up               start haterm x4, shim x4, lb
#   scripts/local.sh bench [VAR=...]  run scripts/bench.sh in the h2load image
#   scripts/local.sh delay <1-4> <t>  set the delay of one server, e.g. 200
#   scripts/local.sh logs             logs of the load balancer
#   scripts/local.sh down             remove the pod
#
# Settings (environment):
#   DELAYS        delay of server 1..4 in ms   "5 5 5 50"
#   SIZE          response size                1k
#   BUILD_CPUS    CPUs for the builds          8
#   BUILD_MEM     memory for the builds        8g
#   BUILD_JOBS    make -j for the builds       8
#   HAPROXY_GIT   HAProxy repository for "src" ../haproxy
set -eu

cd "$(dirname "$0")/.."

POD=peak-ewma
IMG_HAP=localhost/peak-ewma-hap:latest
IMG_H2LOAD=localhost/peak-ewma-h2load:latest
DELAYS="${DELAYS:-5 5 5 50}"
SIZE="${SIZE:-1k}"
BUILD_CPUS="${BUILD_CPUS:-8}"
BUILD_MEM="${BUILD_MEM:-8g}"
BUILD_JOBS="${BUILD_JOBS:-8}"
HAPROXY_GIT="${HAPROXY_GIT:-../haproxy}"

# limits per container: cpus memory
LIM_HATERM="--cpus=1 --memory=128m --pids-limit=256"
LIM_SHIM="--cpus=0.5 --memory=128m --pids-limit=256"
LIM_LB="--cpus=2 --memory=512m --pids-limit=256"
LIM_H2LOAD="--cpus=2 --memory=1g --pids-limit=256"

# rootless podman only has the cpu, io, memory and pids controllers, so the
# builds are limited with a CPU quota, not a cpuset
# only committed changes end up in the archive, not the working tree
src() {
	if [ "${1:-}" = "-" ]; then
		rm -f src/haproxy.tar
		return
	fi
	git -C "$HAPROXY_GIT" archive --prefix=haproxy/ -o "$PWD/src/haproxy.tar" "${1:-HEAD}"
	echo "src/haproxy.tar: $(git -C "$HAPROXY_GIT" log -1 --format='%h %s' "${1:-HEAD}")"
}

build() {
	lim="--cpu-period=100000 --cpu-quota=$((BUILD_CPUS * 100000)) --memory=$BUILD_MEM"
	# shellcheck disable=SC2086
	podman build $lim --build-arg JOBS="$BUILD_JOBS" \
		-f containers/haproxy/Containerfile -t "$IMG_HAP" .
	# shellcheck disable=SC2086
	podman build $lim --build-arg JOBS="$BUILD_JOBS" \
		-f containers/h2load/Containerfile -t "$IMG_H2LOAD" containers/h2load
}

up() {
	podman pod create --name "$POD" -p 127.0.0.1:8404:8404
	i=1
	for d in $DELAYS; do
		podman run -d --pod "$POD" --name "${POD}-haterm$i" $LIM_HATERM \
			-e NBTHREAD=1 -e HATERM_LISTEN="127.0.0.1:800$i" \
			"$IMG_HAP" haterm
		podman run -d --pod "$POD" --name "${POD}-shim$i" $LIM_SHIM \
			-e NBTHREAD=1 -e DELAY="$d" -e SIZE="$SIZE" \
			-e SHIM_PORT="900$i" -e SHIM_CLI_PORT="910$i" \
			-e HATERM_ADDR="127.0.0.1:800$i" \
			"$IMG_HAP" shim
		i=$((i + 1))
	done
	podman run -d --pod "$POD" --name "${POD}-lb" $LIM_LB \
		-e NBTHREAD=2 "$IMG_HAP" lb
	echo "stats: http://127.0.0.1:8404/stats"
}

bench() {
	mkdir -p results
	env_args=""
	for kv in "$@"; do
		env_args="$env_args -e $kv"
	done
	# shellcheck disable=SC2086
	podman run --rm --pod "$POD" --name "${POD}-h2load" $LIM_H2LOAD \
		-v "$PWD/scripts/bench.sh:/bench.sh:ro,Z" \
		-v "$PWD/results:/results:Z" \
		$env_args --entrypoint /bin/sh "$IMG_H2LOAD" /bench.sh
}

delay() {
	echo "experimental-mode on; set var proc.delay str($2)" | \
		podman exec -i "${POD}-lb" socat stdio "tcp:127.0.0.1:910$1"
}

case "${1:-}" in
src) shift; src "$@" ;;
build) build ;;
up) up ;;
bench) shift; bench "$@" ;;
delay) delay "$2" "$3" ;;
logs) podman logs -f "${POD}-lb" ;;
down) podman pod rm -f "$POD" ;;
*) sed -n '2,22p' "$0"; exit 1 ;;
esac
