#!/bin/sh
################################################################################
#
# speedtest.sh - a script supporting minimal speedtest functionality
#
# Copyright (c) 2021 John Fitzgibbon
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
###############################################################################
#
# This script is intended as a minimal replacement for speedtest-cli on
# embedded linux/BSD platforms that do not support python.
#
# To avail of the full functionality, (including lookups for client and server
# settings), a reasonably functional version of either "curl" or "wget" is
# required, (must support HTTPS and basic GET and POST operations).
#
# If the server and device are specified on the command line, netcat (nc) can
# also be used instead of wget/curl. (netcat does not support HTTPS, so
# config lookups will fail with the nc option.)
#
# The "ip" command is used for finding a device with a particular IP address,
# though a fallback to "ifconfig" is also attempted if "ip" fails.
#
# "awk" with math support is required for calculating distances to servers.
#
# For platforms with low storage, you can save space by stripping comments
# and some of the verbose help with something like this:
#
# $ ( head -n 26 speedtest.sh; tail -n $(($(cat speedtest.sh | wc -l) - 26)) \
# speedtest.sh | sed '/^[ \t]*#/d;/^#$/d;/^$/d' ) > speedtest-min.sh
#
###############################################################################

reset_defaults() {
	dn=/dev/null
	# set to measure upload speed
	up=1
	# set to measure download speed
	down=1
	# set to truncate values to 32-bit
	calc32=0
	# set to list client/server details
	list=0
	# set to select a random nearby server, (rather than measuring latency)
	randserv=0
	# field separator for CSV output
	fs=
	# device to monitor, (with ifconfig), for throughput stats
	dev=
	# curl/wget/nc (+ appropriate command params)
	cmd=curl
	# how long to run each up/down test
	secs=4
	# how many nearby servers to select from
	servcnt=5
	# set to an appropriate "killall" command if -k is specified
	killall=
	# size of resource to upload via POST
	upsz=524288
	valid_up="[ 32768, 65536, 131072, 262144, 524288, 1048576, 7340032 ]"
	# size of download resource, (determines name of GET resource -
	# format is "random[downsz]x[downsz].jpg")
	downsz=1500
	valid_down="[ 350, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000 ]"
	# number of downloads/uploads each client will perform
	downcnt=4
	upcnt=4
	# number of clients to run in parallel
	clients=4
	# url provides an xml-formatted list of servers
	url="https://speedtest.net/speedtest-servers.php"
	# set to use a previously saved copy of url, (if available)
	reuse_url=0
	# saved copy of url, used to lookup server details by ID
	serv_file=/tmp/speedtest-servers.xml
	# selected speedtest server ID
	serv_id=
	# selected server "hostname:port" - specified on command line,
	# or retrieved from "url" using "serv_id"
	serv=
	# client config details, (location, IP, ISP, etc.)
	clientcfg=
	# clientcfg is populated by fetching cfgurl
	cfgurl="https://speedtest.net/speedtest-config.php"
	cfgfile=/tmp/speedtest-config.php
	# externally visible IP address - retrieved from clientcfg
	ip="unknown"
	# latitude - from clientcfg
	lat=0
	# longitude - from clientcfg
	lon=0
	# calcdist is an awk script for estimating distance to a server,
	# initialized with a placeholder until we know latitude/longitude
	calcdist='{ printf "999999999%s%s\n", s, $1; }'
	# post_file is the POST resource, (generated by this script)
	post_file=/tmp/speedtest-post.dat
}

