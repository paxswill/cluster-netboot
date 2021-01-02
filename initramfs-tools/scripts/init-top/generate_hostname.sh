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

log_begin_msg "Generating board hostname"
if set-cluster-node-hostname; then
	log_success_msg "Hostname set to $(hostname)"
else
	panic "Unable to generate hostname, /var mounting will fail."
fi
log_end_msg
