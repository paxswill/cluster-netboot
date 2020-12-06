#!/usr/bin/env python3

from __future__ import annotations

import argparse
import contextlib
import enum
import functools
import hashlib
import io
import logging
import math
import os
import os.path
import shutil
import struct
import subprocess
import sys
import typing

import yaml


# Using a slightly different name for the logger to keep it Python-safe
log = logging.getLogger("update_firmware")
logging.basicConfig(
    level=logging.WARNING,
    format="%(levelname)s: %(message)s",
    stream=sys.stderr,
)


# Reimplementing BufferedIO, probably badly...
def read_exactly(
    handle: io.BinaryIO,
    length: int
) -> bytearray:
    starting_offset = handle.tell()
    remaining = length
    buffer = bytearray()
    # Try to use read1, which is only on buffered instances
    while remaining > 0:
        data = handle.read(remaining)
        if data is None:
            log.debug("Empty read() call, spinning...")
            continue
        elif len(data) == 0:
            log.warning("Unexpected EOF reached on %s", handle)
            return buffer
        else:
            log.debug("Read 0x%x bytes from %s", len(data), handle)
            remaining -= len(data)
            buffer.extend(data)
    return buffer


def find_mbr_first_partition(
    stream: io.BinaryIO,
) -> typing.Union[int, None]:
    """Find the offset of the first partition in an MBR.

    The given stream is assumed to be at offset 0 of a raw block device. If
    there is a valid MBR, the four primary partition entries are examined, and
    the entry with the lowest starting sector is found. The value of the
    starting sector is then multipled by 512 to get the byte offset of the first
    partition.

    If there is not a valid MBR, or no partitions are found, `None` is returned.
    """
    starting_offset = stream.tell()
    if starting_offset != 0:
        log.warning(
            "The starting offset of %s is not 0! (actual value is 0x%x)",
            stream,
            starting_offset,
        )
    # Skip forward to the boot signature and check that first
    MBR_BOOT_SIG_OFFSET = 0x1fe
    stream.seek(MBR_BOOT_SIG_OFFSET, os.SEEK_CUR)
    boot_sig_buf = read_exactly(stream, 2)
    boot_sig = struct.unpack("<2B", boot_sig_buf)
    if boot_sig != (0x55, 0xaa):
        log.warning(
            "Invalid boot signature (%s) found.",
            ", ".join(f"0x{n:x}" for n in boot_sig)
        )
        return None
    stream.seek(starting_offset, os.SEEK_SET)
    # Partition entries start at 0x1be, and are 16 bytes long. They follow one
    # after another four times, for a total of 64 bytes
    MBR_FIRST_PART_ENTRY = 0x1be
    stream.seek(MBR_FIRST_PART_ENTRY, os.SEEK_CUR)
    # Each partition entry has:
    # * flags (1 byte)
    # * CHS start (3 bytes, packed format)
    # * partition type (1 byte)
    # * CHS end (3 bytes, packed format)
    # * LBA start (4 bytes, int)
    # * Sector count (4 bytes, int)
    #
    # All values are little-endian. The CHS values are packed, but we're only
    # interested in the LBA of the starting sector, so I don't care about the
    # CHS values and don't need to unpack them.
    mbr_entry_format = "<B3sB3s2I"
    lowest_starting_sector = 0xffffffff
    for i in range(4):
        entry_buf = read_exactly(stream, 16)
        partition_entry = struct.unpack( mbr_entry_format, entry_buf)
        # All zeros is an empty entry which we can skip
        if not any(entry_buf):
            continue
        log.debug(
            "Partition entry %d values: %s",
            i,
            tuple(
                n.hex(" ") if isinstance(n, bytes) else f"0x{n:x}"
                for n in partition_entry
            )
        )
        if partition_entry[4] < lowest_starting_sector:
            lowest_starting_sector = partition_entry[4]
            log.debug(
                "New lowest starting sector of %s (0x%x)",
                lowest_starting_sector,
                lowest_starting_sector,
            )
    SECTOR_SIZE = 512
    return SECTOR_SIZE * lowest_starting_sector


