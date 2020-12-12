# Loads and resolves the various config options. This file is intended to be
# sourced by cluster-netboot scripts. After sourcing it, the config variables
# will be set with the default values, optionally overridden by
# "/etc/defaults/cluster-netboot".

# Either the hostname or IP address of the NFS server. By defaulting to the
# empty string, the server IP from the DHCP server can be used.
CLUSTER_NFS_SERVER=

# The base of the exported path for the cluster filesystems.
CLUSTER_NFS_BASE_PATH=/mnt/cluster

# Load /etc/defaults/cluster-netboot after the simple settings, but before the
# settings that depend on earlier settings.
if [ -f /etc/defaults/cluster-netboot ]; then
    . /etc/defaults/cluster-netboot
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
    if [ -f "${_LOADER_RELATIVE_ROOT}/etc/defaults/cluster-netboot" ]; then
        . "${_LOADER_RELATIVE_ROOT}/etc/defaults/cluster-netboot"
    fi
    unset _LOADER_FULL_PATH
    unset _LOADER_RELATIVE_ROOT
fi


# The exported path to the root filesystems. If not set, defaults to
# ${CLUSTER_NFS_BASE_PATH}/root
CLUSTER_NFS_ROOT_PATH="${CLUSTER_NFS_ROOT_PATH:=${CLUSTER_NFS_BASE_PATH}/root}"

# It is also possible to set specific paths for each architecture's root by
# setting the variable name "CLUSTER_NFS_ROOT_${ARCH}_PATH" with ARCH being one
# of "armhf" or "arm64" (uppercased). If not set, the values default to
# "${CLUSTER_NFS_ROOT_PATH}/${ARCH}".
CLUSTER_NFS_ROOT_ARMHF_PATH="${CLUSTER_NFS_ROOT_ARMHF_PATH:-${CLUSTER_NFS_ROOT_PATH}/armhf}"
CLUSTER_NFS_ROOT_ARM64_PATH="${CLUSTER_NFS_ROOT_ARM64_PATH:-${CLUSTER_NFS_ROOT_PATH}/arm64}"

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
        _ROOT_MOUNTPOINT="${rootmnt:-/}"
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
        return ""
    fi
    echo "${_NFS_REGEX%%:*}"
    unset _ROOT_MOUNTPOINT
    unset _NFS_REGEX
    unset _NFS_ROOT
}

# The exported path to the netboot root. If not set, defaults to
# ${CLUSTER_NFS_BASE_PATH}/netboot
#CLUSTER_NFS_NETBOOT_PATH="${CLUSTER_NFS_BASE_PATH}/netboot"
CLUSTER_NFS_NETBOOT_PATH="${CLUSTER_NFS_NETBOOT_PATH:-${CLUSTER_NFS_BASE_PATH}/netboot}"

# The name of the U-Boot boot script defaults to "netboot.scr".
# The path to the U-Boot boot script within the netboot root. Defaults to
# "boot.scr" (meaning at the root of the netboot share).
CLUSTER_UBOOT_SCRIPT_NAME="${CLUSTER_UBOOT_SCRIPT_NAME:-netboot.scr}"

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