# Note: verbose text is preceded by "# " so stripping comments reduces help size
usage() {
	reset_defaults
	sed 's/^# //' <<EOF
Command format:
 
$0 [-h] [-l] [-D|-U] [-curl|-wget|-nc] [-t secs] [-c clients] [-u URL] \\
	[-r] [-n count] [-R] [-fs char|-csv] [-k] [-32] \\
	[-ds downsize] [-us upsize] [-dc downcount] [-uc upcount] \\
	[-s server|-i id] [-d device]
 
Parameters:

	-h|--help	: Display this help text
	-l		: List client details and nearby servers, (no tests)
	-D|-U		: Measure Download or Upload, (default both)
	-curl|-wget|-nc	: Use curl, wget or nc, (default "$cmd")
	-t secs		: Measure for [secs] seconds, (default $secs)
	-c clients	: Number of clients run in parallel, (default $clients)
	-url URL	: URL for downloading Server details
			  Default: "$url"
	-r		: Reuse saved URL file, (if available)
	-n count	: Select from "count" nearby servers, (default $servcnt)
	-R		: Choose random server, (default: use latency)
	-fs ch		: Output CSV format, using "ch" as field separator
	-csv		: Output CSV - same as "-fs ,"
	-k		: Terminate curl/wget/nc with "killall"
	-32		: Use 32-bit calculations. Limits max speed,
			  but works for non-64 bit shells
	-ds downsize	: Download resource size, (default $downsz)
			  Valid: $valid_down
	-us upsize	: Upload resource size, (default $upsz)
			  Valid: $valid_up
	-dc downcount	: Download repeat count, (default $downcnt)
	-uc upcount	: Upload repeat count, (default $upcnt)
	-s server	: Speedtest server, (hostname or IP)
			  Note: include ":port", (typically ":8080")
	-i id		: Server ID, (speedtest.net ID)
	-d device	: Device to monitor, (ISP uplink device)
 
# If the server, (or server ID), or device are not specified, values will be
# assigned by querying "$cfgurl".
# If values cannot be determined automatically, you will need to include them
# on the command line.
# 
# Browsing "$url" is a good way to pick
# a server or server ID. This URL redirects you to a list of speedtest servers
# that are available from your ISP/location.
# 
# The device to monitor is determined by looking for a device that matches the
# client IP address reported by "$cfgurl".
# If you are behind a firewall/NAT, you will need to specify the device.
# 
# If this script is being run periodically to track speeds, it is a good idea
# to specify the server ID and device. Allowing the script to pick from nearby
# servers can result in less reliable measurements, as there can be quite a bit
# of variation between servers, even if they have similiar proximity/latency.
# 
# If your version of curl/wget does not support redirects, you may need to
# override the default URL. You can find the appropriate URL by copying the
# redirected URL from the address bar of your browser.
# 
# If you are using netcat (nc) instead of curl/wget, then you will need to
# specify the [-s server] and [-d device] options, since nc cannot fetch the
# HTTPS resources needed to populate the client and server config files.
# 
# You may need to modify some of the count/size parameters based on the speed of
# the link being tested. Specifically, if you have a very fast, (or very slow),
# link, you may want to increase, (or decrease), the up/down counts, which
# determine how many times the upload/download is repeated. You might also
# want to pick larger, (or smaller), up/down sizes to ensure TCP slow-start
# isn't a limiting factor. Increasing "clients", (which determines how many
# up-/down-loads to run in parallel), can also help achieve steady throughput.
# 
# Essentially, you need to pick values that ensure that there is sufficient
# upload/download activity happening throughout the sampling interval.
# 
# It is worth noting that running tests on the router that is forwarding traffic
# may result in lower throughput compared to a test run on a LAN-side device.
# This is because the router has to *process* the traffic, as opposed to just
# *forwarding* it. However, on "beefier" routers it should be possible to get
# pretty accurate results.
# 
EOF
	[ ! "$*" = "" ] && echo "Error: $*" >&2
	exit 1
}

# check that 2nd param (a size) is in 1st param, (a list of sizes)
check_size() {
	[ "$(echo "$1" | sed "s/ $2[, ]//")" = "$1" ] && usage "Invalid ${3}size: $2"
}

reset_defaults
while [ ! "$1" = "" ]; do
case $1 in
	-h|--help)
	usage
	;;
	-32)
	calc32=1
	shift
	;;
	-D)
	down=1
	shift
	;;
	-U)
	up=1
	shift
	;;
	-curl)
	cmd=curl
	shift
	;;
	-wget)
	cmd=wget
	shift
	;;
	-nc)
	cmd=nc
	shift
	;;
	-t)
	secs=$2
	shift
	shift
	;;
	-d)
	dev=$2
	shift
	shift
	;;
	-s)
	serv=$2
	serv_id=
	shift
	shift
	;;
	-i)
	serv_id=$2
	serv=$2
	shift
	shift
	;;
	-ds)
	check_size "$valid_down" "$2" "down"
	downsz=$2
	shift
	shift
	;;
	-us)
	check_size "$valid_up" "$2" "up"
	upsz=$2
	shift
	shift
	;;
	-dc)
	downcnt=$2
	shift
	shift
	;;
	-uc)
	upcnt=$2
	shift
	shift
	;;
	-c)
	clients=$2
	shift
	shift
	;;
	-url)
	url=$2
	shift
	shift
	;;
	-l)
	list=1
	shift
	;;
	-n)
	servcnt=$2
	shift
	shift
	;;
	-R)
	randserv=1
	shift
	;;
	-r)
	resuse_url=1
	shift
	;;
	-fs)
	fs=$2
	shift
	shift
	;;
	-csv)
	fs=","
	shift
	;;
	-k)
	killall="killall"
	shift
	;;
	*)
	usage "Bad parameter: $1"
	;;