def get_mlo_toc_size(
    stream: io.BinaryIO
) -> typing.Union[int, None]:
    """Determine the size of a possible MLO image.

    The given stream is checked starting from its current position. If a valid
    TOC is found there, the total size in bytes of the MLO image is returned. If
    no image is found, ``None`` is returned.
    """
    starting_offset = stream.tell()
    # Instead of manually verifying each field, I'm just going to hash the
    # entire TOC. The contents are fixed, even though a quick read of the
    # documentation looks like it might be used in other places where the
    # content could vary.
    toc_hasher = hashlib.sha256()
    TOC_LEN = 512
    toc_data = read_exactly(stream, TOC_LEN)
    if toc_data is None:
        return None
    toc_hasher.update(toc_data)
    toc_hex = toc_hasher.hexdigest()
    log.debug("TOC hash for %s at 0x%x: %s", stream, starting_offset, toc_hex)
    expected_hash = (
        "21a542439d495f829f448325a75a2a377bf84c107751fe77a0aeb321d1e23868"
    ) 
    if toc_hex != expected_hash:
        log.debug("TOC hash at %s, offset 0x%x did not match", stream, starting_offset)
        return None
    # Relying on the read position of stream being where it was left from
    # reading the TOC
    image_len_buf = read_exactly(stream, 4)
    if image_len_buf is None:
        return None
    image_len = struct.unpack_from("<I", image_len_buf)[0]
    return image_len + TOC_LEN


def get_u_boot_legacy_size(
    stream: io.BinaryIO,
) -> typing.Union[int, None]:
    """Determine the size of a possible U-Boot legacy image.

    The given stream is checked starting from its current position. If a valid
    U-Boot legacy image is found there, the total size in bytes of the image is
    returned. If no image is found, ``None`` is returned.
    """
    U_BOOT_HEADER_LEN = 64
    header_buf = read_exactly(stream, U_BOOT_HEADER_LEN)
    if header_buf is None:
        return None
    # This format spec is based on the U-Boot sources, specifically the
    # definition of image_header_t in include/image.h
    header_format = ">7I4B32s"
    parsed_header = struct.unpack(header_format, header_buf)
    # The only fields we care about are the magic number (at index 0) and the
    # image data size (at index 3).
    UBOOT_LEGACY_MAGIC = 0x27051956
    if parsed_header[0] != UBOOT_LEGACY_MAGIC:
        return None
    return parsed_header[3] + U_BOOT_HEADER_LEN


def get_u_boot_fit_size(
    stream: io.BinaryIO,
) -> typing.Union[int, None]:
    """Determine the size of a possible U-Boot FIT image.

    The given stream is checked starting from its current position. If a valid
    U-Boot FIT image is found there, the total size in bytes of the image is
    returned. If no image is found, ``None`` is returned.
    """
    starting_offset = stream.tell()
    # The first 8 bytes of a flattened device tree (FDT) are a magic number, and
    # the total size of the FDT.
    buf = read_exactly(stream, 8)
    if buf is None:
        return None
    magic, fdt_len = struct.unpack(">2I", buf)
    if magic != 0xd00dfeed:
        log.debug(
            "Magic number for %s at 0x%x does not match for an FDT",
            stream,
            starting_offset
        )
        return None
    # Extract the FDT from the device (and only the FDT, which we can do because
    # the size is now known). Feed it into dtc to decompile it, then convert the
    # DTS to YAML for easier parsing.
    stream.seek(starting_offset, os.SEEK_SET)
    read_pipe, write_pipe = os.pipe()
    # Fork so we can have a process feed the data in to the pipe.
    if os.fork() != 0:
        os.close(write_pipe)
    else:
        os.close(read_pipe)
        fdt_data = read_exactly(stream, fdt_len)
        os.write(write_pipe, fdt_data) # type: ignore
        os.close(write_pipe)
        sys.exit()
    decompile = subprocess.Popen(
        ["dtc", "-I", "dtb", "-O", "dts", "-o", "-", "-"],
        stdin=read_pipe,
        stdout=subprocess.PIPE,
        close_fds=True,
    )
    yaml_convert = subprocess.Popen(
        ["dtc", "-I", "dts", "-O", "yaml", "-o", "-", "-"],
        stdin=decompile.stdout,
        stdout=subprocess.PIPE,
    )
    fit_yaml = yaml.safe_load_all(yaml_convert.communicate()[0])
    # FIT uses the DTS format, with a couple of differences. We only care about
    # the "images" nodes. To figure out the size of the FIT image, we look at
    # the "data-size" and "data-offset" properties of the image nodes.
    try:
        # We only care about the first document, and the first tree in that
        # document.
        images = next(iter(fit_yaml))[0]["images"]
        largest_offset = 0
        offset_size = 0
        for image_data in images.values():
            # The data-[size,offset] properties have only one value
            image_offset = image_data["data-offset"][0][0]
            image_size = image_data["data-size"][0][0]
            log.debug(
                "Found image with offset 0x%x and size %d",
                image_offset,
                image_size,
            )
            if image_offset > largest_offset:
                largest_offset = image_offset
                offset_size = image_size
    except (KeyError, IndexError) as exc:
        log.exception("Invalid access in FIT parsing")
        return None
    # The full size is now the FDT size + (the largest image offset + the size
    # of that image, rounded up to the nearest 4-byte boundary)
    extra_len = largest_offset + offset_size
    return fdt_len + (4 * math.ceil(extra_len / 4))


