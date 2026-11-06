"""Tagged property (FPropertyTag) reader for uncooked packages."""
from __future__ import annotations

from .uasset import (FormatError, Reader, VER_UE4_ARRAY_PROPERTY_INNER_TAGS,
                     VER_UE4_PROPERTY_GUID_IN_PROPERTY_TAG,
                     VER_UE4_STRUCT_GUID_IN_PROPERTY_TAG,
                     VER_UE5_PROPERTY_TAG_COMPLETE_TYPE_NAME,
                     VER_UE5_PROPERTY_TAG_EXTENSION_AND_OVERRIDABLE_SERIALIZATION)


class Ref:
    """An object reference (import < 0, export > 0)."""

    def __init__(self, pkg, index: int):
        self.index = index
        self.name = pkg.object_name(index)
        self.path = pkg.object_path(index)

    def __repr__(self):
        return f"Ref({self.path})"


def read_tagged_properties(pkg, r: Reader, end: int) -> dict:
    props: dict = {}
    while r.pos < end:
        tag = _read_tag(pkg, r)
        if tag is None:
            break
        start = r.pos
        try:
            value = _read_value(pkg, r, tag, tag["type"], tag["size"], top=True)
        except (FormatError, IndexError, UnicodeDecodeError, ValueError) as err:
            value = f"<unreadable {tag['type']}: {err}>"
        r.pos = start + tag["size"]
        key = tag["name"] if tag["array_index"] == 0 else f"{tag['name']}[{tag['array_index']}]"
        props[key] = value
    return props


def _read_tag(pkg, r: Reader) -> dict | None:
    name = pkg.fname(r)
    if name == "None":
        return None
    tag = {"name": name}
    if pkg.ue5_version >= VER_UE5_PROPERTY_TAG_COMPLETE_TYPE_NAME:
        # UE5.4+: a flattened type-name tree replaces the per-type extras.
        nodes = []
        while True:
            nodes.append((pkg.fname(r), r.i32()))
            if sum(n for _, n in nodes) - (len(nodes) - 1) <= 0:
                break
        tag["type"] = nodes[0][0]
        tag["type_tree"] = nodes
        tag["size"] = r.i32()
        flags = r.u8()
        tag["array_index"] = r.i32() if flags & 0x01 else 0
        if flags & 0x02:
            r.guid()
        if flags & 0x04:
            _skip_extensions(r)
        tag["bool"] = bool(flags & 0x10)
        _fill_from_tree(tag, nodes)
        return tag
    tag["type"] = pkg.fname(r)
    tag["size"] = r.i32()
    tag["array_index"] = r.i32()
    t = tag["type"]
    if t == "StructProperty":
        tag["struct"] = pkg.fname(r)
        if pkg.ue4_version >= VER_UE4_STRUCT_GUID_IN_PROPERTY_TAG:
            r.guid()
    elif t == "BoolProperty":
        tag["bool"] = r.u8() != 0
    elif t in ("ByteProperty", "EnumProperty"):
        tag["enum"] = pkg.fname(r)
    elif t in ("ArrayProperty", "SetProperty"):
        if pkg.ue4_version >= VER_UE4_ARRAY_PROPERTY_INNER_TAGS:
            tag["inner"] = pkg.fname(r)
    elif t == "MapProperty":
        tag["inner"] = pkg.fname(r)
        tag["value_type"] = pkg.fname(r)
    if pkg.ue4_version >= VER_UE4_PROPERTY_GUID_IN_PROPERTY_TAG:
        if r.u8():
            r.guid()
    if pkg.ue5_version >= VER_UE5_PROPERTY_TAG_EXTENSION_AND_OVERRIDABLE_SERIALIZATION:
        _skip_extensions(r)
    return tag


def _skip_extensions(r: Reader):
    flags = r.u8()
    if flags & 0x02:  # OverridableInformation
        r.u8()


