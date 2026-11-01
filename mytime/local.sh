#!/bin/sh
# Local MyTime test with podman: one pod per node (four services and their
# sidecars) and one for the edge, on their own network, so that the names
# are the same as in Kubernetes ("app-<i>" instead of "app-<i>.app...").
# Node i pins its services to the host cores 4*i .. 4*i+3 (rootless podman
# has no cpuset controller), so keep APP_COUNT * 4 below the host cores.
#
#   mytime/local.sh build             build the MyTime image on top of the
#                                     HAProxy image (scripts/local.sh build)
#   mytime/local.sh up                start APP_COUNT nodes and the edge
#   mytime/local.sh bench [VAR=...]   run mytime/bench.sh with haload (MyTime
#                                     image), with GEN=h2load in the h2load
#                                     image
#   mytime/local.sh down              remove the pods and the network
#
# Settings (environment):
#   APP_COUNT   nodes                                      3
#   MESH_PROTO  protocol between the proxies: h1 or h2     h1
#   BACKLOG     listen backlog of the services             (5)
set -eu

cd "$(dirname "$0")/.."

NET=mytime
IMG=localhost/peak-ewma-mytime:latest
IMG_H2LOAD=localhost/peak-ewma-h2load:latest
APP_COUNT="${APP_COUNT:-3}"
MESH_PROTO="${MESH_PROTO:-h1}"
BACKLOG="${BACKLOG:-}"

# one thread per connection in the services
LIM_NODE="--memory=1g --pids-limit=4096"
LIM_EDGE="--cpus=2 --memory=256m --pids-limit=256"
LIM_H2LOAD="--cpus=2 --memory=1g --pids-limit=256"

build() {
	podman build -f mytime/Containerfile -t "$IMG" .
}

up() {
	podman network exists "$NET" || podman network create "$NET"
	podman pod create --name edge --network "$NET" --hostname edge \
		-p 127.0.0.1:8404:8404
	podman run -d --pod edge --name edge-haproxy $LIM_EDGE \
		-e APP_COUNT="$APP_COUNT" -e APP_ADDR=app-%d -e EDGE_ADDR=edge \
		-e MESH_PROTO="$MESH_PROTO" "$IMG" edge
	i=0
	while [ "$i" -lt "$APP_COUNT" ]; do
		p="app-$i"
		podman pod create --name "$p" --network "$NET" --hostname "$p"
		# shellcheck disable=SC2086
		podman run -d --pod "$p" --name "$p-node" $LIM_NODE \
			-e APP_COUNT="$APP_COUNT" -e APP_ADDR=app-%d -e EDGE_ADDR=edge \
			-e MESH_PROTO="$MESH_PROTO" -e BACKLOG="$BACKLOG" \
			-e CORE_OFFSET=$((i * 4)) "$IMG" node
		i=$((i + 1))
	done
	echo "stats: http://127.0.0.1:8404/stats"
}

bench() {
	mkdir -p results/mytime
	img="$IMG"
	# "-e VAR=value" per argument, values may contain spaces (ALGOS)
	for kv in "$@"; do
		[ "$kv" = GEN=h2load ] && img="$IMG_H2LOAD"
		set -- "$@" -e "$kv"
		shift
	done
	# shellcheck disable=SC2086
	# as root: the mounted results directory belongs to the host user
	podman run --rm --network "$NET" --name mytime-bench --user 0 $LIM_H2LOAD \
		-v "$PWD/mytime/bench.sh:/bench.sh:ro,Z" \
		-v "$PWD/results/mytime:/results:Z" \
		-e APP_COUNT="$APP_COUNT" -e APP_ADDR=app-%d -e EDGE_HOST=edge \
		"$@" --entrypoint /bin/sh "$img" /bench.sh
}

down() {
	podman pod rm -f edge 2>/dev/null || true
	i=0
	while [ "$i" -lt 8 ]; do
		podman pod rm -f "app-$i" 2>/dev/null || true
		i=$((i + 1))
	done
	podman network rm "$NET" 2>/dev/null || true
}

case "${1:-}" in
build) build ;;
up) up ;;
bench) shift; bench "$@" ;;
down) down ;;
*) sed -n '2,19p' "$0"; exit 1 ;;
esac
