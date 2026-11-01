#!/bin/sh
# Copies a gRPC test bed run from the cluster to results/grpc/<date>[_label]/,
# prints the summary (grpc/summary.py) and draws the charts (grpc/plot.sh):
#
#   grpc/get-all-results.sh [<label>]
#
#   <dir>/<index>/      the files of grpc/bench.sh of every client
#   <dir>/client-<index>.log, svc-<i>.log (GC log), lb.log
#   <dir>/cluster/      nodes and pods with their CPU usage
#
# It only reads: kubectl get, logs, top and cp. The client pods must still
# be running (see KEEP).
#
# Environment:
#   KUBECTL     kubectl command          kubectl
#   NS          namespace                grpc
set -eu

cd "$(dirname "$0")/.."

KUBECTL="${KUBECTL:-kubectl}"
NS="${NS:-grpc}"
k() {
	$KUBECTL -n "$NS" "$@"
}

dest="results/grpc/$(date +%Y%m%d_%H%M%S)${1:+_$1}"
mkdir -p "$dest/cluster"

for pod in $(k get pod -l app=grpc-bench -o name); do
	pod="${pod#pod/}"
	idx=$(k get pod "$pod" -o jsonpath='{.metadata.annotations.batch\.kubernetes\.io/job-completion-index}')
	k cp "$pod:/results/$idx" "$dest/$idx" > /dev/null
	k logs "$pod" > "$dest/client-$idx.log" 2>&1 || true
done
for pod in $(k get pod -l app=grpc-svc -o name); do
	k logs "$pod" > "$dest/${pod#pod/}.log" 2>&1 || true
done
k logs deploy/lb > "$dest/lb.log" 2>&1 || true

$KUBECTL get nodes -o wide > "$dest/cluster/nodes.txt" 2>&1 || true
k get pods -o wide > "$dest/cluster/pods.txt" 2>&1 || true
$KUBECTL top nodes > "$dest/cluster/top-nodes.txt" 2>&1 || true
k top pods > "$dest/cluster/top-pods.txt" 2>&1 || true

echo "$dest"
python3 -I grpc/summary.py "$dest"
grpc/plot.sh "$dest" || true