def _tree(nodes: list, i: int = 0):
    """Flattened FPropertyTypeName -> (name, [children]), next index."""
    name, count = nodes[i]
    i += 1
    children = []
    for _ in range(count):
        child, i = _tree(nodes, i)
        children.append(child)
    return (name, children), i


def _fill_from_tree(tag: dict, nodes: list):
    (t, params), _ = _tree(nodes)
    first = params[0][0] if params else None
    if t == "StructProperty" and params:
        tag["struct"] = first
    elif t in ("ByteProperty", "EnumProperty") and params:
        tag["enum"] = first
    elif t in ("ArrayProperty", "SetProperty", "OptionalProperty") and params:
        tag["inner"] = first
        if first == "StructProperty" and params[0][1]:
            tag["inner_struct"] = params[0][1][0][0]
    elif t == "MapProperty" and len(params) >= 2:
        tag["inner"], tag["value_type"] = first, params[1][0]
        if first == "StructProperty" and params[0][1]:
            tag["key_struct"] = params[0][1][0][0]
        if params[1][0] == "StructProperty" and params[1][1]:
            tag["value_struct"] = params[1][1][0][0]


SIMPLE = {
    "IntProperty": "i32", "Int32Property": "i32", "UInt32Property": "u32", "Int8Property": "i8",
    "Int16Property": "i16", "UInt16Property": "u16", "Int64Property": "i64", "UInt64Property": "u64",
    "FloatProperty": "f32", "DoubleProperty": "f64",
}


def _read_value(pkg, r: Reader, tag: dict, t: str, size: int, top: bool = False):
    if t in SIMPLE:
        return getattr(r, SIMPLE[t])()
    if t == "BoolProperty":
        return tag.get("bool", False) if top else r.u8() != 0
    if t in ("NameProperty",):
        return pkg.fname(r)
    if t in ("StrProperty",):
        return r.fstring()
    if t in ("ObjectProperty", "ClassProperty", "WeakObjectProperty", "LazyObjectProperty", "InterfaceProperty"):
        idx = r.i32()
        return Ref(pkg, idx) if idx else None
    if t in ("SoftObjectProperty", "SoftClassProperty"):
        path = pkg.fname(r)
        sub = r.fstring()
        return f"{path}:{sub}" if sub else path
    if t == "ByteProperty":
        if tag.get("enum", "None") != "None" and (size == 8 or not top):
            return pkg.fname(r)
        return r.u8() if size == 1 else pkg.fname(r)
    if t == "EnumProperty":
        return pkg.fname(r)
    if t == "TextProperty":
        return _read_text(pkg, r)
    if t == "StructProperty":
        return _read_struct(pkg, r, tag.get("struct", ""), size)
    if t in ("ArrayProperty", "SetProperty"):
        if t == "SetProperty":
            r.i32()  # elements to remove
        count = r.i32()
        inner = tag.get("inner", "")
        if inner == "StructProperty":
            # Arrays of structs carry one inner tag describing the element struct.
            if pkg.ue5_version >= VER_UE5_PROPERTY_TAG_COMPLETE_TYPE_NAME:
                struct = tag.get("inner_struct", "")
            else:
                inner_tag = _read_tag(pkg, r)
                struct = inner_tag.get("struct", "") if inner_tag else ""
            return [_read_struct(pkg, r, struct, -1) for _ in range(count)]
        return [_read_value(pkg, r, {}, inner, -1) for _ in range(count)]
    if t == "MapProperty":
        r.i32()  # keys to remove
        count = r.i32()
        out = []
        for _ in range(count):
            k = _read_value(pkg, r, {"struct": tag.get("key_struct", "")}, tag.get("inner", ""), -1)
            v = _read_value(pkg, r, {"struct": tag.get("value_struct", "")}, tag.get("value_type", ""), -1)
            out.append((k, v))
        return out
    raise FormatError(f"unsupported property type {t}")


