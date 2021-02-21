# Installing a root filesystem with `debootstrap`

`debootstrap` is a tool that lets us install a new Debian-based operating
system from an already running system. There are other ways a fresh installation
could be set up, but `debootstrap` also gives us a minimal system without extra
dependencies while also ensuring everything is up to date. The easiest way to do
this is to use an ARM machine to do the installation, and if you're installing
both 32 and 64 bit versions, you can use a 64 bit machine for both (I used a
Raspberry Pi 4B running Ubuntu 20.10 arm64).

Most of these commands need to be run as root. If the root account isn't enabled
on your system you can either prefix them with `sudo`, or start a root shell (ex: `sudo -s`).

1. Install necessary packages
    ```shell
    sudo apt update && sudo apt install -y --no-install-recommends nfs-common debootstrap debian-archive-keychain
    ```

1. Mount the various destination filesystems over NFS. We'll also declare a
   couple of environment variables used in later steps.
   ```shell
    # The path on the NFS server to the root cluster directory.
    NFS_ROOT=/mnt/tank/cluster
    # The IP address or hostname of your NFS server.
    NFS_SERVER="storage.example.com"
    # The directory where we're going to be mounting things locally
    MNT_ROOT=/tmp/cluster

    # If you're only installing one architecture (ex: if you're only using 
    # 64-bit nodes), edit this variable to match
    NET_ARCHS="armhf arm64"

    mkdir -p "${MNT_ROOT}/netboot"
    mount -t nfs -o vers=4 "${NFS_SERVER}:${NFS_ROOT}/netboot" "${MNT_ROOT}/netboot"
    for NET_ARCH in $NET_ARCHS; do
        mkdir -p "${MNT_ROOT}/rootfs_${NET_ARCH}"
        mount -t nfs -o vers=4 "${NFS_SERVER}:${NFS_ROOT}/root/${NET_ARCH}" "${MNT_ROOT}/rootfs_${NET_ARCH}"
    done
   ``` 

1. Now we'll use `debootstrap` to install a minimal system. We need the non-free
   components for the Raspberry Pi firmware, and we're using bullseye as the
   newer kernels have much better Raspberry Pi 4 support. If you're installing
   both architectures, you can do both in parallel (run the inner part of the
   loop, setting `$NET_ARCH` appropriately). If you do run them in parallel,
   make sure to also define `$MNT_ROOT` in the new shell as well.

    ```shell
    for NET_ARCH in $NET_ARCHS; do
        debootstrap \
            --arch=${NET_ARCH} \
            --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
            --components=main,contrib,non-free \
            --merged-usr \
            bullseye \
            ${MNT_ROOT}/rootfs_${NET_ARCH} \
            http://ftp.debian.org/debian/
    done
    ```

1. Before we chroot in to the newly installed systems we're going to temporarily
   mount some filesystems. The extra checks for 

    ```shell
    for NET_ARCH in armhf arm64; do
        for FS in dev sys proc; do
            TARGET_FS="${MNT_ROOT}/rootfs_${NET_ARCH}/${FS}"
            # Checking if they're already mounted
            if findmnt -f "$TARGET_FS" >/dev/null; then
                mount --rbind /${FS} "$TARGET_FS"
            fi
        done
        mkdir -p "${MNT_ROOT}/rootfs_${NET_ARCH}/boot/netboot"
        mount --bind "${MNT_ROOT}/netboot" "${MNT_ROOT}/rootfs_${NET_ARCH}/boot/netboot"
        mkdir -p "${MNT_ROOT}/rootfs_${NET_ARCH}/tmp"
        mount -t tmpfs tmpfs "${MNT_ROOT}/rootfs_${NET_ARCH}/tmp"
        mount --make-rslave "${MNT_ROOT}/rootfs_${NET_ARCH}"
    done
    ```

1. Now we `chroot` in to the fresh system. As with the `debootstrap` step, you
   can do both architectures in parallel.
    ```shell
    for NET_ARCH in $NET_ARCHES; do
        chroot "${MNT_ROOT}/rootfs_${NET_ARCH}" /bin/bash
    done
    ```

