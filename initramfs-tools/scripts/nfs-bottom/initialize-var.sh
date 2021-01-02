#!/bin/sh
PREREQ="mount-var-iscsi.sh"
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

# Set /var/machine-id to contain "uninitialized\n" if that file does not already
# exist. This is so the "ConditionFirstBoot" systemd condition will be set
# appropriately. This action can't be done by systemd later in boot, because
# systemd checks for this file and the contents shortly after *it* starts.
if ! [ -f "${rootmnt}/var/machine-id" ]; then
	printf "uninitialized\n" > "${rootmnt}/var/machine-id"
fi