#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""fatimg.py - build a minimal FAT16 image containing the UEFI app at
\EFI\BOOT\BOOTX64.EFI (OVMF's default boot path)."""

import struct
import sys

SECTOR = 512
TOTAL_SECTORS = 32768          # 16 MiB
SECTORS_PER_CLUSTER = 1
ROOT_ENTRIES = 512
RESERVED = 1
FATS = 2
MEDIA = 0xF8


def fat_sectors(clusters):
    return (clusters * 2 + SECTOR - 1) // SECTOR


def dirent(name, ext, attr, cluster, size):
    e = bytearray(32)
    e[0:8] = name.encode().upper().ljust(8, b" ")
    e[8:11] = ext.encode().upper().ljust(3, b" ")
    e[11] = attr
    struct.pack_into("<HHH", e, 22, 0x2A00, 0x2A00, 0x2A00)  # time/date
    struct.pack_into("<H", e, 26, cluster)
    struct.pack_into("<I", e, 28, size)
    return bytes(e)


def build(img, app_data):
    # Compute FAT size for the data region.
    root_sectors = (ROOT_ENTRIES * 32 + SECTOR - 1) // SECTOR
    fat_sz = fat_sectors(TOTAL_SECTORS)
    while True:
        data_start = RESERVED + FATS * fat_sz + root_sectors
        clusters = TOTAL_SECTORS - data_start
        new_fat = fat_sectors(clusters)
        if new_fat == fat_sz:
            break
        fat_sz = new_fat

    data_start = RESERVED + FATS * fat_sz + root_sectors

    img_data = bytearray(TOTAL_SECTORS * SECTOR)

    # Boot sector: write each field at its fixed FAT16 offset so the
    # 11-byte volume label does not shift the file-system type and the
    # 0x55AA signature lands at the sector end (offset 510-511), not at
    # the byte the concatenation happened to reach.
    boot = bytearray(SECTOR)
    boot[0:3] = b"\xEB\x3C\x90"
    boot[3:11] = b"NT64BOOT"
    struct.pack_into("<H", boot, 11, SECTOR)
    struct.pack_into("<B", boot, 13, SECTORS_PER_CLUSTER)
    struct.pack_into("<H", boot, 14, RESERVED)
    struct.pack_into("<B", boot, 16, FATS)
    struct.pack_into("<H", boot, 17, ROOT_ENTRIES)
    struct.pack_into("<H", boot, 19, TOTAL_SECTORS)
    boot[21] = MEDIA
    struct.pack_into("<H", boot, 22, fat_sz)
    struct.pack_into("<H", boot, 24, 63)          # sectors/track
    struct.pack_into("<H", boot, 26, 16)          # heads
    struct.pack_into("<I", boot, 28, 0)           # hidden sectors
    struct.pack_into("<I", boot, 32, 0)           # total32 (0 = CHS)
    boot[36] = 0x80                               # drive number
    boot[37] = 0
    boot[38] = 0x29                               # extended boot sig
    struct.pack_into("<I", boot, 39, 0x12345678)  # volume serial
    boot[43:54] = b"NT64TEST   "                  # volume label (11 bytes)
    boot[54:62] = b"FAT16   "                     # file-system type (8 bytes)
    boot[510] = 0x55
    boot[511] = 0xAA
    img_data[0:SECTOR] = boot

    # FAT: cluster 0/1 reserved, then each allocated cluster = 0xFFFF.
    fat = bytearray(fat_sz * SECTOR)
    fat[0] = 0xF8
    fat[1] = 0xFF
    fat[2] = 0xFF
    fat[3] = 0xFF

    def set_fat(cluster, value):
        struct.pack_into("<H", fat, cluster * 2, value)

    def cluster_off(cluster):
        return (data_start + (cluster - 2) * SECTORS_PER_CLUSTER) * SECTOR

    # Allocate: BOOTX64.EFI, STARTUP.NSH, then the two directories.
    cluster = 2
    nfile = (len(app_data) + SECTOR - 1) // SECTOR
    fcl = cluster
    img_data[cluster_off(fcl):cluster_off(fcl) + len(app_data)] = app_data
    for i in range(nfile):
        set_fat(fcl + i, fcl + i + 1 if i + 1 < nfile else 0xFFFF)
    cluster += nfile

    nsh_data = b"FS0:\\EFI\\BOOT\\BOOTX64.EFI\r\n"
    nnsh = (len(nsh_data) + SECTOR - 1) // SECTOR
    nsh_cl = cluster
    img_data[cluster_off(nsh_cl):cluster_off(nsh_cl) + len(nsh_data)] = nsh_data
    for i in range(nnsh):
        set_fat(nsh_cl + i, nsh_cl + i + 1 if i + 1 < nnsh else 0xFFFF)
    cluster += nnsh

    efi_cl = cluster
    cluster += 1
    boot_cl = cluster
    efi_dir = (dirent(".", "", 0x10, efi_cl, 0) +
               dirent("..", "", 0x10, 0, 0) +
               dirent("BOOT", "", 0x10, boot_cl, 0)).ljust(SECTOR, b"\x00")
    img_data[cluster_off(efi_cl):cluster_off(efi_cl) + SECTOR] = efi_dir
    set_fat(efi_cl, 0xFFFF)
    boot_dir = (dirent(".", "", 0x10, boot_cl, 0) +
                dirent("..", "", 0x10, efi_cl, 0) +
                dirent("BOOTX64", "EFI", 0x20, fcl, len(app_data))
                ).ljust(SECTOR, b"\x00")
    img_data[cluster_off(boot_cl):cluster_off(boot_cl) + SECTOR] = boot_dir
    set_fat(boot_cl, 0xFFFF)

    # Root directory: EFI entry + STARTUP.NSH.
    root_off = (RESERVED + FATS * fat_sz) * SECTOR
    img_data[root_off:root_off + SECTOR] = \
        dirent("EFI", "", 0x10, efi_cl, 0).ljust(SECTOR, b"\x00")
    img_data[root_off + 32:root_off + 64] = \
        dirent("STARTUP", "NSH", 0x20, nsh_cl, len(nsh_data))

    # Write both FAT copies.
    fat_off = RESERVED * SECTOR
    img_data[fat_off:fat_off + len(fat)] = bytes(fat)
    img_data[fat_off + len(fat):fat_off + 2 * len(fat)] = bytes(fat)

    assert len(img_data) == TOTAL_SECTORS * SECTOR, "image resized"
    with open(img, "wb") as f:
        f.write(img_data)
    print(f"fat16 image {img}: app {len(app_data)}B at cluster {fcl}, "
          f"fat_sz={fat_sz} data_start={data_start}")


def main():
    app, img = sys.argv[1], sys.argv[2]
    with open(app, "rb") as f:
        build(img, f.read())


if __name__ == "__main__":
    main()
