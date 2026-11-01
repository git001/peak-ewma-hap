#!/bin/sh
# Local run of the gRPC test bed with podman, all containers on one network:
#
#   grpc/local.sh build               service and client images
#   grpc/local.sh up                  services svc-0..N-1 and the lb
#   grpc/local.sh bench [VAR=...]     CLIENTS clients at the same time
#   grpc/local.sh down                remove everything
#
# Results in results/grpc/<date>/<index>/, service logs (GC) beside them.
#
# Settings (environment):
#   SVC_COUNT   services                    4
#   SVC_CPUS    CPUs per service            1
#   CLIENTS     clients                     3
#   JAVA_OPTS   JVM options of all services (default of the image)
set -eu

cd "$(dirname "$0")/.."

NET=grpc
IMG_SVC=localhost/peak-ewma-grpc-svc:latest
IMG=localhost/peak-ewma-grpc:latest
SVC_COUNT="${SVC_COUNT:-4}"
SVC_CPUS="${SVC_CPUS:-1}"
CLIENTS="${CLIENTS:-3}"

build() {
	podman build -f grpc/service/Containerfile -t "$IMG_SVC" grpc/service
	podman build -f grpc/Containerfile -t "$IMG" .
}

up() {
	podman network exists "$NET" || podman network create "$NET"
	i=0
	while [ "$i" -lt "$SVC_COUNT" ]; do
		podman run -d --network "$NET" --name "svc-$i" --hostname "svc-$i" \
			--cpus="$SVC_CPUS" --memory=512m \
			${JAVA_OPTS:+-e JAVA_OPTS="$JAVA_OPTS"} "$IMG_SVC"
		i=$((i + 1))
	done
	podman run -d --network "$NET" --name lb --hostname lb \
		--cpus=2 --memory=256m -p 127.0.0.1:8404:8404 \
		-e SVC_COUNT="$SVC_COUNT" "$IMG" lb
}

# bench [VAR=value ...]: passed to every client
bench() {
	out="results/grpc/$(date +%Y%m%d_%H%M%S)"
	mkdir -p "$out"
	# "-e VAR=value" for each argument, values may contain spaces
	n=$#
	while [ "$n" -gt 0 ]; do
		set -- "$@" -e "$1"
		shift
		n=$((n - 1))
	done
	i=0
	while [ "$i" -lt "$CLIENTS" ]; do
		podman run -d --network "$NET" --name "client-$i" --user 0 \
			--cpus=2 --memory=1g -v "$PWD/$out:/results:z" \
			-e SVC_COUNT="$SVC_COUNT" -e INDEX="$i" -e KEEP=0 "$@" \
			"$IMG" client
		i=$((i + 1))
	done
	i=0
	while [ "$i" -lt "$CLIENTS" ]; do
		podman wait "client-$i" > /dev/null
		podman logs "client-$i" > "$out/client-$i.log" 2>&1
		podman rm "client-$i" > /dev/null
		i=$((i + 1))
	done
	i=0
	while [ "$i" -lt "$SVC_COUNT" ]; do
		podman logs "svc-$i" > "$out/svc-$i.log" 2>&1
		i=$((i + 1))
	done
	echo "$out"
}

down() {
	i=0
	while [ "$i" -lt "$SVC_COUNT" ]; do
		podman rm -f "svc-$i" > /dev/null 2>&1 || true
		i=$((i + 1))
	done
	podman rm -f lb > /dev/null 2>&1 || true
	podman ps -a --format '{{.Names}}' | grep '^client-' | xargs -r podman rm -f > /dev/null
	podman network rm "$NET" > /dev/null 2>&1 || true
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
build|up|down) "$cmd" ;;
bench) bench "$@" ;;
*) sed -n '2,16p' "$0"; exit 1 ;;
esac