esac
done

# Format "killall" command, (before we add options to "cmd")
if [ ! "$killall" = "" ]; then
	# see if sudo works, (otherwise assume we are root)
	sudo=$(sudo ls >$dn 2>&1 && echo "sudo")
	killall="$sudo $killall $cmd"
fi

# Format "cmd" and "post_param" to include appropriate options
if [ "$cmd" = "curl" ]; then
	cmd="curl -Ls -o"
	post_param="--data-binary @"
elif [ "$cmd" = "wget" ]; then
	cmd="wget -q -O"
	post_param="--post-file="
else
	cmd="nc_get_post"
fi

createfile() {
	local size=$(($1 - 9))
	local str="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	rm -f "$post_file"
	( \
		printf "content1="; \
		for i in $(seq 1 $((size / 36))); do \
			printf $str; \
		done; \
		printf "%.$((size % 36))s" $str; \
	) > "$post_file"
}

# rand/$RANDOM mght not be implemented, so...
# (parameter specifies number of digits required, default=3)
getrand() {
	echo $(head /dev/urandom | tr -dc "0123456789" | cut -c1-${1:-3} | sed 's/^0*//;s/^$/0/')
}

# If date does not support nanosecs, msects() will replace the msec part of the
# timestamp with a random number
[ "$(date +%N)" = "" -o "$(date +%N)" = "N" ] && nanos=0 || nanos=1

# Output a millisecond timestamp with 2 decimal places, ("nnnnnnnnnnnnn.nn")
msects() {
	if [ $nanos -eq 0 ]; then
		printf "%s%.3d.00" $(date +%s) $(getrand)
	else	
		printf "%s" $(($(date +%s%N) / 10000)) | sed 's/\(.*\)\(..\)/\1.\2/'
	fi
}

nc_get_post() {
	if [ ! "$(echo "$2" | sed 's/https://')" = "$2" ]; then
		echo "nc does not support HTTPS URLS, ($2)"
		return 1
	fi
	nc_url="$2"
	[ "$(echo "$nc_url" | sed 's/http://')" = "$2" ] && nc_url="$3"
	nc_serv=$(echo $nc_url | cut -d/ -f3)
	nc_cmd="nc $(echo $nc_serv | sed 's/:/ /')"
	nc_req="/$(echo $nc_url | cut -d/ -f4-) HTTP/1.1\r\nAccept-Encoding: identity\r\nHost: $nc_serv\r\nUser-Agent: netcat\r\nConnection: close\r\n"
	if [ "$nc_url" = "$2" ]; then
		printf "GET ${nc_req}Cache-Control: no-cache\r\n\r\n" | $nc_cmd >"$1"
	else
		( printf "POST ${nc_req}Accept: */*\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: $upsz\r\n\r\n"; cat $post_file ) | $nc_cmd
	fi
}

get() {
	$cmd $dn http://"$1"/speedtest/random${downsz}x${downsz}.jpg?x=$(msects) >$dn 2>&1
}

post() {
	$cmd $dn $post_param"$post_file" http://"$1"/upload.php?x=$(msects) >$dn 2>&1
}

latency() {
	time -p $cmd $dn http://"$1"/speedtest/latency.txt?x=$(msects) 2>&1 | grep -F real | cut -d" " -f2
}

# If /sys/class/net exists, we use it to fetch device rx/tx bytes.
# If not, we assume we can use a BSD-style "netstat -idb".
# If neither of these apply, getbytes() will fail.
[ -d /sys/class/net ] && has_sys=1 || has_sys=0

getbytes() {
	[ $has_sys -eq 1 ] &&  cat /sys/class/net/$1/statistics/$2_bytes || \
		netstat -idb | grep -F $(echo $1 | sed 's/[0-9]//g') | grep -F Link | awk -v rx_tx=$2 '{ if (rx_tx == "rx") print $8; else print $11; }'
}

