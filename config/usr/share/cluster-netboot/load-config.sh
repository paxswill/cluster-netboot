# Loads and resolves the various config options. This file is intended to be
# sourced by cluster-netboot scripts. After sourcing it, the config variables
# will be set with the default values, optionally overridden by
# "/etc/defaults/cluster-netboot".

# Either the hostname or IP address of the NFS server. By defaulting to the
# empty string, the server IP from the DHCP server can be used.
CLUSTER_NFS_SERVER=

# The base of the exported path for the cluster filesystems.
CLUSTER_NFS_BASE_PATH=/mnt/cluster

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
fi

# If we've booted a cluster node, there's sometimes a need to the actual,
# resolved NFS server name.
# TODO: Add a CLUSTER_NFS_SERVER_RESOLVED variable

# The exported path to the root filesystems. If not set, defaults to
# ${CLUSTER_NFS_BASE_PATH}/root
CLUSTER_NFS_ROOT_PATH="${CLUSTER_NFS_ROOT_PATH:=${CLUSTER_NFS_BASE_PATH}/root}"

# It is also possible to set specific paths for each architecture's root by
# setting the variable name "CLUSTER_NFS_ROOT_${ARCH}_PATH" with ARCH being one
# of "armhf" or "arm64" (uppercased). If not set, the values default to
# "${CLUSTER_NFS_ROOT_PATH}/${ARCH}".
CLUSTER_NFS_ROOT_ARMHF_PATH="${CLUSTER_NFS_ROOT_ARMHF_PATH:-${CLUSTER_NFS_ROOT_PATH}/armhf}"
CLUSTER_NFS_ROOT_ARM64_PATH="${CLUSTER_NFS_ROOT_ARM64_PATH:-${CLUSTER_NFS_ROOT_PATH}/arm64}"

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
panic=10${CLUSTER_RASPI_EXTRA_CMDLINE:+ }${CLUSTER_RASPI_EXTRA_CMDLINE} \
"}"