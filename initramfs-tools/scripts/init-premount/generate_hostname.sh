#!/bin/sh
PREREQ=""
prereqs()
{
	echo "$PREREQ"
}
case $1 in
prereqs)
	prereqs
	exit 0
	;;
esac
. /scripts/functions

# Wait for a network device to appear (which can take a little while on some
# devices, ex: Raspberry Pi 3).
# Waiting for udev to settle doesn't actually wait for all devices to be set up
# (it looks like the USB bus takes a bit to enumerate). Instead this hacky loop
# just waits for a netowrk device other than lo to appear.
IF_ATTEMPT_COUNT=0
NET_IF=
# Waiting a max of roughly 3 seconds (30 attempts, a bit more than 0.1 seconds
# per loop).
while [ $IF_ATTEMPT_COUNT -le 50 ] && [ -z "$NET_IF" ]; do
	NET_IFS="$(ls /sys/class/net | sort)"
	for IF in $NET_IFS; do
		IF_PATH="/sys/class/net/${IF}"
		REAL_IF="$(readlink -f "$IF_PATH" || echo "")"
		if [ -d "$IF_PATH" ] && [ -e "${IF_PATH}/device" ]; then
			NET_IF="$IF"
			break;
		fi
	done
	IF_ATTEMPT_COUNT=$(($IF_ATTEMPT_COUNT + 1))
	# Thankfully busybox supports fractional seconds for sleep
	sleep 0.1
done

log_begin_msg "Generating board hostname"
if set-cluster-node-hostname; then
	log_success_msg "Hostname set to $(hostname)"
else
	panic "Unable to generate hostname, /var mounting will fail."
fi
log_end_msg