1. The final step in the host system is to chroot in to the newly bootstrapped
   systems and then install necessary packages. These instructions will add
   'deb.paxswill.com' as an APT repo and install the associated keyring. If you
   don't want to do that, you can also download the appropriate deb file from
   the [releases page](https://github.com/paxswill/cluster-netboot/releases) and
   install it manually. It won't be as nice though, as you'll have to resolve
   the dependencies yourself and you won't get later updates automatically.

    ```shell
    apt update && apt upgrade
    apt install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
    curl -o /tmp/paxswill-keyring.deb -L https://deb.paxswill.com/pool/main/p/paxswill-archive-keyring/paxswill-archive-keyring_2021.02.05_all.deb
    dpkg -i /tmp/paxswill-keyring.deb
    add-apt-repository "deb https://deb.paxswill.com bullseye main"
    apt update
    apt install cluster-netboot
    ```

   There will be some questions about merging configuration files (I'd recommend
   installing the new versions). There will also be a debconf prompt for configuring the storage servers and iSCSI names.

1. Now that the basic system is installed, add a user, set a root password (or
   configure sudo) and installa few extra packages that make life easier.

    ```shell
    apt install -y sudo locales openssh-server tmux bash-completion
    ```

   I personally am mounting my home directories over NFS, and using `autofs` to
   automatically mount them as needed. If you're not doing this, you don't need
   to specify the UID nor GID for the user.
    ```shell
    printf "/home\t/etc/home.map\n" > /etc/auto.master.d/home.autofs
    printf "*\t-fstype=nfs4,rw,nosuid\t%s:/mnt/tank/home/&\n" "$NFS_SERVER" > /etc/home.map
    adduser --
    addgroup --gid 1000 paxswill
    adduser --uid 1000 --home /home/paxswill --no-create-home --ingroup paxswill paxswill
    usermod -aG adm,dialout,sudo,cdrom,floppy,audio,dip,video,plugdev,netdev paxswill
    ```

# Setting up U-Boot

Each U-Boot node should get a little bit of extra configuration. If the node
doesn't have any local bootable source, it will eventually fall back to using
DHCP, and loading 'boot.scr.uimg' over TFTP. If you want to speed up the boot
process (or force U-Boot to ignore local bot devices) you have a few options:

* Add a local `boot.scr` file on a local boot device. For example, on the
  Raspberry Pi 2B (see below), create `boot.scr.txt` containing this:
  ```
  run bootcmd_dhcp
  ```
  Then format it for U-Boot:
  ```shell
  mkimage -T script -O u-boot -A invalid -d boot.scr.txt boot.scr
  ```
  Place `boot.scr` at the root of the local boot device (the SD card in the case
  of the Raspberry Pi 2B).

* Fiddle with saved environment variables. My Fingboxes are running a
  non-standard U-Boot (for better hardware support). They set up their
  networking hardware in an included `boot.scr` file, so while I could make a
  new `boot.scr` and append my extra command on to it, it was easier to do this
  in the U-Boot shell:
  ```shell
  setenv uenvcmd 'run bootcmd_dhcp'
  saveenv
  ```
  `uenvcmd` is a variable with a command that would normally continue on and
  boot the normal Fingbox software.

  For the same effect, you could also reorder the `boot_targets` variable. For
  example (this includes the U-Boot prompt and the output):
  ```
  => printenv boot_targets
  boot_targets=fel mmc0 mmc1 usb0 pxe dhcp
  => setenv boot_targets 'fel dhcp mmc0 mmc1 usb1 pxe'
  => saveenv
  ```
  This means the DHCP boot option is tried before the local boto devices, and
  before PXE boot (which can take a while to time out).

## Raspberry Pi 2 B

I have an early revision of the Model 2 B, with the BCM2836 (rev 1.2 changed to
a BCM2837, adding ARMv8 and native netboot support). U-Boot on the Raspberry Pis
supports netboot though, so setting up an SD card with just U-Boot and the
Raspberry Pi firmware files works pretty well.

1. On a Linux computer that has access to the SD card you're going to use:
    ```shell
    # Use the proper path to your SD card here!
    SDCARD=/dev/disk/by-id/foo-bar
    echo ";;0b;*" | sudo sfdisk $SDCARD
    sudo mkfs.vfat -F 32 -n boot ${SDCARD}-part1
    ```

1. Now just mount it somewhere and copy the boot files over. These commands
   assume they're being run from a device that's already booted from the 32-bit
   cluster (in my case, I used a BeagleBone). If you want to do this from a
   desktop, you can download and extract the
   [u-boot-rpi](https://packages.debian.org/bullseye/u-boot-rpi) and
   [raspi-firmware](https://packages.debian.org/bullseye/raspi-firmware)
   packages, and manually copy over/create `config.txt`:

    ```shell
    sudo mount ${SDCARD}-part1 /mnt
    sudo cp /usr/lib/raspi-firmware/* /mnt/
    sudo cp /usr/share/cluster-netboot/raspi-config.txt /mnt/config.txt
    sudo cp /uer/lib/u-boot/rpi_2/u-boot.bin /mnt/
    ```

## BeagleBone Black (and Green)

TODO: Expand this to an actual section. Short version: zero out the early part
of the on-board eMMC, write the MLO and U-Boot to the appropriate offsets on it,
add MBR and a small ext4 partition (with the start of the partition offset far
enough so the U-Boot file won't overlap!), and format the ext4 partition. Copy
`boot.scr` over to the partition.