def _read_text(pkg, r: Reader):
    r.u32()  # flags
    history = r.i8()
    if history == -1:  # None
        if r.bool32():
            return r.fstring()
        return ""
    if history == 0:  # Base
        r.fstring()  # namespace
        r.fstring()  # key
        return r.fstring()
    raise FormatError(f"text history {history}")


# Structs with native (non-tagged) binary layouts.
NATIVE_STRUCTS = {
    "Vector": "fff", "Vector2D": "ff", "Vector4": "ffff", "Rotator": "fff", "Quat": "ffff",
    "LinearColor": "ffff", "IntPoint": "ii", "IntVector": "iii",
}


def _read_struct(pkg, r: Reader, struct: str, size: int):
    large = pkg.ue5_version >= 1004  # LARGE_WORLD_COORDINATES: doubles in UE5
    if struct in NATIVE_STRUCTS:
        fmt = NATIVE_STRUCTS[struct]
        if large and struct in ("Vector", "Vector2D", "Vector4", "Rotator", "Quat"):
            return tuple(r.f64() for _ in fmt)
        return tuple(getattr(r, {"f": "f32", "i": "i32"}[c])() for c in fmt)
    if struct == "Color":
        b, g, rr, a = r.u8(), r.u8(), r.u8(), r.u8()
        return (rr, g, b, a)
    if struct == "Guid":
        return r.guid()
    if struct in ("Box",):
        v = [r.f64() if large else r.f32() for _ in range(6)]
        r.u8()
        return v
    if struct == "SoftObjectPath":
        return f"{pkg.fname(r)}:{r.fstring()}"
    if struct == "DateTime":
        return r.i64()
    if struct in ("PerPlatformFloat",):
        r.bool32()
        return r.f32()
    if struct in ("PerPlatformInt",):
        r.bool32()
        return r.i32()
    if struct in ("PerPlatformBool",):
        r.bool32()
        return r.u8() != 0
    if struct == "FrameNumber":
        return r.i32()
    if struct in MATERIAL_INPUTS:
        return _read_material_input(pkg, r, struct, size)
    # Everything else is a nested tagged property list.
    end = r.pos + size if size >= 0 else len(r.data)
    return read_tagged_properties(pkg, r, end)


# Material pins (FExpressionInput and FMaterialInput<T>) use native serialization.
MATERIAL_INPUTS = {
    "ExpressionInput": None, "ColorMaterialInput": "color", "ScalarMaterialInput": "f",
    "VectorMaterialInput": "fff", "Vector2MaterialInput": "ff", "MaterialAttributesInput": "attr",
    "ShadingModelMaterialInput": "u32", "StrataMaterialInput": None,
}


def _read_material_input(pkg, r: Reader, struct: str, size: int) -> dict:
    start = r.pos
    idx = r.i32()
    out = {"expression": Ref(pkg, idx) if idx else None, "output": r.i32()}
    out["input_name"] = pkg.fname(r)
    out["mask"] = (r.i32(), r.i32(), r.i32(), r.i32(), r.i32())
    # Editor builds also store the expression name.
    if size >= 0 and r.pos - start + 8 <= size and struct == "ExpressionInput":
        out["expression_name"] = pkg.fname(r)
    kind = MATERIAL_INPUTS[struct]
    if kind == "color":
        if size >= 0 and size - (r.pos - start) >= 16:
            out["expression_name"] = pkg.fname(r)
        out["use_constant"] = r.bool32()
        b, g, rr, a = r.u8(), r.u8(), r.u8(), r.u8()
        out["constant"] = (rr / 255, g / 255, b / 255, a / 255)
    elif kind in ("f", "fff", "ff"):
        if size >= 0 and size - (r.pos - start) >= 8 + 4 * len(kind) + 4:
            out["expression_name"] = pkg.fname(r)
        out["use_constant"] = r.bool32()
        out["constant"] = tuple(r.f32() for _ in kind)
    elif kind == "u32":
        out["use_constant"] = r.bool32()
        out["constant"] = r.u32()
    return out
