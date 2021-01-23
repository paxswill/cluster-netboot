# Loads and resolves the various config options. This file is intended to be
# sourced by cluster-netboot scripts. After sourcing it, the config variables
# will be set with the default values, optionally overridden by
# "/etc/defaults/cluster-netboot".

# Either the hostname or IP address of the NFS server. By defaulting to the
# empty string, the server IP from the DHCP server can be used.
CLUSTER_NFS_SERVER=

# The base of the exported path for the cluster filesystems.
CLUSTER_NFS_BASE_PATH=/mnt/cluster

# The date and domain name used for the iSCSI *initiator*. The default is
# "2020-12.com.paxswill.cluster-netboot", but it is encouraged that it be set to
# a site-specific value. See RFC 3720, section 3.2.6.3.1 for the formatting.
# This is *just* the date and domain portion, "iqn." and a node-specific ID will
# be added automatically.
CLUSTER_ISCSI_INITIATOR=2020-12.com.paxswill.cluster-netboot

# Load /etc/defaults/cluster-netboot after the simple settings, but before the
# settings that depend on earlier settings.
CLUSTER_CONFIGFILE=/etc/cluster-netboot/config
if [ -f $CLUSTER_CONFIGFILE ]; then
    . $CLUSTER_CONFIGFILE
else
    # Try finding the defaults config relative to this file (used when being
    # sourced in initramfs from sysroot). This only works if this script is
    # located at /usr/share/cluster-netboot
    # If in bash, we can use BASH_SOURCE, otherwise we get to walk procfs.
    if [ -n "$BASH" ]; then
        _LOADER_FULL_PATH="$(realpath "$BASH_SOURCE")"
    else
        # realpath, sort, and tail are available through busybox in initramfs.
        _LOADER_FULL_PATH="$(readlink -f \
            "/proc/$$/fd/$(ls -1 /proc/$$/fd | sort -n | tail -1)"
        )"
    fi
    _LOADER_RELATIVE_ROOT="$(realpath \
        "$(dirname ${_LOADER_FULL_PATH})/../../.."
    )"
    if [ -f "${_LOADER_RELATIVE_ROOT}${CLUSTER_CONFIGFILE}" ]; then
        . "${_LOADER_RELATIVE_ROOT}${CLUSTER_CONFIGFILE}"
    fi
    unset _LOADER_FULL_PATH
    unset _LOADER_RELATIVE_ROOT
fi
unset CLUSTER_CONFIGFILE

# Ensure that CLUSTER_NFS_BASE_PATH does not have a trailing slash.
CLUSTER_NFS_BASE_PATH="${CLUSTER_NFS_BASE_PATH%/}"

# The date and domain for the iSCSI *target*. If not set, the value from
# CLUSTER_ISCSI_INITIATOR will be used. The same guidelines for that value also
# apply here.
CLUSTER_ISCSI_TARGET="${CLUSTER_ISCSI_TARGET:=${CLUSTER_ISCSI_INITIATOR}}"

# The iSCSI server to use for mounting each node's /var. If left at the default
# (an empty string), the same value as CLUSTER_NFS_SERVER will be used. If
# CLUSTER_NFS_SERVER is also left at it's default value (also an empty string),
# the same hostname or IP address that was used to mount the root filesystem
# will be used (which is typically provided via DHCP).
CLUSTER_ISCSI_SERVER="${CLUSTER_ISCSI_SERVER:-${CLUSTER_NFS_SERVER}}"

# It is possible to set specific paths for each architecture's root by
# setting the variable name "CLUSTER_NFS_ROOT_${ARCH}_PATH" with ARCH being one
# of "armhf" or "arm64" (uppercased). If not set, the values default to
# "root/${ARCH}". Note that the default value does not start with a leading
# slash. Without a leading slash, the path is interpreted as relative to the NFS
# base path defined earlier.
CLUSTER_NFS_ROOT_ARMHF_PATH="${CLUSTER_NFS_ROOT_ARMHF_PATH:-root/armhf}"
CLUSTER_NFS_ROOT_ARM64_PATH="${CLUSTER_NFS_ROOT_ARM64_PATH:-root/arm64}"

