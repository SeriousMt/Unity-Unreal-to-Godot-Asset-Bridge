"""Decoder for FMeshDescription as stored in uncooked UE4.26/4.27 static meshes
(FStaticMeshSourceModel::MeshDescriptionBulkData).

Layout (derived from real Marketplace assets):
  element arrays, each a bit array of allocated slots followed by per-element data:
    vertices          (no data)
    vertex instances  int32 VertexID
    edges             int32 VertexID[2]
    polygons          int32 (unused) + int32 PolygonGroupID
    polygon groups    (no data)
  attribute sets for vertices, vertex instances, edges, polygons, polygon groups:
    int32 NumElements, int32 NumAttributes, then per attribute:
      FString name, int32 type index, int32 NumElements, int32 NumIndices,
      per index: int32 element size, int32 count, raw elements,
      default value, uint32 flags
  triangles (bit array + VertexInstanceID[3] + PolygonID) and their attribute set.
"""
from __future__ import annotations

import struct

from .uasset import FormatError, Reader

# Attribute type index -> (struct format, component count) for UE 4.26 TAttributeTypes.
ATTR_TYPES = {0: ("4f", 16), 1: ("3f", 12), 2: ("2f", 8), 3: ("f", 4), 4: ("i", 4), 5: ("?", 1), 6: ("name", 0)}


class MeshDescription:
    def __init__(self):
        self.vertex_ids: list[int] = []          # per vertex instance
        self.edges: list[tuple[int, int]] = []
        self.polygon_groups_of_polygon: list[int] = []
        self.triangles: list[tuple[int, int, int, int]] = []  # 3 instances + polygon
        self.attributes: dict[str, dict[str, list]] = {}       # element kind -> name -> channels
        self.counts: dict[str, int] = {}


