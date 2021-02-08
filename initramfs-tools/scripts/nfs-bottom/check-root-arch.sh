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

# Ensure that the root filesystem is the correct one for the architecture of
# this node.
# The config loading code is a shell script, so we can load it from the root FS,
# and then remount the root fs if needed.

. "${rootmnt}/usr/share/cluster-netboot/load-config.sh"

NFS_REGEX="^\([^ ]\+\) ${rootmnt} nfs \(.*\) [0-9] [0-9]"
CURRENT_ROOT="$(grep -o -m 1 -e "$NFS_REGEX" /proc/mounts)"
NFS_SERVER="${CURRENT_ROOT%%:*}"

if [ "$DPKG_ARCH" = "armhf" ] ; then
	INTENDED_ROOT="${NFS_SERVER}:${CLUSTER_NFS_ROOT_ARMHF_PATH}"
elif [ "$DPKG_ARCH" = "arm64" ]; then
	INTENDED_ROOT="${NFS_SERVER}:${CLUSTER_NFS_ROOT_ARM64_PATH}"
fi

if [ "$CURRENT_ROOT" != "$INTENDED_ROOT" ]; then
	log_warning_msg "Remounting proper root FS [${INTENDED_ROOT}]"
	umount "$rootmnt"
	nfsmount -o ro "$INTENDED_ROOT" "$rootmnt" || panic "Remount failed!"
fi
