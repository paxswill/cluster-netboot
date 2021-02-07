#!/bin/sh
PREREQ="mount-var-iscsi-pre.sh"
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

# Set /var/machine-id to contain "uninitialized\n" if that file does not already
# exist. This is so the "ConditionFirstBoot" systemd condition will be set
# appropriately. This action can't be done by systemd later in boot, because
# systemd checks for this file and the contents shortly after *it* starts.
if ! [ -f "${PREMOUNTPOINT}/machine-id" ]; then
	printf "uninitialized\n" > "${PREMOUNTPOINT}/machine-id"
	log_success_msg "machine-id set to 'uninitialized'"
fi

# Mount the node-specific machine=id over the places where systemd and dbus
# expect it to be
mount -o bind "${PREMOUNTPOINT}/machine-id" "${rootmnt}/etc/machine-id"
if ! [ -e "${PREMOUNTPOINT}/lib/dbus/machine-id" ]; then
	mkdir -p "${PREMOUNTPOINT}/lib/dbus"
	ln -s ../../machine-id "${PREMOUNTPOINT}/lib/dbus/machine-id"
	log_success_msg "Linked dbus machine-id to machine-id"
fi
log_success_msg "Bound machine-id to /etc/machine-id"

# Copy over required state directories for some services
STATE_DIRS="nfs logrotate"
mkdir -p "${PREMOUNTPOINT}/lib"
for STATE_DIR in $STATE_DIRS; do
	if [ ! -d "${PREMOUNTPOINT}/lib/${STATE_DIR}" ]; then
		cp -a "${rootmnt}/var/lib/${STATE_DIR}" "${PREMOUNTPOINT}/lib/"
		log_success_msg "Initialized /var/lib/${STATE_DIR}"
	fi
done