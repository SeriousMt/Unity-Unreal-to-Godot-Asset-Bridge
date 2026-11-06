#!/usr/bin/env python3
"""Unit tests for the Unreal converter's format code, using synthetic data
(real Fab packages can't be committed). Run: python3 tests/test_uasset.py"""
import array
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "addons", "asset_bridge", "unreal"))

from uasset import trailer  # noqa: E402
from uasset.convert import _packed_layout  # noqa: E402
from uasset.properties import _fill_from_tree  # noqa: E402


def ue_delta_encode(img: bytes, row: int, bpp: int, channel_bytes: int) -> bytes:
    """Encoder matching the decoder rules (strips of 8*bpp rows)."""
    out = bytearray(img)
    rows = len(img) // row
    for y in range(rows - 1, 0, -1):
        if y % (8 * bpp) == 0:
            continue
        if channel_bytes == 2:
            cur = array.array("H", img[y * row:(y + 1) * row])
            up = array.array("H", img[(y - 1) * row:y * row])
            out[y * row:(y + 1) * row] = array.array("H", ((c - u + 0x8080) & 0xFFFF for c, u in zip(cur, up))).tobytes()
        else:
            out[y * row:(y + 1) * row] = bytes((c - u) & 255 for c, u in zip(img[y * row:(y + 1) * row], img[(y - 1) * row:y * row]))
    return bytes(out)


def stored_buffer(raw: bytes) -> bytes:
    header = struct.pack(">IIBBBBIQQ", 0xB7756362, 0, 0, 0, 0, 0, 0, len(raw), len(raw) + 64) + b"\0" * 32
    return header + raw


class UEDeltaTest(unittest.TestCase):
    def roundtrip(self, w, h, bpp, channel_bytes, use_helper):
        import random
        rnd = random.Random(w * bpp)
        img = bytes(rnd.randrange(256) for _ in range(w * h * bpp))
        enc = ue_delta_encode(img, w * bpp, bpp, channel_bytes)
        if not use_helper:
            os.environ["ASSET_BRIDGE_OOZ"] = "/nonexistent"
            saved = trailer.ooz_helper
            trailer.ooz_helper = lambda: None
            try:
                dec = trailer.decompress_buffer(stored_buffer(enc), (w * bpp, bpp, channel_bytes))
            finally:
                trailer.ooz_helper = saved
        else:
            if not trailer.ooz_helper():
                self.skipTest("ab-ooz not built")
            dec = trailer.decompress_buffer(stored_buffer(enc), (w * bpp, bpp, channel_bytes))
        self.assertEqual(dec, img)

    def test_bgra8_python(self):
        self.roundtrip(16, 70, 4, 1, False)

    def test_g16_python(self):
        self.roundtrip(16, 40, 2, 2, False)

    def test_rgba16_helper(self):
        self.roundtrip(32, 140, 8, 2, True)

    def test_g8_helper(self):
        self.roundtrip(64, 30, 1, 1, True)


class NamesTest(unittest.TestCase):
    def test_packed_layouts(self):
        self.assertEqual(_packed_layout("T_Wall_RHAOM")["metallic"], "a")
        self.assertEqual(_packed_layout("ORMH A")["roughness"], "g")
        self.assertIsNone(_packed_layout("T_Wall_BaseColor"))

    def test_ue5_map_type_tree(self):
        tag = {"type": "MapProperty"}
        nodes = [("MapProperty", 2), ("IntProperty", 0), ("StructProperty", 1), ("MeshSectionInfo", 1), ("/Script/Engine", 0)]
        _fill_from_tree(tag, nodes)
        self.assertEqual((tag["inner"], tag["value_type"], tag["value_struct"]), ("IntProperty", "StructProperty", "MeshSectionInfo"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
