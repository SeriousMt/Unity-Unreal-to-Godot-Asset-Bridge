"""Bulk data (FUntypedBulkData) reading for uncooked UE4 packages."""
from __future__ import annotations

import os
import zlib

from .uasset import FormatError, Reader

BULKDATA_PayloadAtEndOfFile = 0x0001
BULKDATA_SerializeCompressedZLIB = 0x0002
BULKDATA_Unused = 0x0020
BULKDATA_PayloadInSeperateFile = 0x0100
BULKDATA_Size64Bit = 0x2000
BULKDATA_NoOffsetFixUp = 0x10000
PACKAGE_TAG = 0x9E2A83C1


def read_bulk(pkg, r: Reader) -> bytes:
    """Reads a bulk data header at r and returns the (decompressed) payload."""
    flags = r.u32()
    count = r.i64() if flags & BULKDATA_Size64Bit else r.i32()
    if count == 0 and flags & ~BULKDATA_Unused == 0:
        return b""  # empty bulk data stores only flags and count
    size = r.i64() if flags & BULKDATA_Size64Bit else r.i32()
    offset = r.i64()
    if flags & BULKDATA_Unused or size <= 0:
        return b""
    if flags & BULKDATA_PayloadInSeperateFile:
        ubulk = os.path.splitext(pkg.path)[0] + ".ubulk"
        with open(ubulk, "rb") as f:
            f.seek(offset)
            raw = f.read(size)
    elif flags & BULKDATA_PayloadAtEndOfFile:
        if not flags & BULKDATA_NoOffsetFixUp:
            offset += pkg.bulk_data_start
        raw = pkg.data[offset:offset + size]
    else:
        raw = r.read(size)
    if flags & BULKDATA_SerializeCompressedZLIB:
        raw = decompress_chunks(raw)
    return raw


def decompress_chunks(data: bytes) -> bytes:
    """FArchive::SerializeCompressed format: tag, block size, summary, block table, blocks."""
    r = Reader(data)
    tag = r.i64()
    if tag & 0xFFFFFFFF != PACKAGE_TAG:
        raise FormatError("compressed bulk data has no package tag")
    block_size = r.i64()
    _summary_compressed = r.i64()
    total = r.i64()
    n = (total + block_size - 1) // block_size
    blocks = [(r.i64(), r.i64()) for _ in range(n)]
    out = bytearray()
    for comp, _uncomp in blocks:
        out += zlib.decompress(r.read(comp))
    return bytes(out)