# read uptime from /proc/uptime, without the decimal point, (i.e 100'ths of a sec)
getuptime() {
	sed 's/ .*//;s/\.//;s/^0*//;s/^$/0/' /proc/uptime
}

# val32() reduces a value to < 2 billion by removing significant digits. Use this
# if the shell only supports 32-bit arithmetic. Note that this is not foolproof,
# especially if the rates are high, but it should work for sub-gigabit speeds
# with the default sample time.
val32() {
	val=$(echo $1 | sed 's/.*\([0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\)/\1/;s/^0*//;s/^$/0/')
	# if we are given start/end values and "start > end",
	# then we assume "end" wrapped into the next billion
	[ $2 -gt $val ] && val=$((val + 1000000000))
	echo $val
}

# "run" runs an actual test and outputs the result measured in bits/sec.
# params are command to run, (get/post), number of iterations, and stat to read, (rx/tx)
run() {
	for i in $(seq 1 $clients); do
		( for j in $(seq 1 $2); do $1 $serv; done ) >$dn 2>&1 &
	done
	# give the clients a second to get ramped up
	sleep 1
	if [ -r /proc/uptime ]; then
		sbytes=$(getbytes "$dev" "$3")
		stime=$(getuptime)
		sleep $secs
		ebytes=$(getbytes "$dev" "$3")
		etime=$(getuptime)
	else
		stime="0"
		sbytes=$(getbytes "$dev" "$3")
		etime=$(time -p sleep $secs 2>&1 | grep -F real)
		ebytes=$(getbytes "$dev" "$3")
		etime=$(echo "$etime" | cut -d" " -f2 | sed 's/\.//')
	fi
	if [ ! "$killall" = "" ]; then
		$killall >$dn 2>&1
		while [ "$?" = "0" ]; do sleep 1; $killall >$dn 2>&1; done
	fi
	if [ $calc32 -eq 1 ]; then
		sbytes=$(val32 $sbytes 0)
		ebytes=$(val32 $ebytes $sbytes)
		stime=$(val32 $stime 0)
		etime=$(val32 $etime $stime)
	fi
	bits=$(((ebytes - sbytes) * 8))
	# "time -p" and "/proc/uptime" are accurate to 1/100th of a second, so
	# we adjust "bits" to compensate for the fraction over the sample time
	elapsed=$((etime - stime))
	expected=$((secs * 100))
	bits=$((bits - (bits / elapsed * (elapsed - expected))))
	echo $((bits / secs))
}

getcfgval() {
	echo $(echo "$clientcfg" | grep -F " $1=" | sed 's/.* '$1'="\([^"]*\)".*/\1/')
}

getval() {
	if [ ! "$serv_id" = "" ]; then
		local val=$(grep -F "id=\"$serv_id\"" "$serv_file" | sed 's/.* '$1'="\([^"]*\)".*/\1/')
		[ "$val" = "" ] && echo "Error: Could not find \"$1\" for server ID ${serv_id}!" >&2
		echo $val
	fi
}

getservfile() {
	if [ ! -r "$serv_file" -o ! $reuse_url -eq 1 ]; then
		rm -f "$serv_file"
		$cmd "$serv_file" "$url"
		reuse_url=1
	fi
	if [ ! -r "$serv_file" ]; then
		echo "Error: could not read \"$serv_file\"!" >&2
		exit 1
	fi
}

getlatlon() {
	lat="$(getcfgval 'lat')"
	lon="$(getcfgval 'lon')"
	# Define an awk script for calculating distances
	# Note that we use a quick Euclidean approximation here,
	# rather than the slow-but-correct haversine formula
	calcdist='{ x=($2 - '$lat'); y=($3 - '$lon')*cos('$lat'); printf "%d%s%s\n", 110.25*sqrt(x*x+y*y), s, $1; }'
}

listnearby() {
	grep -F " id=" "$serv_file" | \
	sed 's/.* lat="\([^"]*\)" lon="\([^"]*\)".* id="\([^"]*\)".*/\3 \1 \2/' | \
	awk -v s=" " "$calcdist" | sort -n | head -n $servcnt | cut -d' ' -f2
}

