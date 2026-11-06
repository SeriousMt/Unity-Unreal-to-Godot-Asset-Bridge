"""Minimal reader for *uncooked* Unreal Engine packages (.uasset/.umap), as
shipped on Fab/Marketplace. Standard library only.

Prototype: reads the package summary, name/import/export tables and tagged
properties. Asset-specific payloads (textures, meshes) live in sibling modules.
"""
from __future__ import annotations

import struct
import uuid
from dataclasses import dataclass, field

PACKAGE_TAG = 0x9E2A83C1

# UE4 object versions we branch on (EUnrealEngineObjectUE4Version)
VER_UE4_NAME_HASHES_SERIALIZED = 504
VER_UE4_64BIT_EXPORTMAP_SERIALSIZES = 511
VER_UE4_TEMPLATEINDEX_IN_COOKED_EXPORTS = 508
VER_UE4_PRELOAD_DEPENDENCIES_IN_COOKED_EXPORTS = 507
VER_UE4_NON_OUTER_PACKAGE_IMPORT = 520
VER_UE4_ADDED_PACKAGE_OWNER = 518
VER_UE4_ADDED_SEARCHABLE_NAMES = 510
VER_UE4_SERIALIZE_TEXT_IN_PACKAGES = 459
VER_UE4_ADDED_PACKAGE_SUMMARY_LOCALIZATION_ID = 516
VER_UE4_ADD_STRING_ASSET_REFERENCES_MAP = 384
VER_UE4_PROPERTY_GUID_IN_PROPERTY_TAG = 503
VER_UE4_LOAD_FOR_EDITOR_GAME = 365
VER_UE4_COOKED_ASSETS_IN_EDITOR_SUPPORT = 485
VER_UE4_ENGINE_VERSION_OBJECT = 336
VER_UE4_PACKAGE_SUMMARY_HAS_COMPATIBLE_ENGINE_VERSION = 444
VER_UE4_WORLD_LEVEL_INFO = 224
VER_UE4_CHANGED_CHUNKID_TO_BE_AN_ARRAY_OF_CHUNKIDS = 326
VER_UE4_STRUCT_GUID_IN_PROPERTY_TAG = 441
VER_UE4_ARRAY_PROPERTY_INNER_TAGS = 500

# UE5 object versions (EUnrealEngineObjectUE5Version)
VER_UE5_NAMES_REFERENCED_FROM_EXPORT_DATA = 1001
VER_UE5_PAYLOAD_TOC = 1002
VER_UE5_OPTIONAL_RESOURCES = 1003
VER_UE5_REMOVE_OBJECT_EXPORT_PACKAGE_GUID = 1005
VER_UE5_TRACK_OBJECT_EXPORT_IS_INHERITED = 1006
VER_UE5_ADD_SOFTOBJECTPATH_LIST = 1008
VER_UE5_DATA_RESOURCES = 1009
VER_UE5_SCRIPT_SERIALIZATION_OFFSET = 1010
VER_UE5_PROPERTY_TAG_EXTENSION_AND_OVERRIDABLE_SERIALIZATION = 1011
VER_UE5_PROPERTY_TAG_COMPLETE_TYPE_NAME = 1012
VER_UE5_METADATA_SERIALIZATION_OFFSET = 1014
VER_UE5_VERSE_CELLS = 1015
VER_UE5_PACKAGE_SAVED_HASH = 1016

PKG_FILTER_EDITOR_ONLY = 0x80000000


class FormatError(Exception):
    pass


class Reader:
    def __init__(self, data: bytes, pos: int = 0):
        self.data = data
        self.pos = pos

    def read(self, n: int) -> bytes:
        if self.pos + n > len(self.data):
            raise FormatError(f"read past end ({self.pos}+{n} > {len(self.data)})")
        b = self.data[self.pos:self.pos + n]
        self.pos += n
        return b

    def _s(self, fmt: str):
        size = struct.calcsize(fmt)
        v = struct.unpack_from("<" + fmt, self.data, self.pos)
        self.pos += size
        return v[0] if len(v) == 1 else v

    def i8(self): return self._s("b")
    def u8(self): return self._s("B")
    def i16(self): return self._s("h")
    def u16(self): return self._s("H")
    def i32(self): return self._s("i")
    def u32(self): return self._s("I")
    def i64(self): return self._s("q")
    def u64(self): return self._s("Q")
    def f32(self): return self._s("f")
    def f64(self): return self._s("d")
    def bool32(self): return self.u32() != 0

    def guid(self) -> str:
        a, b, c, d = struct.unpack_from("<4I", self.data, self.pos)
        self.pos += 16
        return f"{a:08X}{b:08X}{c:08X}{d:08X}"

    def fstring(self) -> str:
        n = self.i32()
        if n == 0:
            return ""
        if n < 0:
            raw = self.read(-n * 2)
            return raw.decode("utf-16-le").rstrip("\0")
        return self.read(n).decode("latin-1").rstrip("\0")

    def array(self, fn):
        return [fn() for _ in range(self.i32())]


