An overview of the various servers required and their configuration. I recommend
setting these up on a separate network from your primary one, just in case
there's a conflict. For the examples given, the subnet is 203.0.113.0/24

# DHCP

In addition to distributing IP addresses to the nodes, the DHCP server also
provides the TFTP server IP address, the default boot file name, and the root
filesystem path. The 64-bit Raspberry Pis only require the TFTP server to be
defined (the Raspberry Pi [documentation][rpf-netboot] also says Option 43 needs
to be set to `Raspberry Pi Boot   `, but I haven't needed it).

[rpf-netboot]: https://www.raspberrypi.org/documentation/hardware/raspberrypi/bootmodes/net.md

One non-standard setting is to ignore client identifiers when recording leases.
The nodes have three different DHCP client implementations, and they aren't
consistent in how they use the client ID.

| Server | Configuration option |
|-|-|
| ISC dhcpd | `ignore-client-uids true;` in a pool block. |
| pfSense | Check the "Ignore client identifiers" setting for the DHCP server. |
| dnsmasq | `dhcp-ignore-clid` |

# File Servers

While the precise directory structure is configurable, I recommend creating a
directory structure like this (the exact path is up to you, `/srv` is just being
used as an example, as is the network 10.0.0.0/24):
```
/srv/cluster/
├── netboot/
└── root/
    ├── arm64/
    └── armhf/
```

If you're using ZFS, I recommend also put the zvols for the iSCSI volumes within
this dataset. This lets you easily snapshot the entire state of the cluster for
and roll it back to a known good state.

## TFTP

The TFTP root should be set to `/srv/cluster/netboot/`. For security purposes,
the server should be configured to **not** allow writing to files, or creation
of new files. I would also recommend enabling extra logging as it makes
debugging the boot process easier.

## NFS

The `netboot` and `root` directories need to be exported, and UID/GID 0
squashing needs to be disabled.

### Linux
`/etc/exports`
```
/srv/cluster/netboot 203.0.113.0/24(no_root_squash,rw)
/srv/cluster/root 203.0.113.0/24(no_root_squash,rw)
```
If you trust that your server won't crash in the middle of writing (or you don't
care if it does), you can add the `async` option within the parentheses for a
performance increase.

### FreeBSD
`/etc/exports`:
```
V4: / -sec=sys
/srv/cluster/netboot -maproot=0:0 -network 203.0.113.0/24
/srv/cluster/root -alldirs -maproot=0:0 -network 203.0.113.0/24
```

# iSCSI

TODO: Translate my TrueNAS iSCSI config to a generic config, usable by both
FreeBSD and Linux iSCSI server.