def get_u_boot_size(
    stream: io.BinaryIO,
) -> typing.Union[int, None]:
    starting_offset = stream.tell()
    if legacy_size := get_u_boot_legacy_size(stream):
        return legacy_size
    else:
        stream.seek(starting_offset, os.SEEK_SET)
        return get_u_boot_fit_size(stream)


class OpenMode(enum.Enum):

    READ = "r"

    WRITE = "w"

    READ_WRITE = "rw"

    def __contains__(self, other):
        if isinstance(other, OpenMode):
            return other.value in self.value
        return NotImplemented


@contextlib.contextmanager
def open_raw_device(
    name: os.PathLike,
    mode: OpenMode = OpenMode.READ
) -> typing.Iterator[io.BinaryIO]:
    """A context manager for opening raw block devices.

    It takes the name of a device and opens it in a manner that ensures (as much
    as possible) that all data is written to disk as soon as possible.
    """
    if not os.path.isabs(name):
        path = os.path.join("/dev", name)
    else:
        path = name
    if not os.path.exists(path):
        raise ValueError(f"Device '{path}' cannot be found.")
    if mode is OpenMode.READ:
        flags = os.O_RDONLY
        # If we're only reading, use a buffered stream. Otherwise use a raw
        # stream.
        buffer_mode = -1
    elif mode is OpenMode.WRITE:
        flags = os.O_WRONLY
        buffer_mode = 0
    elif mode is OpenMode.READ_WRITE:
        flags = os.O_RDWR
        buffer_mode = 0
    else:
        raise ValueError("Unknown open mode: %s", mode)
    try:
        fd = os.open(path, flags)
        os.set_blocking(fd, True)
        file_obj = os.fdopen(
            fd,
            mode=mode.value + "b",
            buffering=buffer_mode,
            closefd=False
        )
        log.debug("Opened FD %d for path %s", fd, path)
        yield file_obj # type: ignore
    finally:
        file_obj.flush()
        file_obj.close()
        os.fsync(fd)
        os.close(fd)
        log.debug("Closed FD %d for path %s", fd, path)

@functools.total_ordering
class ImageKind(enum.Enum):

    #: Called SPL images by U-Boot, and MLO in the AM335x Reference Manual.
    MLO = "MLO image"

    #: Covers both U-Boot legacy and FIT images.
    UBOOT = "U-Boot image"

    def __lt__(self, other):
        if not isinstance(other, type(self)):
            return NotImplemented
        # MLO before U-Boot
        return self is self.MLO and other is self.UBOOT


