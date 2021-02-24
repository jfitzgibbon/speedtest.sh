# speedtest.sh
speedtest.sh - a script supporting minimal speedtest functionality

This script is intended as a minimal replacement for speedtest-cli on
embedded linux/BSD platforms that do not support python.

To avail of the full functionality, (including lookups for client and server
settings), a reasonably functional version of either "curl" or "wget" is
required, (must support HTTPS and basic GET and POST operations).

If the server and device are specified on the command line, netcat (nc) can
also be used instead of wget/curl. (netcat does not support HTTPS, so
config lookups will fail with the nc option.)

The "ip" command is used for finding a device with a particular IP address,
though a fallback to "ifconfig" is also attempted if "ip" fails.

"awk" with math support is required for calculating distances to servers.

For platforms with low storage, you can save space by stripping comments
and some of the verbose help with something like this:

  $ ( head -n 26 speedtest.sh; tail -n $(($(cat speedtest.sh | wc -l) - 26)) \
  speedtest.sh | sed '/^[ \t]*#/d;/^#$/d;/^$/d' ) > speedtest-min.sh

