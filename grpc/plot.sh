#!/bin/sh
# Charts of a gRPC test bed run, per topology (central, sidecar), all rounds
# of an algorithm together:
#
#   grpc/plot.sh <results dir>
#
#   pctl_<mode>.png     response time over the percentiles on a log scale
#   p99_<mode>.png      p99 of each second of the run (GC pauses show here)
#   share_<mode>.png    share of the requests of each server per algorithm
#   load-per-server_<mode>.png
#                       maximum load (smax) of each server per algorithm,
#                       stacked per sidecar (central: the lb alone), as
#                       mytime/plot.sh
#
# The data files come from grpc/plot-data.py (python3 on the host); without
# gnuplot on the host, the charts are drawn in an Alpine container (podman).
set -eu

dir="$1"
here="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$dir/plot" ]; then
	python3 -I "$here/plot-data.py" "$dir"
fi

if ! command -v gnuplot > /dev/null; then
	exec podman run --rm -v "$here:/grpc:ro,Z" \
		-v "$(cd "$dir" && pwd):/data:Z" docker.io/alpine:3.23 \
		sh -c "apk add -q --no-cache gnuplot font-dejavu > /dev/null &&
			sh /grpc/plot.sh /data"
fi

cd "$dir/plot"

title_of() {
	case "$1" in
	rnd) echo "Random" ;;
	po2) echo "Power-of-Two" ;;
	rr) echo "Round-robin" ;;
	lc) echo "Leastconn" ;;
	pe2) echo "P2 Peak EWMA" ;;
	pe3) echo "P3 Peak EWMA" ;;
	*) echo "$1" ;;
	esac
}

common='set terminal pngcairo size 640,400 font "DejaVu Sans,9"
set border lw 2
set linetype 10 linecolor rgb "#e0e0e0"
set grid back ls 10
set key box opaque'

for share in ./*.share; do
	mode=$(basename "$share" .share)
	algos=$(head -1 "$share" | cut -d' ' -f2-)

	pplot=""
	splot=""
	for a in $algos; do
		pplot="${pplot:+$pplot, }'${mode}_$a.pctl' using (100 / (100 - \$1 + 0.001)):2 with lines lw 2 title '$(title_of "$a")'"
		splot="${splot:+$splot, }'${mode}_$a.series' using 1:2 with lines lw 2 title '$(title_of "$a")'"
	done

	gnuplot <<EOF
$common
set output "../pctl_$mode.png"
set title "gRPC, $mode: response time over the percentiles"
set logscale x
set logscale y
set xrange [1:100000]
set xtics ("0%%" 1, "50%%" 2, "90%%" 10, "99%%" 100, "99.9%%" 1000, "99.99%%" 10000, "99.999%%" 100000)
set xlabel "Percentile"
set ylabel "Response time in milliseconds (lower is better)"
set key inside top left
plot $pplot

set output "../p99_$mode.png"
set title "gRPC, $mode: p99 of each second"
unset logscale
set xrange [*:*]
set xtics autofreq
set yrange [0:*]
set xlabel "Elapsed time (seconds)"
set ylabel "p99 in milliseconds (lower is better)"
set key inside top right
plot $splot
EOF

	# one group of bars per algorithm, one bar per server
	n=$(echo "$algos" | wc -w)
	bplot=""
	i=2
	for a in $algos; do
		bplot="${bplot:+$bplot, }'$mode.share' using $i:xtic(1) title '$(title_of "$a")'"
		i=$((i + 1))
	done
	gnuplot <<EOF
$common
set terminal pngcairo size 720,400 font "DejaVu Sans,9"
set output "../share_$mode.png"
set title "gRPC, $mode: share of the requests per server"
set style data histograms
set style histogram clustered gap 1
set style fill solid 1.00 noborder
set yrange [0:*]
set xlabel "Server"
set ylabel "Share of the requests in % (even is $(awk 'NR > 1 { n++ } END { printf "%.1f", 100 / n }' "$mode.share") %%)"
set key outside right top vertical nobox noopaque
set grid noxtics
plot $bplot
EOF
	# stacked bars: one block per algorithm, one bar per server, one
	# segment per source (the sidecar of a client, or the lb)
	nsrv=$(awk 'NR > 1 && NF { n++ } NR > 1 && !NF { exit } END { print n }' "$mode.smax")
	colors="#e69f00 #56b4e9 #009e73 #9400d3 #f0e442 #0072b2 #d55e00 #cc79a7"
	lplot=""
	i=0
	for a in $algos; do
		# two lines for the long names
		name=$(title_of "$a" | sed 's/ Peak/\\nPeak/')
		lplot="${lplot:+$lplot, }newhistogram \"$name\""
		j=1
		for src in $(head -1 "$mode.smax" | cut -d' ' -f3-); do
			c=$(echo "$colors" | cut -d' ' -f"$j")
			t="notitle"
			if [ "$i" = 0 ]; then
				if [ "$src" = lb ]; then
					t="title 'Load balancer'"
				else
					t="title 'Sidecar $src'"
				fi
			fi
			lplot="$lplot, '$mode.smax' index $i using $((j + 1)) lc rgb '$c' $t"
			j=$((j + 1))
		done
		i=$((i + 1))
	done
	gnuplot <<EOF
$common
set terminal pngcairo size 720,400 font "DejaVu Sans,9"
set output "../load-per-server_$mode.png"
set title "gRPC, $mode: maximum load per server"
set key outside right top vertical nobox noopaque samplen 2
set bmargin 5
unset xlabel
set xrange [-1:$((i * (nsrv + 1) - 1))]
set yrange [0:*]
set offsets 0, 0, graph 0.05, 0
set style data histograms
set style histogram rowstacked title offset 0,-0.6
set style fill solid 1.00 noborder
set boxwidth 0.6 absolute
set xtics in nomirror format ""
set tics scale 0.0
set grid noxtics
set ylabel "Maximum server load (lower is better)"
plot $lplot
EOF
	echo "$n algorithms: pctl_$mode.png p99_$mode.png share_$mode.png load-per-server_$mode.png"
done
