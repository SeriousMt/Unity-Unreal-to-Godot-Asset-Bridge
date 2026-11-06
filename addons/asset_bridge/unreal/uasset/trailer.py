"""UE5 package trailer (virtualized editor bulk data) and FCompressedBuffer.

Uncooked UE5 packages store texture sources and mesh descriptions in a trailer
at the end of the file. Each payload is an FCompressedBuffer, usually
compressed with Oodle Kraken; those are handed to the optional `ab-ooz`
helper (tools/ooz-helper), everything else is decoded here.
"""
from __future__ import annotations

import array
import os
import shutil
import struct
import subprocess
import tempfile

from .uasset import FormatError

TRAILER_TAG = 0xD1C43B2E80A5F697
BUFFER_MAGIC = 0xB7756362
HEADER_SIZE = 64


class Trailer:
    def __init__(self, data: bytes):
        self.data = data
        self.entries: dict[bytes, tuple[int, int, int]] = {}  # hash -> (abs offset, compressed, raw)
        start = data.find(struct.pack("<Q", TRAILER_TAG))
        if start < 0:
            return
        _tag, _version, header_len, _payloads_len, count = struct.unpack_from("<QiIQi", data, start)
        entry_size = (header_len - 28) // count if count else 0
        payload_base = start + header_len
        pos = start + 28
        for _ in range(count):
            ident = data[pos:pos + 20]
            offset, comp, raw = struct.unpack_from("<qQQ", data, pos + 20)
            if offset >= 0:
                self.entries[ident] = (payload_base + offset, comp, raw)
            pos += entry_size

    def find_in(self, blob: bytes) -> bytes | None:
        """Payload whose identifier hash appears in an export's serialized data."""
        for ident in self.entries:
            if ident in blob:
                return ident
        return None

    def payload(self, ident: bytes, undelta: tuple | None = None) -> bytes:
        offset, comp, _raw = self.entries[ident]
        return decompress_buffer(self.data[offset:offset + comp], undelta)


def ooz_helper() -> str | None:
    env = os.environ.get("ASSET_BRIDGE_OOZ")
    if env and os.path.isfile(env):
        return env
    local = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "ab-ooz")
    if os.path.isfile(local):
        return local
    return shutil.which("ab-ooz")


class OodleUnavailable(FormatError):
    pass


def _undelta(data: bytes, spec: tuple) -> bytes:
    """TSCF_UEDELTA (see tools/ooz-helper/main.cpp): strips of 8*bpp rows, first
    row of each strip raw, the rest stored as differences to the row above."""
    row, bpp, channel_bytes = spec
    strip = 8 * bpp
    out = bytearray(data)
    for i, y in enumerate(range(0, len(out) - row + 1, row)):
        if not i % strip:
            continue
        if channel_bytes == 2:
            cur = array.array("H", bytes(out[y:y + row]))
            up = array.array("H", bytes(out[y - row:y]))
            out[y:y + row] = array.array("H", ((a + b - 0x8080) & 0xFFFF for a, b in zip(cur, up))).tobytes()
        else:
            out[y:y + row] = bytes((a + b) & 255 for a, b in zip(out[y:y + row], out[y - row:y]))
    return bytes(out)


def decompress_buffer(buf: bytes, undelta: tuple | None = None) -> bytes:
    """Decodes an FCompressedBuffer; [undelta] reverses TSCF_UEDELTA row deltas."""
    if len(buf) < HEADER_SIZE or struct.unpack_from(">I", buf, 0)[0] != BUFFER_MAGIC:
        raise FormatError("payload is not an FCompressedBuffer")
    method = buf[8]
    raw_size = struct.unpack_from(">Q", buf, 16)[0]
    helper = ooz_helper()
    if method == 0 and not helper:
        raw = buf[HEADER_SIZE:HEADER_SIZE + raw_size]
        return _undelta(raw, undelta) if undelta else raw
    if method not in (0, 3):
        raise FormatError(f"FCompressedBuffer method {method} not supported")
    if not helper:
        raise OodleUnavailable("Oodle-compressed UE5 data needs the ab-ooz helper (tools/ooz-helper/build.sh)")
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "in.ucb"), os.path.join(tmp, "out.bin")
        with open(src, "wb") as f:
            f.write(buf)
        args = [helper] + (["--undelta"] + [str(v) for v in undelta] if undelta else []) + [src, dst]
        r = subprocess.run(args, capture_output=True, text=True)
        if r.returncode != 0:
            raise FormatError("ab-ooz: " + (r.stderr.strip() or "failed"))
        with open(dst, "rb") as f:
            out = f.read()
    if len(out) != raw_size:
        raise FormatError("decompressed size mismatch")
    return out