@dataclass
class Import:
    class_package: str
    class_name: str
    outer_index: int
    object_name: str


@dataclass
class Export:
    index: int
    class_index: int
    super_index: int
    outer_index: int
    object_name: str
    serial_size: int
    serial_offset: int
    class_name: str = ""
    properties: dict = field(default_factory=dict)
    tail_offset: int = 0  # where native serialization starts, after the tagged properties


class Package:
    def __init__(self, data: bytes, path: str = ""):
        self.data = data
        self.path = path
        self.names: list[str] = []
        self.imports: list[Import] = []
        self.exports: list[Export] = []
        self.custom_versions: dict[str, int] = {}
        self._parse_summary()
        self._parse_tables()

    # --- summary -----------------------------------------------------------
    def _parse_summary(self):
        r = Reader(self.data)
        if r.u32() != PACKAGE_TAG:
            raise FormatError("not an Unreal package (bad magic); cooked/IoStore packages are not supported")
        legacy = r.i32()
        self.legacy_version = legacy
        if legacy < -9:
            raise FormatError(f"unsupported package version {legacy}")
        if legacy != -4:
            r.i32()  # LegacyUE3Version
        self.ue4_version = r.i32()
        self.ue5_version = r.i32() if legacy <= -8 else 0
        self.licensee_version = r.i32()
        if self.ue4_version == 0 and self.ue5_version == 0:
            raise FormatError("unversioned package (cooked); only editor assets are supported")
        if legacy <= -9:
            r.read(20)  # SavedHash
            self.total_header_size = r.i32()
        if legacy <= -2:
            for _ in range(r.i32()):
                key = r.guid()
                self.custom_versions[key] = r.i32()
        if legacy > -9:
            self.total_header_size = r.i32()
        self.folder_name = r.fstring()
        self.package_flags = r.u32()
        self.filter_editor_only = bool(self.package_flags & PKG_FILTER_EDITOR_ONLY)
        self.name_count, self.name_offset = r.i32(), r.i32()
        if self.ue5_version >= VER_UE5_ADD_SOFTOBJECTPATH_LIST:
            r.i32(); r.i32()  # SoftObjectPaths count/offset
        if not self.filter_editor_only and self.ue4_version >= VER_UE4_ADDED_PACKAGE_SUMMARY_LOCALIZATION_ID:
            r.fstring()  # LocalizationId
        if self.ue4_version >= VER_UE4_SERIALIZE_TEXT_IN_PACKAGES:
            r.i32(); r.i32()  # GatherableTextData
        self.export_count, self.export_offset = r.i32(), r.i32()
        self.import_count, self.import_offset = r.i32(), r.i32()
        if self.ue5_version >= VER_UE5_VERSE_CELLS:
            r.i32(); r.i32(); r.i32(); r.i32()  # cell exports/imports
        if self.ue5_version >= VER_UE5_METADATA_SERIALIZATION_OFFSET:
            r.i32()  # MetaDataOffset
        r.i32()  # DependsOffset
        if self.ue4_version >= VER_UE4_ADD_STRING_ASSET_REFERENCES_MAP:
            r.i32(); r.i32()
        if self.ue4_version >= VER_UE4_ADDED_SEARCHABLE_NAMES:
            r.i32()
        r.i32()  # ThumbnailTableOffset
        if self.ue5_version < VER_UE5_PACKAGE_SAVED_HASH:
            r.guid()  # Guid
        if not self.filter_editor_only and self.ue4_version >= VER_UE4_ADDED_PACKAGE_OWNER:
            r.guid()  # PersistentGuid
            if self.ue4_version < VER_UE4_NON_OUTER_PACKAGE_IMPORT:
                r.guid()
        for _ in range(r.i32()):  # Generations
            r.i32(); r.i32()
        if self.ue4_version >= VER_UE4_ENGINE_VERSION_OBJECT:
            self.saved_by = self._engine_version(r)
        else:
            r.i32()
            self.saved_by = "?"
        if self.ue4_version >= VER_UE4_PACKAGE_SUMMARY_HAS_COMPATIBLE_ENGINE_VERSION:
            self._engine_version(r)
        if r.u32() != 0:
            raise FormatError("compressed packages are not supported")
        if r.i32() != 0:
            raise FormatError("compressed chunks are not supported")
        r.u32()  # PackageSource
        r.array(r.fstring)  # AdditionalPackagesToCook
        if legacy > -7:
            r.i32()  # NumTextureAllocations
        r.i32()  # AssetRegistryDataOffset
        self.bulk_data_start = r.i64()

    @staticmethod
    def _engine_version(r: Reader) -> str:
        major, minor, patch = r.u16(), r.u16(), r.u16()
        changelist = r.u32()
        branch = r.fstring()
        return f"{major}.{minor}.{patch}-{changelist}+{branch}"

    # --- tables ------------------------------------------------------------
    def _parse_tables(self):
        r = Reader(self.data, self.name_offset)
        for _ in range(self.name_count):
            self.names.append(r.fstring())
            if self.ue4_version >= VER_UE4_NAME_HASHES_SERIALIZED:
                r.u32()
        r.pos = self.import_offset
        for _ in range(self.import_count):
            cp = self.fname(r)
            cn = self.fname(r)
            outer = r.i32()
            on = self.fname(r)
            if not self.filter_editor_only and self.ue4_version >= VER_UE4_NON_OUTER_PACKAGE_IMPORT:
                self.fname(r)  # PackageName
            if self.ue5_version >= VER_UE5_OPTIONAL_RESOURCES:
                r.i32()  # bImportOptional
            self.imports.append(Import(cp, cn, outer, on))
        r.pos = self.export_offset
        for i in range(self.export_count):
            class_index = r.i32()
            super_index = r.i32()
            if self.ue4_version >= VER_UE4_TEMPLATEINDEX_IN_COOKED_EXPORTS:
                r.i32()
            outer = r.i32()
            name = self.fname(r)
            r.u32()  # ObjectFlags
            if self.ue4_version >= VER_UE4_64BIT_EXPORTMAP_SERIALSIZES:
                size, offset = r.i64(), r.i64()
            else:
                size, offset = r.i32(), r.i32()
            r.i32(); r.i32(); r.i32()  # forced export, not for client/server
            if self.ue5_version < VER_UE5_REMOVE_OBJECT_EXPORT_PACKAGE_GUID:
                r.guid()
            if self.ue5_version >= VER_UE5_TRACK_OBJECT_EXPORT_IS_INHERITED:
                r.i32()
            r.u32()  # PackageFlags
            if self.ue4_version >= VER_UE4_LOAD_FOR_EDITOR_GAME:
                r.i32()
            if self.ue4_version >= VER_UE4_COOKED_ASSETS_IN_EDITOR_SUPPORT:
                r.i32()  # bIsAsset
            if self.ue5_version >= VER_UE5_OPTIONAL_RESOURCES:
                r.i32()  # bGeneratePublicHash
            if self.ue4_version >= VER_UE4_PRELOAD_DEPENDENCIES_IN_COOKED_EXPORTS:
                r.i32(); r.i32(); r.i32(); r.i32(); r.i32()
            if self.ue5_version >= VER_UE5_SCRIPT_SERIALIZATION_OFFSET:
                r.i64(); r.i64()
            self.exports.append(Export(i + 1, class_index, super_index, outer, name, size, offset))
        for e in self.exports:
            e.class_name = self.object_name(e.class_index)

    def fname(self, r: Reader) -> str:
        idx, number = r.i32(), r.i32()
        if idx < 0 or idx >= len(self.names):
            raise FormatError(f"bad name index {idx} at {r.pos - 8}")
        base = self.names[idx]
        return base if number == 0 else f"{base}_{number - 1}"

    def object_name(self, index: int) -> str:
        if index < 0:
            return self.imports[-index - 1].object_name
        if index > 0:
            return self.exports[index - 1].object_name
        return ""

    def object_path(self, index: int) -> str:
        """Full path of an import/export, e.g. /Game/Textures/T_Leaf.T_Leaf."""
        parts = []
        while index != 0:
            if index < 0:
                imp = self.imports[-index - 1]
                parts.append(imp.object_name)
                index = imp.outer_index
            else:
                exp = self.exports[index - 1]
                parts.append(exp.object_name)
                index = exp.outer_index
        parts.reverse()
        if len(parts) >= 2:
            return parts[0] + "." + ".".join(parts[1:])
        return parts[0] if parts else ""

    # --- properties --------------------------------------------------------
    def read_export(self, export: Export) -> Export:
        r = Reader(self.data, export.serial_offset)
        end = export.serial_offset + export.serial_size
        if self.ue5_version >= VER_UE5_PROPERTY_TAG_EXTENSION_AND_OVERRIDABLE_SERIALIZATION:
            # EClassSerializationControlExtension byte before the tagged properties.
            if r.u8() & 0x02:
                r.u8()  # overridden property operation
        export.properties = self.read_properties(r, end)
        export.tail_offset = r.pos
        return export

    def read_properties(self, r: Reader, end: int) -> dict:
        from .properties import read_tagged_properties
        return read_tagged_properties(self, r, end)

    def export_by_class(self, class_name: str) -> list[Export]:
        return [e for e in self.exports if e.class_name == class_name]

    def main_export(self) -> Export | None:
        """The export named like the package file (the asset itself)."""
        stem = self.path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
        for e in self.exports:
            if e.object_name == stem and e.outer_index == 0:
                return e
        return self.exports[0] if self.exports else None


def load(path: str) -> Package:
    with open(path, "rb") as f:
        return Package(f.read(), path)
