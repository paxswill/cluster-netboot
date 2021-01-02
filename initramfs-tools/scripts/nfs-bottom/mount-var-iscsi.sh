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

set -e

log_begin_msg "Mounting instance-specific /var over iSCSI"
INSTANCE_ID="$(generate-id)"
if [ -z "$INSTANCE_ID" ]; then
	panic "Unable to generate a valid instance ID"
fi

# At this point in initramfs (nfs-bottom), the root FS has been mounted over
# NFS, so we can just source the config from there.
. "${rootmnt}/usr/share/cluster-netboot/load-config.sh"

INITIATOR_NAME="iqn.${CLUSTER_ISCSI_INITIATOR}:host-${INSTANCE_ID}"
TARGET_NAME="iqn.${CLUSTER_ISCSI_TARGET}:${INSTANCE_ID}"

iscsistart -i $INITIATOR_NAME -t $TARGET_NAME -g 1 -a 172.17.9.5
# Wait a beat for iSCSI to get set up
sleep 3
mount -t ext4 /dev/disk/by-label/instance-var ${rootmnt}/var || panic "Unable to mount!"

log_end_msg