class FirmwareImage(object):
    """A combination of device, offset, image type, and image size."""

    #: The device name or this image was found on, or a path to a bootloader
    #: image file.
    device: os.PathLike

    #: The offset on the device that the image was found at.
    offset: int

    #: The kind of image it is.
    kind: ImageKind

    size: int

    @typing.overload
    def __init__(
        self,
        device: os.PathLike,
        offset: int,
        kind: ImageKind,
        size: int,
    ):
        """Create a `FilesystemImage` for a raw image on a block device."""
        pass

    @typing.overload
    def __init__(
        self,
        device: os.PathLike,
        kind: ImageKind,
    ):
        """Create a `FirmwareImage` representing a file on a filesystem."""
        pass

    def __init__(self, *args, **kwargs):
        attr_names = ("device", "offset", "kind", "size")
        if len(args) == 4:
            for attr_name, arg in zip(attr_names, args):
                setattr(self, attr_name, arg)
        elif kwargs.keys() == set(attr_names):
            for attr_name in attr_names:
                setattr(self, attr_name, kwargs[attr_name])
        elif len(args) == 2:
            self.device, self.kind = args
            self.offset = 0
            stat = os.stat(self.device)
            self.size = stat.st_size
        elif kwargs.keys() == {"device", "kind"}:
            self.device = kwargs["device"]
            self.kind = kwargs["kind"]
            self.offset = 0
            stat = os.stat(self.device)
            self.size = stat.st_size
        else:
            raise ValueError()

    @functools.cached_property
    def hexdigest(self) -> str:
        with open_raw_device(self.device) as raw_device:
            raw_device.seek(self.offset)
            hasher = hashlib.sha256(
                read_exactly(raw_device, self.size)
            )
        return hasher.hexdigest()

    @property
    def path(self):
        return self.device

    def __eq__(self, other):
        if isinstance(other, FirmwareImage):
            return self.hexdigest == other.hexdigest
        elif isinstance(other, int):
            return self.offset == other
        else:
            return NotImplemented

    def __lt__(self, other):
        if isinstance(other, FirmwareImage):
            return self.offset + self.size < other.offset
        elif isinstance(other, int):
            return self.offset + self.size < other
        else:
            return NotImplemented

    def __le__(self, other):
        if isinstance(other, FirmwareImage):
            return self.offset + self.size <= other.offset
        elif isinstance(other, int):
            return self.offset + self.size <= other
        else:
            return NotImplemented

    def __gt__(self, other):
        if isinstance(other, FirmwareImage):
            return self.offset + self.size > other.offset
        elif isinstance(other, int):
            return self.offset + self.size > other
        else:
            return NotImplemented

    def __ge__(self, other):
        if isinstance(other, FirmwareImage):
            return self.offset + self.size >= other.offset
        elif isinstance(other, int):
            return self.offset + self.size >= other
        else:
            return NotImplemented

    def __matmul__(
        self,
        new_offset: typing.Union[int, FirmwareImage]
    ) -> FirmwareImage:
        """Return a copy of this object, but with a different `offset`."""
        if isinstance(new_offset, int):
            if new_offset < 0:
                raise ValueError(
                    f"The new offset ({new_offset}) must be greater than 0"
                )
        elif isinstance(new_offset, FirmwareImage):
            new_offset = new_offset.offset
        else:
            return NotImplemented
        return type(self)(self.device, new_offset, self.kind, self.size)

    def __repr__(self):
        # defining repr so that the size and offset are in hex
        return (
            f"{self.__class__.__name__}('{self.device}', 0x{self.offset:x}, "
            f"ImageKind.{self.kind.name}, 0x{self.size:x})"
        )


def find_images(device_name: str) -> typing.Collection[FirmwareImage]:
    images = []
    with open_raw_device(device_name, OpenMode.READ) as device:
        for offset in (0, 0x20000, 0x40000, 0x60000):
            device.seek(offset, os.SEEK_SET)
            if image_size := get_mlo_toc_size(device):
                images.append(FirmwareImage( # type: ignore
                    device_name,
                    offset,
                    ImageKind.MLO,
                    image_size
                ))
            else:
                device.seek(offset, os.SEEK_SET)
                if image_size := get_u_boot_size(device):
                    images.append(FirmwareImage( # type: ignore
                        device_name,
                        offset,
                        ImageKind.UBOOT,
                        image_size
                    ))
    return images


