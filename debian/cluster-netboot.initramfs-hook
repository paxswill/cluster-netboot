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
. /usr/share/initramfs-tools/hook-functions
# Begin real processing below this line
copy_exec /usr/sbin/generate-cluster-id /sbin/
copy_exec /usr/sbin/set-cluster-node-hostname /sbin/