def _bits(r: Reader) -> list[int]:
    n = r.i32()
    words = r.read(((n + 31) // 32) * 4)
    out = []
    for i in range(n):
        if words[i >> 3] >> (i & 7) & 1:
            out.append(i)
    return out


def _attribute_set(r: Reader, kind: str, md: MeshDescription):
    r.i32()  # NumElements
    attrs = {}
    for _ in range(r.i32()):
        name = r.fstring().strip()  # UE names its position attribute "Position "
        type_index = r.i32()
        r.i32()  # NumElements
        channels = []
        for _ in range(r.i32()):
            if type_index == 6:
                count = r.i32()
                channels.append([_fname(r) for _ in range(count)])
                continue
            fmt, size = ATTR_TYPES.get(type_index, (None, 0))
            elem_size, count = r.i32(), r.i32()
            raw = r.read(elem_size * count)
            if fmt is None or elem_size != size:
                channels.append(None)
            else:
                channels.append(list(struct.iter_unpack("<" + fmt, raw)))
        if type_index == 6:
            _fname(r)
        elif type_index == 5:
            r.u32()  # bool default is serialized as 32 bits
        else:
            r.read(ATTR_TYPES.get(type_index, ("", 0))[1])  # default value
        r.u32()  # flags
        attrs[name] = channels
    md.attributes[kind] = attrs


def _fname(r: Reader) -> str:
    # FNames inside the memory archive are written as plain strings.
    return r.fstring()


def parse(blob: bytes) -> MeshDescription:
    r = Reader(blob)
    md = MeshDescription()
    verts = _bits(r)
    md.counts["vertices"] = len(verts)
    inst = _bits(r)
    md.vertex_ids = [r.i32() for _ in inst]
    edges = _bits(r)
    md.edges = [(r.i32(), r.i32()) for _ in edges]
    polys = _bits(r)
    for _ in polys:
        r.i32()  # unused in uncooked data
        md.polygon_groups_of_polygon.append(r.i32())
    groups = _bits(r)
    md.counts.update(vertex_instances=len(inst), edges=len(edges), polygons=len(polys), polygon_groups=len(groups))
    for kind in ("vertex", "vertex_instance", "edge", "polygon", "polygon_group"):
        _attribute_set(r, kind, md)
    if r.pos < len(blob):
        tris = _bits(r)
        for _ in tris:
            a, b, c, p = r.i32(), r.i32(), r.i32(), r.i32()
            md.triangles.append((a, b, c, p))
        md.counts["triangles"] = len(tris)
        if r.pos < len(blob):
            _attribute_set(r, "triangle", md)
    if not md.triangles:
        raise FormatError("mesh description has no triangles")
    return md


# --- UE5 ----------------------------------------------------------------------
# UE5 serializes the mesh description as named element types, each with one or
# more channels; a channel is an allocation bit array plus an attribute set.
# Attributes carry an "extent" (values per element, e.g. 3 instance indices per
# triangle):
#   int32 NumElementTypes
#   per type: FString name, int32 NumChannels,
#     per channel: bit array, int32 0, int32 NumElements, int32 NumAttributes,
#       per attribute: FString name, int32 type, int32 extent, int32 NumElements,
#         int32 NumIndices, per index: int32 extent, [int32 elem size], int32 count, data
#         then default value and uint32 flags.

def _attribute_set_ue5(r: Reader) -> dict:
    r.i32()
    r.i32()  # NumElements
    attrs = {}
    for _ in range(r.i32()):
        name = r.fstring().strip()
        type_index = r.i32()
        extent = r.i32()
        r.i32()  # NumElements
        channels = []
        for _ in range(r.i32()):
            r.i32()  # extent (repeated)
            if type_index == 6:
                count = r.i32()
                channels.append([_fname(r) for _ in range(count)])
                continue
            fmt, size = ATTR_TYPES.get(type_index, (None, 0))
            elem_size, count = r.i32(), r.i32()
            raw = r.read(elem_size * count)
            if fmt is None or elem_size != size:
                channels.append(None)
                continue
            values = list(struct.iter_unpack("<" + fmt, raw))
            if extent > 1:
                values = [tuple(v[0] for v in values[i:i + extent]) for i in range(0, len(values), extent)]
            channels.append(values)
        if type_index == 6:
            _fname(r)
        elif type_index == 5:
            r.u32()
        else:
            r.read(ATTR_TYPES.get(type_index, ("", 0))[1])
        r.u32()  # flags
        attrs[name] = channels
    return attrs


def parse_ue5(blob: bytes) -> MeshDescription:
    r = Reader(blob)
    md = MeshDescription()
    types: dict[str, list[dict]] = {}
    for _ in range(r.i32()):
        name = r.fstring()
        chans = []
        for _ in range(r.i32()):
            allocated = _bits(r)
            attrs = _attribute_set_ue5(r)
            attrs["__count"] = len(allocated)
            chans.append(attrs)
        types[name] = chans

    def attr(type_name: str, attr_name: str, channel: int = 0):
        ch = types.get(type_name) or [{}]
        a = ch[0].get(attr_name) if ch else None
        return a[channel] if a and len(a) > channel else None

    md.attributes["vertex"] = {"Position": [attr("Vertices", "Position")]}
    vi = (types.get("VertexInstances") or [{}])[0]
    md.attributes["vertex_instance"] = {k: v for k, v in vi.items() if not k.startswith("__") and k != "VertexIndex"}
    md.vertex_ids = [v[0] for v in (attr("VertexInstances", "VertexIndex") or [])]
    md.edges = [tuple(e) for e in (attr("Edges", "VertexIndex") or [])]
    tri_inst = attr("Triangles", "VertexInstanceIndex") or []
    tri_poly = attr("Triangles", "PolygonIndex") or [(i,) for i in range(len(tri_inst))]
    tri_group = attr("Triangles", "PolygonGroupIndex")
    md.triangles = [(t[0], t[1], t[2], i) for i, t in enumerate(tri_inst)]
    # Map "polygon" -> group per triangle so the UE4 code path works unchanged.
    if tri_group:
        md.polygon_groups_of_polygon = [g[0] for g in tri_group]
    else:
        pg = attr("Polygons", "PolygonGroupIndex") or []
        md.polygon_groups_of_polygon = [pg[p[0]][0] if p[0] < len(pg) else 0 for p in tri_poly]
    md.attributes["polygon_group"] = {"ImportedMaterialSlotName": [attr("PolygonGroups", "ImportedMaterialSlotName") or []]}
    md.counts = {k: (v[0].get("__count", 0) if v else 0) for k, v in types.items()}
    if not md.triangles:
        raise FormatError("mesh description has no triangles")
    return md