def compare_images(
    new_mlo: FirmwareImage,
    new_u_boot: FirmwareImage,
    devices: typing.Iterable[str],
) -> typing.Sequence[FirmwareImage]:
    """Update BeagleBone Black/Green firmware.

    This handles both raw and FAT bootloader configurations (see section
    26.1.8.5 of the AM335x Reference Manual for more details).
    """
    # There are two possible MMC/SD devices on BeagleBones, mmcblk0 and 1, and
    # four possible locations for the MLO: 0, 0x20000, 0x40000, and 0x60000.
    # The full U-Boot image is then (possibly) at one of the later loader
    # locations.
    images_to_update = []
    for device_name in devices:
        try:
            with open_raw_device(device_name) as device:
                lowest_partition_start = find_mbr_first_partition(device)
                # Just not handling the case where there's no MBR
                if lowest_partition_start is None:
                    log.info(
                        "No MBR found on device '%s', skipping.",
                        device_name
                    )
                    continue
            images = find_images(device_name)
        except ValueError:
            # ValueError from open_raw_device, for non-existent device names
            continue
        if not images:
            log.debug("No firmware images found on device '%s'", device_name)
            continue
        for image in images:
            if image.offset == 0:
                # This error should not be hit
                log.error("%s would overlap the MBR", image)
                continue
            # "shift" the new image to the offset of the old image
            if image.kind is ImageKind.MLO:
                new_image = new_mlo
            elif image.kind is ImageKind.UBOOT:
                new_image = new_u_boot
            else:
                raise ValueError("Unknown image kind %s", image.kind)
            if new_image @ image >= lowest_partition_start:
                log.error(
                    "%s would overlap the partition starting at 0x%x",
                    image
                )
                continue
            # The equality operation *only* checks the sha256 hash of the data
            if new_image != image:
                log.info(
                    (
                        "New %(kind)s (%(path)s) does not match existing "
                        "%(kind)s on %(device_name)s at offset 0x%(offset)x"
                    ),
                    {
                        "kind": image.kind.value,
                        "path": new_image.path,
                        "device_name": device_name,
                        "offset": image.offset,
                    }
                )
                log.debug(
                    "%-20s: %s",
                    "New image hash",
                    new_image.hexdigest
                )
                log.debug(
                    "%-20s: %s",
                    "Existing image hash",
                    image.hexdigest
                )
                images_to_update.append(image)
    return images_to_update


class MainAction(enum.Enum):

    DRY_RUN = enum.auto()

    INTERACTIVE = enum.auto()

    FORCE = enum.auto()


def copy_raw(
    new_image: FirmwareImage,
    old_image: FirmwareImage,
):
    # TODO:
    pass


