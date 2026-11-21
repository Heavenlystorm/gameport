#!/usr/bin/env python3
"""Marks PE DLLs as Wine builtins, like `winebuild --builtin`: writes "Wine builtin DLL" at offset 0x40.
Wine only loads DLLs from WINEDLLPATH overlay folders when they carry this marker; without it
it silently falls back to its own builtin. The bytes replace the unused DOS stub.
Usage: python3 Scripts/mark-wine-builtin.py <dll>..."""
import struct, sys

MARK = b"Wine builtin DLL".ljust(32, b"\0")

for path in sys.argv[1:]:
    with open(path, "r+b") as f:
        head = bytearray(f.read(0x60))
        if head[:2] != b"MZ":
            sys.exit(f"{path}: not a PE file")
        (pe_offset,) = struct.unpack_from("<I", head, 0x3C)
        if pe_offset < 0x60:
            sys.exit(f"{path}: PE header at {pe_offset:#x} overlaps the marker")
        if head[0x40:0x60] != MARK:
            f.seek(0x40)
            f.write(MARK)
        print(f"  builtin: {path}")
