#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""pewrap.py - wrap a flat 64-bit code blob into a minimal PE32+
EFI_APPLICATION image (BOOTX64.EFI).  The blob is linked at RVA
0x1000 and is fully position-independent (RIP-relative), so a single
RWX .text section suffices."""

import struct
import sys

SECTION_ALIGN = 0x1000
FILE_ALIGN = 0x200
ENTRY_RVA = 0x1000


def align(v, a):
    return (v + a - 1) & ~(a - 1)


def build(code):
    headers_size = align(0x200, FILE_ALIGN)
    size_of_image = (align(headers_size, SECTION_ALIGN) +
                     align(len(code), SECTION_ALIGN))

    pe = bytearray()
    pe += b"MZ" + b"\x00" * 0x3a + struct.pack("<I", 0x80)
    pe += b"\x00" * (0x80 - len(pe))
    pe += b"PE\x00\x00"

    # COFF header
    pe += struct.pack("<HHIIIHH",
                      0x8664,          # machine: x86-64
                      1,               # one section
                      0,               # timestamp
                      0,               # symbol table
                      0,               # symbols
                      0xF0,            # size of optional header
                      0x2022)          # executable | large-address | dll

    # PE32+ optional header
    opt = struct.pack("<H", 0x20B)              # magic: PE32+
    opt += struct.pack("<BB", 0, 0)             # linker version
    opt += struct.pack("<I", align(len(code), SECTION_ALIGN))
    opt += struct.pack("<I", 0)                 # initialized data
    opt += struct.pack("<I", 0)                 # uninitialized data
    opt += struct.pack("<I", ENTRY_RVA)         # entry point
    opt += struct.pack("<I", 0x1000)            # base of code
    opt += struct.pack("<Q", 0x40000000)        # image base (relocatable)
    opt += struct.pack("<I", SECTION_ALIGN)
    opt += struct.pack("<I", FILE_ALIGN)
    opt += struct.pack("<HHHHHH", 0, 0, 0, 0, 0, 0)  # versions
    opt += struct.pack("<I", 0)                 # win32 version
    opt += struct.pack("<I", size_of_image)
    opt += struct.pack("<I", headers_size)
    opt += struct.pack("<I", 0)                 # checksum
    opt += struct.pack("<HH", 10, 0)            # EFI_APPLICATION, dll chars
    opt += struct.pack("<QQQQ", 0x10000, 0x10000, 0x10000, 0x10000)
    opt += struct.pack("<II", 0, 16)            # loader flags, rva count
    opt += b"\x00" * (16 * 8)          # data directories
    assert len(opt) == 0xF0
    pe += opt

    # section table: one RWX .text
    pe += b".text".ljust(8, b"\x00")
    pe += struct.pack("<IIIIIIHHI",
                      align(len(code), SECTION_ALIGN),  # virtual size
                      0x1000,                            # virtual address
                      align(len(code), FILE_ALIGN),      # raw size
                      headers_size,                      # raw pointer
                      0, 0, 0,                           # relocs/line nums
                      0,
                      0xE0000020)                        # code|exec|read|write

    pe += b"\x00" * (headers_size - len(pe))
    pe += code
    pe += b"\x00" * (align(len(pe), FILE_ALIGN) - len(pe))
    return bytes(pe)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        data = f.read()
    if data[:2] == b"MZ" and data[data.find(b"PE\x00\x00"):][:4] == b"PE\x00\x00":
        # Already a PE (e.g. objcopy's pei-x86-64 output): force the
        # subsystem to EFI_APPLICATION and write it out.
        pe = bytearray(data)
        o = struct.unpack_from("<I", pe, 0x3C)[0] + 24
        struct.pack_into("<H", pe, o + 68, 10)
        with open(dst, "wb") as f:
            f.write(pe)
        print(f"patched subsystem of {src} -> {dst}")
    else:
        with open(dst, "wb") as f:
            f.write(build(data))
        print(f"wrapped {src} ({len(data)} bytes) -> {dst}")


if __name__ == "__main__":
    main()
