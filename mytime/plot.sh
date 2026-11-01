#!/bin/sh
# Draws the three charts of the 2019 test with gnuplot, with the settings
# of plot/*.gnup of https://github.com/haproxytech/bench-algo-p2c, from the
# files of mytime/bench.sh:
#
#   mytime/plot.sh <results dir> <cores>
#
#   req-per-second_cpu<cores>.png   requests per second over the elapsed time
#   resp-time_cpu<cores>.png        mean response time over the elapsed time
#   load-per-server_cpu<cores>.png  maximum load of each service of each
#                                   node, stacked per node, per algorithm
#   pctl_cpu<cores>.png             response time over the percentiles on a
#                                   log scale, as graph-h1load-pct.sh of
#                                   dpbench (haload runs, not in the original)
#   steal_cpu<cores>.png            CPU steal of the VMs (mean of the nodes)
#                                   over the elapsed time, to spot noisy
#                                   neighbours (not in the original)
#
# Without gnuplot on the host, it runs in an Alpine container (podman).
set -eu

dir="$1"
cores="$2"

if ! command -v gnuplot > /dev/null; then
	exec podman run --rm -v "$(cd "$(dirname "$0")" && pwd):/mytime:ro,Z" \
		-v "$(cd "$dir" && pwd):/data:Z" docker.io/alpine:3.23 \
		sh -c "apk add -q --no-cache gnuplot font-dejavu > /dev/null &&
			sh /mytime/plot.sh /data '$cores'"
fi

cd "$dir"

title_of() {
	case "$1" in
	rnd) echo "Random" ;;
	po2) echo "Power-of-Two" ;;
	rr) echo "Round-robin" ;;
	lc) echo "Leastconn" ;;
	ext) echo "External" ;;
	pe2) echo "P2 Peak EWMA" ;;
	pe3) echo "P3 Peak EWMA" ;;
	*) echo "$1" ;;
	esac
}

# the algorithms of this level, in the order of the summary
algos=$(awk -F, -v c="$cores" 'NR == 1 && $1 != "cores" { exit } $1 == c { print $2 }' summary.csv)
if [ -z "$algos" ]; then
	echo "$dir: no runs with $cores cores in summary.csv" >&2
	exit 0
fi

common='set terminal pngcairo size 640,400 font "DejaVu Sans,9"
set border lw 2
set linetype 10 linecolor rgb "#e0e0e0"
set grid back ls 10
set key box opaque inside top right
set xlabel "Elapsed time (seconds)"'

# time series: column 2 = requests per second, 3 = mean response time
lines() {
	plot=""
	for a in $algos; do
		f="${a}_cpu${cores}.series"
		[ -f "$f" ] || continue
		plot="${plot:+$plot, }'$f' using 1:$1 with lines lw 2 smooth bezier title '$(title_of "$a")'"
	done
	echo "plot $plot"
}

gnuplot <<EOF
$common
set output "req-per-second_cpu${cores}.png"
set ylabel "Requests per second (higher is better)"
set yrange [0:*]
$(lines 2)
set output "resp-time_cpu${cores}.png"
set ylabel "Response time in milliseconds (lower is better)"
set key bottom right
$(lines 3)
EOF

# percentiles: x = 1 / (1 - p) on a log scale, y = time to last byte
pplot=""
for a in $algos; do
	f="${a}_cpu${cores}.pctl"
	[ -s "$f" ] || continue
	# 100 / tail instead of invtail, which haload rounds to an integer
	pplot="${pplot:+$pplot, }'$f' using (\$2 > 0 ? 100 / \$2 : 1e5):7 with lines lw 2 title '$(title_of "$a")'"
done
if [ -n "$pplot" ]; then
	gnuplot <<EOF
$common
set output "pctl_cpu${cores}.png"
set logscale x
set logscale y
set xrange [1:100000]
set xtics ("0%%" 1, "50%%" 2, "90%%" 10, "99%%" 100, "99.9%%" 1000, "99.99%%" 10000, "99.999%%" 100000)
set xlabel "Percentile"
set ylabel "Response time in milliseconds (lower is better)"
set key top left
plot $pplot
EOF
fi

# steal: mean of the nodes per second, as "<elapsed> <steal %>"
splot=""
for a in $algos; do
	f="${a}_cpu${cores}.samples"
	[ -s "$f" ] || continue
	awk '{ s[$2] += $7; n[$2]++ } END { for (t in s) print t, s[t] / n[t] }' "$f" |
		sort -n | awk 'NR == 1 { t0 = $1 } { print $1 - t0, $2 }' > "$f.steal"
	splot="${splot:+$splot, }'$f.steal' using 1:2 with lines lw 2 title '$(title_of "$a")'"
done
if [ -n "$splot" ]; then
	gnuplot <<EOF
$common
set output "steal_cpu${cores}.png"
set ylabel "CPU steal in % (mean of the nodes)"
set yrange [0:*]
plot $splot
EOF
	rm -f ./*_cpu"${cores}".samples.steal
fi

# stacked bars: one block per algorithm, one row per node
: > load.dat
for a in $algos; do
	f="${a}_cpu${cores}.load"
	[ -f "$f" ] || continue
	awk '{ v[$1, $2] = $3; p[$1] = 1 }
		END {
			for (node in p)
				print node, v[node, "mytime"] + 0, v[node, "log"] + 0,
					v[node, "time"] + 0, v[node, "user"] + 0
		}' "$f" | sort -t- -k2 -n >> load.dat
	printf '\n\n' >> load.dat
done
nodes=$(awk 'NF { n++ } !NF { exit } END { print n }' load.dat)

plot=""
i=0
for a in $algos; do
	[ -f "${a}_cpu${cores}.load" ] || continue
	# the key only once, as in the original
	if [ "$i" = 0 ]; then
		t1="title 'MyTime'"; t2="title 'Log'"; t3="title 'Time'"; t4="title 'User'"
	else
		t1="notitle"; t2="notitle"; t3="notitle"; t4="notitle"
	fi
	# two lines for the long names, so that seven groups fit
	name=$(title_of "$a" | sed 's/ Peak/\\nPeak/')
	plot="${plot:+$plot, }newhistogram \"$name\", \
'load.dat' index $i using 2 lc rgb '#e69f00' $t1, \
'' index $i using 3 lc rgb '#56b4e9' $t2, \
'' index $i using 4 lc rgb '#009e73' $t3, \
'' index $i using 5 lc rgb '#9400d3' $t4"
	i=$((i + 1))
done

gnuplot <<EOF
$common
set terminal pngcairo size 720,400 font "DejaVu Sans,9"
set output "load-per-server_cpu${cores}.png"
set title "Load per server for each algorithm"
set key outside right top vertical nobox noopaque samplen 2
set bmargin 5
unset xlabel
set xrange [-1:$((i * (nodes + 1) - 1))]
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
plot $plot
EOF
rm -f load.dat

ls -1 ./*_cpu"${cores}".png