def update_raw_beaglebone(
    new_mlo_path: os.PathLike,
    new_u_boot_path: os.PathLike,
    devices: typing.Iterable[str],
    action: MainAction,
) -> bool:
    if not os.path.exists(new_mlo_path):
        raise ValueError(
            f"MLO file ({new_mlo_path}) does not exist."
        )
    if not os.path.exists(new_u_boot_path):
        raise ValueError(
            f"U-Boot file ({new_u_boot_path}) does not exist."
        )
    # Check that the files given are actually the appropriate kind of files.
    with open(new_mlo_path, "rb") as mlo_file:
        if not get_mlo_toc_size(mlo_file):
            raise ValueError(f"{new_mlo_path} does not have a valid TOC")
    with open(new_u_boot_path, "rb") as u_boot_file:
        if not get_u_boot_size(u_boot_file):
            raise ValueError(f"{new_u_boot_path} is not a valid U-Boot image")
    new_mlo = FirmwareImage(new_mlo_path, ImageKind.MLO)
    new_u_boot = FirmwareImage(new_u_boot_path, ImageKind.UBOOT)
    new_images = {
        ImageKind.MLO: new_mlo,
        ImageKind.UBOOT: new_u_boot,
    }
    outdated_images = list(compare_images(new_mlo, new_u_boot, devices))
    # Sort the images by kind, then device, then by offset
    outdated_images.sort(key=lambda i: (i.kind, i.device, i.offset))

    for image in outdated_images:
        destination_message = (
            f"{image.kind.value} at 0x{image.offset:x} on {image.device}"
        )
        source_message = (
            f"{new_images[image.kind].path} "
            f"({new_images[image.kind].size} bytes)"
        )
        if action is MainAction.DRY_RUN:
            print(
                f"{destination_message} would be overwritten by "
                f"{source_message}"
            )
        elif action is MainAction.FORCE:
            print(
                f"{destination_message} will be overwritten with the contents "
                f"of {source_message}"
            )
            copy_raw(new_images[image.kind], image)
        elif action is MainAction.INTERACTIVE:
            response = input(
                f"Should {destination_message} be overwritten by "
                f"{source_message}? [y/N] "
            )
            cleaned_response = response.lower().strip()
            if cleaned_response not in ("y", "yes"):
                print("Skipping...")
            else:
                copy_raw(new_images[image.kind], image)
    return bool(outdated_images)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Check and update AM335x MMC bootloaders",
        # TODO: add extra help describing the exit status
    )
    # Action arguments
    action_group = parser.add_mutually_exclusive_group()
    action_group.add_argument(
        "--dry-run", "-n",
        action="store_const",
        const=MainAction.DRY_RUN,
        help=(
            "Print messages showing which installed bootloaders do match the"
            " bootloader files, with no changes actually written. This is the"
            " default when not run interactively."
        ),
        dest="action",
    )
    action_group.add_argument(
        "--interactive", "-i",
        action="store_const",
        const=MainAction.INTERACTIVE,
        help=(
            "Prompt for confirmation for every change. This is the default when"
            " run interactively."
        ),
        dest="action",
    )
    action_group.add_argument(
        "--force", "-f",
        action="store_const",
        const=MainAction.FORCE,
        help=(
            "Replace any installed bootloaders that do not match the given "
            "files without confirmation."
        ),
        dest="action",
    )
    parser.set_defaults(
        action=MainAction.INTERACTIVE if os.isatty(1) else MainAction.DRY_RUN
    )
    # Target selection arguments
    DEFAULT_MLO_PATH = "/usr/lib/u-boot/am335x_evm/MLO"
    parser.add_argument(
        "--mlo", "-m",
        action="store",
        help=f"Path to the MLO file to use (default: {DEFAULT_MLO_PATH}).",
        default=DEFAULT_MLO_PATH,
        metavar="/path/to/MLO",
    )
    DEFAULT_UBOOT_PATH = "/usr/lib/u-boot/am335x_evm/u-boot.img"
    parser.add_argument(
        "--uboot", "-u",
        action="store",
        help=f"Path to the U-Boot file to use (default: {DEFAULT_UBOOT_PATH}).",
        default=DEFAULT_UBOOT_PATH,
        metavar="/path/to/u-boot.img",
    )
    parser.add_argument(
        "--device", "-d",
        action="append",
        help=(
            "Specify which MMC devices to check. If the device cannot be "
            "found, it is skipped (default: mmcblk0 and mmcblk1)."
        ),
        default=["mmcblk0", "mmcblk1"],
        dest="devices",
    )
    # Logging arguments
    logging_group = parser.add_mutually_exclusive_group()
    logging_group.add_argument(
        "--verbose", "-v",
        action="count",
        help=(
            "Increase logging verbosity. May be given more than once to "
            "further increase verbosity."
        ),
        default=0,
        dest="log_level"
    )
    logging_group.add_argument(
        "--quiet", "-q",
        action="store_const",
        const=-1,
        help="Suppress all output.",
        dest="log_level",
    )
    args = parser.parse_args()
    # Set log level first
    log_levels = {
        -1: logging.CRITICAL,
        0: logging.WARNING,
        1: logging.INFO,
        2: logging.DEBUG,
    }
    log.level = log_levels.get(
        # Clamp the value to a max of 2
        min(2, args.log_level),
        # If all else fails, give a default
        logging.WARNING
    )
    # We need root to access block devices directly. Do this check after parsing
    # args so that the help message can be printed as a normal user.
    if os.geteuid() != 0:
        log.error("This program must be run as root.")
        sys.exit(-1)
    # This only makes sense to run on AM335x devices
    FDT_MODEL_PATH = "/proc/device-tree/model"
    if not os.path.exists(FDT_MODEL_PATH):
        log.error(
            "This device does not have a device tree, and can't be an "
            "AM335x device."
        )
        sys.exit(-1)
    with open(FDT_MODEL_PATH, "r") as model:
        model_name = model.read().lower()
        if "am335x" not in model_name:
            log.error("This does not appear to be an AM335x device.")
            sys.exit(-1)
    try:
        bootloader_difference = update_raw_beaglebone(
            args.mlo,
            args.uboot,
            args.devices,
            args.action,
        )
    except ValueError as exc:
        log.error("%s", exc)
        sys.exit(-1)
    if bootloader_difference:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()