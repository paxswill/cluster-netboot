#!/bin/sh
PREREQ="initialize-var.sh"
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

set -e

PREMOUNTPOINT=/tmp/instance-var-pre
mount --move "$PREMOUNTPOINT" "${rootmnt}/var" || panic "Unable to move instance var mountpoint!"

log_success_msg "Moved instance /var over root filesystem"