getnearest() {
	if [ $randserv -eq 1 ]; then
		serv_id=$(listnearby | head -n $(($(getrand) % servcnt + 1)) | tail -n 1)
	else
		nearest_serv_id=
		best_latency=999999999
		for serv_id in $(listnearby); do
			serv="$(getval 'host')"
			this_latency="$(latency $serv | sed 's/\.//')"
			# if latencies are same, toss a coin...
			if [ "$best_latency" -eq "$this_latency" -a $(($(getrand) % 2)) -eq 0 -o \
			     "$best_latency" -gt "$this_latency" ]; then
				best_latency=$this_latency
				nearest_serv_id=$serv_id
			fi
		done
		serv_id=$nearest_serv_id
	fi
}

getdev() {
	ip="$(getcfgval 'ip')"
	dev=$(ip a s | grep -F "scope global" | grep -F " $ip/" | sed 's/.* //')
	# ifconfig formats vary a lot. These sed/awk commands depend on the fact that
	# the device name is at the start of the line and all other lines are indented
	# with spaces or tabs. The address lines must begin with "inet" (or "inet6")
	# and can optionally include " addr:" before the actual address. The device
	# name may also optionally be followed by a ":" (which is removed).
	if [ "$dev" = "" ]; then
		dev=$(ifconfig | sed 's/^[\t ]*inet/inet/;/^[\t ].*/d;s/ addr:/ /' | awk -v ip="$ip" \
			'BEGIN { d=""; } { if (/^inet/) { if ($2 == ip) print d; } else { d = $1; } }' | sed 's/:$//')
	fi
}

getserv() {
	getservfile
	getlatlon
	getnearest
}

listcfg() {
	getlatlon
	echo "IP: $(getcfgval 'ip')"
	echo "Interface: $dev"
	echo "ISP: $(getcfgval 'isp')"
	echo "ISP Rating: $(getcfgval 'isprating')"
	echo "Latitude: $lat"
	echo "Longitude: $lon"
	echo "Country: $(getcfgval 'country')"
	echo "Server ID: $serv_id"
	echo "Nearest Servers:"
	i=1
	for serv_id in $(listnearby); do
		serv="$(getval 'host')"
		servlat="$(getval 'lat')"
		servlon="$(getval 'lon')"
		dist="$(echo "km" $servlat $servlon | awk -v s="" "$calcdist")"
		echo "Server #$i: id=$serv_id, serv=$(getval 'host'), lat=$servlat, lon=$servlon, dist=$dist, latency=$(latency $serv)"
		i=$((i + 1))
	done
	exit 0
}

logbps() {
	[ "$fs" = "" ] && echo "${2}load speed: $1 bps"
}

# Handle device/server lookups and the list command...
if [ "$serv_id" = "" -a "$serv" = "" -o "$dev" = "" -o $list -eq 1 ]; then
	errmsg=$($cmd "$cfgfile" "$cfgurl")
	clientcfg=$(grep "^<client " "$cfgfile" | sed 's/^<client//;s/ \/>$//')
	if [ ! "$clientcfg" = "" ]; then
		[ "$dev" = "" ] && getdev
		[ "$serv" = "" ] && getserv
		[ $list -eq 1 ] && listcfg
	fi
fi

[ "$serv_id" = "" -a "$serv" = "" ] && echo "${errmsg:-Could not find nearest servers} - Please specify a server or server ID!" && exit 1
[ "$dev" = "" ] && echo "${errmsg:-Could not find device with IP \"$ip\"} - Please specify the device to monitor!" && exit 1

# Server ID is preferred. If we have it, lookup the server
if [ ! "$serv_id" = "" ]; then
	getservfile
	serv="$(getval 'host')"
	[ "$serv" = "" ] && exit 1
fi

# Do the work!
if [ "$fs" = "" ]; then
	echo "Server ID: $serv_id"
	echo "Server: $serv"
fi
if [ $down -eq 1 ]; then
	rx_bps=$(run "get" $downcnt "rx")
	logbps $rx_bps "Down"
fi
if [ $up -eq 1 ]; then
	createfile $upsz
	tx_bps=$(run "post" $upcnt "tx")
	logbps $tx_bps "Up"
fi
if [ ! "$fs" = "" ]; then
	[ "$fs" = "," ] && q='"' || q=
	# Note: Output fields correspond to speedtest-cli equivalents
	echo "${serv_id}${fs}${q}$(getval 'sponsor')${q}${fs}${q}$(getval 'name')${q}${fs}$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)${fs}${fs}${fs}${rx_bps}${fs}${tx_bps}${fs}${fs}"
fi
