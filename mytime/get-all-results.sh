#!/bin/sh
# Copies everything of a MyTime run from the cluster to results/mytime/ and
# draws the charts:
#
#   mytime/get-all-results.sh [<label>]     e.g. "cpu4" for the level
#
#   <run dir>/                 the files of mytime/bench.sh (bench Job)
#   <run dir>/cluster/         stats of the edge and all sidecars at the
#                              end ("show stat"), logs of every container,
#                              nodes and pods with their CPU usage
#   <run dir>/*.png            mytime/plot.sh for every contention level
#
# It only reads: kubectl get, logs, top, cp and exec of "show stat" on the
# stats sockets. The bench pod must still be running (see KEEP).
#
# Environment:
#   KUBECTL     kubectl command          kubectl
#   NS          namespace                mytime
set -eu

cd "$(dirname "$0")/.."

KUBECTL="${KUBECTL:-kubectl}"
NS="${NS:-mytime}"
k() {
	$KUBECTL -n "$NS" "$@"
}

pod=$(k get pod -l app=mytime-bench -o name | tail -1)
pod="${pod#pod/}"
[ -n "$pod" ] || { echo "no bench pod in $NS" >&2; exit 1; }

mkdir -p results/mytime
tmp="results/mytime/.cp-$$"
k cp "$pod:/results" "$tmp" > /dev/null
# /results holds one directory per bench.sh start, keep all of them
for d in "$tmp"/*/; do
	run=$(basename "$d")
	dest="results/mytime/${run}${1:+_$1}"
	rm -rf "$dest"
	mv "$d" "$dest"
	echo "$dest"
done
rm -rf "$tmp"

# the cluster state goes with the newest run
cl="$dest/cluster"
mkdir -p "$cl"

k get pods -o wide > "$cl/pods.txt"
$KUBECTL get nodes -o wide --show-labels > "$cl/nodes.txt"
$KUBECTL top nodes > "$cl/top-nodes.txt" 2>&1 || true
k top pods --containers > "$cl/top-pods.txt" 2>&1 || true
k logs "$pod" > "$cl/$pod.log" 2>&1 || true

for p in $(k get pod -l app=mytime-edge -o name) $(k get pod -l app=mytime-app -o name); do
	p="${p#pod/}"
	k logs "$p" > "$cl/$p.log" 2>&1 || true
	case "$p" in
	edge-*) socks="sock-edge" ;;
	*) socks="sock-2001 sock-2002 sock-2003 sock-2004" ;;
	esac
	for sock in $socks; do
		k exec "$p" -- sh -c "echo 'show stat' | socat stdio /tmp/$sock" \
			> "$cl/${p}_$sock.stat.csv" 2>&1 || true
	done
done
echo "$cl"

# charts for every contention level of the summaries (only the format
# of mytime/bench.sh with the column "cores")
for s in results/mytime/*"${1:+_$1}"/summary.csv; do
	d=$(dirname "$s")
	[ -n "$(ls "$d"/*.png 2>/dev/null)" ] && continue
	awk -F, 'NR == 1 && $1 != "cores" { exit } NR > 1 { print $1 }' "$s" | sort -u |
		while read -r cores; do
			sh mytime/plot.sh "$d" "$cores" || true
		done
done