# Because not every usage of this script will need the resolved NFS server, and
# this lookup requires shelling out to some external commands, it's being kept
# behind a function.
cluster_nfs_server_resolved() {
    # There is only one (optional) argument, the path to the root filesystem. If
    # it's not given, the variable 'rootmnt' is used (if it's set and not null),
    # falling back to '/'. 'rootmnt' is defined in initramfs scripts, which is
    # one of the places this script may be sourced.
    # The return value is the hostname *or* IP address of the NFS server. If /
    # is not mounted over NFS, an empty string is returned.
    if [ "$1" = "" ]; then
        _ROOT_MOUNTPOINT="/"
    else
        _ROOT_MOUNTPOINT="$1"
    fi
    # This regex has two capture groups, the first for the combination of NFS
    # server and exported path, and the second for the mount options. They're
    # not used currently, but are being kept for now.
    _NFS_REGEX="^\([^ ]\+\) ${_ROOT_MOUNTPOINT} nfs \(.*\) [0-9] [0-9]"
    # Use _NFS_REGEX (but ignoring the capture groups) to find the mount entry
    # for the root filesystem
    # -o and -m are extensions to POSIX grep, but are present in busybox grep.
    _NFS_ROOT="$(grep -o -m 1 -e "$_NFS_REGEX" /proc/mounts)"
    if [ "$_NFS_ROOT" = "" ]; then
        echo ""
    else
        echo "${_NFS_ROOT%%:*}"
    fi
    unset _ROOT_MOUNTPOINT
    unset _NFS_REGEX
    unset _NFS_ROOT
}

# The exported path to the netboot root. If not set, defaults to
# "netboot", and like the root paths above, means that this is relative to the
# NFS base path.
CLUSTER_NFS_NETBOOT_PATH="${CLUSTER_NFS_NETBOOT_PATH:-netboot}"

# This expands the NFS paths as appropriate
_expand_nfs_path() {
    # One argument, the *name* of the variable being expanded
    eval value="\$$1"
    if [ "${value#/}" = "$value" ]; then
        # it's relative, append to $CLUSTER_NFS_BASE_PATH
        eval ${1}="${CLUSTER_NFS_BASE_PATH}/${value}"
    fi
    unset value
}
_expand_nfs_path CLUSTER_NFS_ROOT_ARMHF_PATH
_expand_nfs_path CLUSTER_NFS_ROOT_ARM64_PATH
_expand_nfs_path CLUSTER_NFS_NETBOOT_PATH
unset -f _expand_nfs_path

# The path and name to the U-Boot boot script within the netboot root. Defaults
# to "boot.scr" (meaning at the root of the netboot share). "boot.scr" is a
# common default for U-Boot boot scripts to load over DHCP (if their
# distro_bootcmd gets to bootcmd_dhcp).
CLUSTER_UBOOT_SCRIPT_NAME="${CLUSTER_UBOOT_SCRIPT_NAME:-boot.scr}"

# The kernel command line used for Raspberry Pis that can natively netboot.
# If not set, the default is "net.ifnames=0 console=ttyS0,115200n8 root=/dev/nfs
# nfsroot=${CLUSTER_NFS_ROOT_ARM64_PATH} ro ip=dhcp rootwait fixrtc panic=10
# ${CLUSTER_RASPI_EXTRA_CMDLINE}". If CLUSTER_NFS_SERVER is set to a non-empty
# string, it will be prepended to the value for "nfsroot" with a colon.
# 
# This allows a way to completely override the command line, instead of just
# adding some extra to it. If all you want to do is add some extra arguments,
# use CLUSTER_RASPI_EXTRA_CMDLINE.
CLUSTER_RASPI_CMDLINE="${CLUSTER_RASPI_CMDLINE:-"\
net.ifnames=0 \
console=ttyS0,115200n8 \
root=/dev/nfs \
nfsroot=${CLUSTER_NFS_SERVER:+"${CLUSTER_NFS_SERVER}:"}${CLUSTER_NFS_ROOT_ARM64_PATH} \
ro \
ip=dhcp \
rootwait \
fixrtc \
panic=10${CLUSTER_RASPI_EXTRA_CMDLINE:+ }${CLUSTER_RASPI_EXTRA_CMDLINE:-} \
"}"
# The extra parameter expansion at the end there is to ensure an unset variable
# isn't expanded.
