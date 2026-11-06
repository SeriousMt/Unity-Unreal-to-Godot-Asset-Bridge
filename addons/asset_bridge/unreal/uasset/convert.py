"""Converts an uncooked Unreal Content folder to glTF meshes, PNG textures and a
material manifest that Asset Bridge turns into Godot materials.

    python3 -m uasset.convert <Content dir> <output dir>

Writes <out>/manifest.json:
  {"textures":  {"/Game/..T": {"file": "Textures/T.png", "normal": bool, "srgb": bool}},
   "materials": {"/Game/..M": {"name", "base_color": {"texture", "channel"} | {"constant"}, ...}},
   "meshes":    {"/Game/..SM": {"file": "Meshes/SM.glb", "slots": [{"name", "material"}]}},
   "skipped":   {"<class>": count}, "errors": [...]}
Standard library only.
"""
from __future__ import annotations

import array
import json
import os
import struct
import sys
import zlib
from collections import Counter

from . import meshdesc
from .bulk import read_bulk
from .properties import Ref
from .trailer import OodleUnavailable, Trailer, decompress_buffer
from .uasset import FormatError, Package, Reader, load

UE_TO_GLTF_SCALE = 0.01  # centimetres -> metres


# --- helpers -----------------------------------------------------------------

def game_path_to_file(content_root: str, game_path: str) -> str | None:
    """/Game/Foo/Bar.Bar -> <Content>/Foo/Bar.uasset"""
    pkg = game_path.split(".", 1)[0]
    if not pkg.startswith("/Game/"):
        return None
    f = os.path.join(content_root, pkg[len("/Game/"):]) + ".uasset"
    return f if os.path.isfile(f) else None


def file_to_game_path(content_root: str, path: str) -> str:
    rel = os.path.relpath(path, content_root).replace(os.sep, "/")
    stem = rel.rsplit(".", 1)[0]
    return f"/Game/{stem}.{stem.rsplit('/', 1)[-1]}"


def write_png(path: str, width: int, height: int, channels: int, pixels: bytes, depth: int = 8):
    color_type = {1: 0, 3: 2, 4: 6}[channels]
    stride = width * channels * (depth // 8)
    raw = b"".join(b"\x00" + pixels[y * stride:(y + 1) * stride] for y in range(height))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, color_type, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 4)))
        f.write(chunk(b"IEND", b""))


# --- textures ----------------------------------------------------------------

BYTES_PER_PIXEL = {"TSF_G8": 1, "TSF_BGRA8": 4, "TSF_BGRE8": 4, "TSF_RGBA16": 8, "TSF_RGBA16F": 8,
                   "TSF_G16": 2, "TSF_RGBA32F": 16, "TSF_R16F": 2, "TSF_R32F": 4}


def _ue5_texture_payload(pkg: Package, export, src: dict) -> bytes:
    trailer = Trailer(pkg.data)
    ident = trailer.find_in(pkg.data[export.tail_offset:export.serial_offset + export.serial_size])
    if ident is None:
        raise FormatError("texture has no source payload in the package trailer")
    offset, comp, _raw = trailer.entries[ident]
    undelta = None
    if src.get("CompressionFormat") == "TSCF_UEDELTA":
        fmt = src.get("Format", "")
        bpp = BYTES_PER_PIXEL.get(fmt, 4)
        channel_bytes = 2 if fmt in ("TSF_G16", "TSF_RGBA16", "TSF_RGBA16F", "TSF_R16F") else 1
        undelta = (src.get("SizeX", 0) * bpp, bpp, channel_bytes)
    return decompress_buffer(pkg.data[offset:offset + comp], undelta)


def convert_texture(pkg: Package, export, out_file: str) -> dict:
    pkg.read_export(export)
    props = export.properties
    src = props.get("Source") or {}
    fmt = src.get("Format", "")
    w, h = src.get("SizeX", 0), src.get("SizeY", 0)
    if pkg.ue5_version > 0:
        data = _ue5_texture_payload(pkg, export, src)
    else:
        r = Reader(pkg.data, export.tail_offset)
        if r.u32():  # UObject GUID
            r.guid()
        r.u8(); r.u8()  # strip flags
        data = read_bulk(pkg, r)
    if not data:
        raise FormatError("texture has no source data (cooked or stripped)")
    compression = src.get("CompressionFormat", "")
    swap_rb = False
    empty_alpha = None  # True when the alpha channel carries no data (all opaque)
    if src.get("bPNGCompressed") or compression == "TSCF_PNG" or data[:8] == b"\x89PNG\r\n\x1a\n":
        with open(out_file, "wb") as f:
            f.write(data)
        # UE stores BGRA8 sources in the PNG without reordering the channels,
        # so red and blue come out swapped (verified against the seller's TGA).
        swap_rb = fmt == "TSF_BGRA8"
    elif compression == "TSCF_JPEG" or data[:2] == b"\xff\xd8":
        out_file = out_file[:-4] + ".jpg"
        with open(out_file, "wb") as f:
            f.write(data)
    elif fmt in ("TSF_BGRA8", "TSF_BGRE8"):
        px = bytearray(data[:w * h * 4])
        alpha = px[3::4]
        empty_alpha = alpha.count(255) == len(alpha)
        px[0::4], px[2::4] = px[2::4], px[0::4]
        write_png(out_file, w, h, 4, bytes(px))
    elif fmt == "TSF_G8":
        write_png(out_file, w, h, 1, data[:w * h])
    elif fmt in ("TSF_RGBA16", "TSF_G16"):
        # 16-bit sources (packed masks, height maps): PNG stores samples big-endian.
        channels = 4 if fmt == "TSF_RGBA16" else 1
        samples = array.array("H", data[:w * h * channels * 2])
        if channels == 4:
            alpha = samples[3::4]
            empty_alpha = alpha.count(0xFFFF) == len(alpha)
        if sys.byteorder == "little":
            samples.byteswap()
        write_png(out_file, w, h, channels, samples.tobytes(), depth=16)
    else:
        raise FormatError(f"texture source format {fmt} not supported yet")
    compression_settings = props.get("CompressionSettings", "")
    return {
        "file": out_file,
        "normal": compression_settings == "TC_Normalmap" or export.object_name.lower().endswith(("_n", "_normal")),
        "srgb": props.get("SRGB", True),
        "size": [w, h],
        "swap_rb": swap_rb,
        "empty_alpha": empty_alpha,
    }


# --- materials ---------------------------------------------------------------

CHANNEL_BY_OUTPUT = {0: "rgb", 1: "r", 2: "g", 3: "b", 4: "a"}
TEXTURE_EXPRESSIONS = ("MaterialExpressionTextureSample", "MaterialExpressionTextureSampleParameter2D",
                       "MaterialExpressionTextureObject", "MaterialExpressionTextureObjectParameter",
                       "MaterialExpressionTextureSampleParameter")


class MaterialAnalyzer:
    """Follows material input pins back to a texture or constant."""

    def __init__(self, content_root: str):
        self.root = content_root
        self.cache: dict[str, dict] = {}

    def analyze(self, game_path: str) -> dict | None:
        if game_path in self.cache:
            return self.cache[game_path]
        self.cache[game_path] = None  # cycle guard
        f = game_path_to_file(self.root, game_path)
        if not f:
            return None
        pkg = load(f)
        main = pkg.main_export()
        pkg.read_export(main)
        if main.class_name == "Material":
            spec = self._material(pkg, main)
        elif main.class_name.startswith("MaterialInstance"):
            spec = self._instance(pkg, main)
        else:
            spec = None
        if spec is not None:
            spec["name"] = main.object_name
            if main.class_name == "Material":
                spec = _validate(spec, self._default_textures(pkg, main))
            spec = _cleanup(spec)
        self.cache[game_path] = spec
        return spec

    def _material(self, pkg: Package, main) -> dict:
        p = main.properties
        for e in pkg.exports:
            if e.outer_index == main.index and e.class_name.startswith("MaterialExpression"):
                try:
                    pkg.read_export(e)
                except FormatError:
                    pass
        spec = {
            "blend": p.get("BlendMode", "BLEND_Opaque"),
            "two_sided": bool(p.get("TwoSided", False)) or "TwoSided" in str(p.get("ShadingModel", "")),
            "shading": p.get("ShadingModel", "MSM_DefaultLit"),
            "opacity_mask_clip": p.get("OpacityMaskClipValue", 0.3333),
        }
        for pin, key in (("BaseColor", "base_color"), ("Normal", "normal"), ("Roughness", "roughness"),
                         ("Metallic", "metallic"), ("AmbientOcclusion", "ao"), ("EmissiveColor", "emissive"),
                         ("OpacityMask", "opacity_mask"), ("Opacity", "opacity")):
            v = self._trace(pkg, p.get(pin))
            if v is not None:
                spec[key] = v
        return spec

    @staticmethod
    def _default_textures(pkg: Package, main) -> dict:
        """Texture parameters/samples of a base material, keyed by parameter (or texture) name."""
        out = {}
        for e in pkg.exports:
            if e.outer_index == main.index and e.class_name in TEXTURE_EXPRESSIONS:
                tex = e.properties.get("Texture")
                if isinstance(tex, Ref):
                    out[e.properties.get("ParameterName") or tex.name] = tex.path
        return out

    def _instance(self, pkg: Package, main) -> dict | None:
        p = main.properties
        parent = p.get("Parent")
        base = self.analyze(parent.path) if isinstance(parent, Ref) else None
        spec = json.loads(json.dumps(base)) if base else {"blend": "BLEND_Opaque", "two_sided": False}
        textures = {}
        for tv in p.get("TextureParameterValues") or []:
            name = (tv.get("ParameterInfo") or {}).get("Name", "")
            val = tv.get("ParameterValue")
            if isinstance(val, Ref):
                textures[name] = val.path
        scalars = {(sv.get("ParameterInfo") or {}).get("Name", ""): sv.get("ParameterValue") for sv in p.get("ScalarParameterValues") or []}
        vectors = {(vv.get("ParameterInfo") or {}).get("Name", ""): vv.get("ParameterValue") for vv in p.get("VectorParameterValues") or []}
        for key, v in list(spec.items()):
            if isinstance(v, dict) and v.get("parameter") in textures:
                v["texture"] = textures[v["parameter"]]
            if isinstance(v, dict) and v.get("parameter") in scalars:
                v["constant"] = scalars[v["parameter"]]
            if isinstance(v, dict) and v.get("parameter") in vectors and isinstance(vectors[v["parameter"]], dict):
                c = vectors[v["parameter"]]
                v["constant"] = [c.get("R", 1), c.get("G", 1), c.get("B", 1), c.get("A", 1)]
        _validate(spec, textures)
        # Parameters the parent didn't expose by a known pin: guess by name.
        guess = {"base_color": ("basecolor", "albedo", "diffuse", "color", "base"),
                 "normal": ("normal",), "roughness": ("rough",), "ao": ("ao", "occlusion")}
        ordered = sorted(textures.items(), key=lambda kv: (any(w in kv[0].lower() for w in ("detail", " b", "blend")), kv[0]))
        # Packed maps (ORM/ORMH/RMA/MRA), recognised by parameter or texture name.
        if not any(isinstance(spec.get(k), dict) and spec[k].get("texture") for k in ("roughness", "metallic")):
            for name, tex in ordered:
                layout = _packed_layout(name) or _packed_layout(tex.rsplit(".", 1)[-1])
                if layout and "detail" not in name.lower():
                    for key, ch in layout.items():
                        spec[key] = {"texture": tex, "channel": ch, "parameter": name}
                    break
        for key, words in guess.items():
            if key in spec and spec[key].get("texture"):
                continue
            exclude = {spec["base_color"].get("texture")} if key == "normal" and isinstance(spec.get("base_color"), dict) else set()
            if key in ("roughness", "ao"):
                # Never read a packed map (ORM, RHAOM, ...) as a single-channel one.
                exclude |= {t for n, t in textures.items() if _packed_layout(n) or _packed_layout(t.rsplit(".", 1)[-1])}
            best = _best_texture(textures, words, exclude)
            if best:
                spec[key] = {"texture": best[1], "channel": "rgb" if key in ("base_color", "normal") else "r", "parameter": best[0]}
        overrides = p.get("BasePropertyOverrides") or {}
        if overrides.get("bOverride_BlendMode"):
            spec["blend"] = overrides.get("BlendMode", spec.get("blend"))
        if overrides.get("bOverride_TwoSided"):
            spec["two_sided"] = bool(overrides.get("TwoSided"))
        return _cleanup(_validate(spec, textures))

    def _trace(self, pkg: Package, pin, depth: int = 0):
        if not isinstance(pin, dict) or depth > 12:
            return None
        expr = pin.get("expression")
        if not isinstance(expr, Ref) or expr.index <= 0:
            if pin.get("use_constant"):
                return {"constant": pin.get("constant")}
            return None
        e = pkg.exports[expr.index - 1]
        props = e.properties
        cls = e.class_name
        channel = CHANNEL_BY_OUTPUT.get(pin.get("output", 0), "rgb")
        mask = pin.get("mask") or (0, 0, 0, 0, 0)
        if mask[0]:
            picked = [c for c, on in zip("rgba", mask[1:]) if on]
            if len(picked) == 1:
                channel = picked[0]
        if cls in TEXTURE_EXPRESSIONS:
            tex = props.get("Texture")
            out = {"texture": tex.path if isinstance(tex, Ref) else None, "channel": channel}
            if props.get("ParameterName"):
                out["parameter"] = props["ParameterName"]
            return out
        if cls == "MaterialExpressionConstant":
            return {"constant": props.get("R", 0.0)}
        if cls in ("MaterialExpressionConstant3Vector", "MaterialExpressionConstant4Vector"):
            c = props.get("Constant", (1, 1, 1, 1))
            return {"constant": list(c) if isinstance(c, tuple) else c}
        if cls == "MaterialExpressionScalarParameter":
            return {"constant": props.get("DefaultValue", 0.0), "parameter": props.get("ParameterName")}
        if cls == "MaterialExpressionVectorParameter":
            c = props.get("DefaultValue", (1, 1, 1, 1))
            return {"constant": list(c) if isinstance(c, tuple) else c, "parameter": props.get("ParameterName")}
        # Arithmetic and other nodes: prefer a texture found on any input; keep a tint for Multiply.
        found = None
        tint = None
        pins = [(k, v) for k, v in props.items() if isinstance(v, dict) and "expression" in v]
        if cls == "MaterialExpressionLinearInterpolate":
            pins = [(k, v) for k, v in pins if k != "Alpha"]  # the blend mask is not the colour
        elif cls == "MaterialExpressionMaterialFunctionCall":
            pins = [("Input", fi.get("Input")) for fi in props.get("FunctionInputs") or []
                    if isinstance(fi, dict) and isinstance(fi.get("Input"), dict)]
        for k, v in pins:
            if True:
                t = self._trace(pkg, v, depth + 1)
                if t and t.get("texture") and not found:
                    found = t
                elif t and "constant" in t and tint is None:
                    tint = t["constant"]
                    if cls == "MaterialExpressionMultiply" and _is_zero(tint) and not t.get("parameter"):
                        return {"constant": 0.0}  # x * 0: the pin is effectively off
        if cls == "MaterialExpressionMultiply" and tint is None and _is_zero(props.get("ConstB", 1.0)):
            return {"constant": 0.0}
        if found:
            if cls == "MaterialExpressionMultiply" and tint is not None:
                found = dict(found, tint=tint)
            return found
        if cls == "MaterialExpressionMultiply" and tint is not None:
            return {"constant": tint}
        return None


def _is_zero(v) -> bool:
    if isinstance(v, (int, float)):
        return v == 0
    if isinstance(v, (list, tuple)) and v:
        return all(isinstance(x, (int, float)) and x == 0 for x in v[:3])
    return False


PACKED_LAYOUTS = {
    "ormh": {"ao": "r", "roughness": "g", "metallic": "b"},
    "orma": {"ao": "r", "roughness": "g", "metallic": "b"},
    "orm": {"ao": "r", "roughness": "g", "metallic": "b"},
    "arm": {"ao": "r", "roughness": "g", "metallic": "b"},
    "occlusionroughnessmetallic": {"ao": "r", "roughness": "g", "metallic": "b"},
    "rma": {"roughness": "r", "metallic": "g", "ao": "b"},
    "mra": {"metallic": "r", "roughness": "g", "ao": "b"},
    "mrao": {"metallic": "r", "roughness": "g", "ao": "b"},
    "rhaom": {"roughness": "r", "ao": "b", "metallic": "a"},
    "rhao": {"roughness": "r", "ao": "b"},
}


def _packed_layout(name: str):
    low = name.lower().replace(" ", "_")
    for token in reversed([t for t in low.replace("-", "_").split("_") if t]):
        if token in PACKED_LAYOUTS:
            return PACKED_LAYOUTS[token]
        if token in ("a", "b", "tex", "texture", "map"):
            continue
        break
    return None


SLOT_SUFFIXES = {
    "base_color": ("basecolor", "albedo", "diffuse", "color", "_d", "_bc", "_col"),
    "normal": ("normal", "_n", "_nrm", "_nor"),
}


NOT_COLOR_WORDS = ("mask", "noise", "var", "detail", "blend", "grunge", "height", "rhaom", "orm", "rough", "normal")


def _is_data_texture(name: str) -> bool:
    low = name.lower()
    return any(w in low for w in NOT_COLOR_WORDS)


def _best_texture(textures: dict, words, exclude=()):
    """Picks the (parameter, texture) whose names best match the slot keywords.
    Texture names ending in the keyword win over parameter names; masks, noise,
    variation, detail and blend textures are never picked."""
    best, best_score = None, 0
    for name, tex in textures.items():
        if tex in exclude:
            continue
        tex_name = tex.rsplit(".", 1)[-1].lower()
        param = name.lower().replace(" ", "")
        if any(w in param or w in tex_name for w in ("mask", "noise", "var", "detail", "blend", "grunge")):
            continue
        score = 0
        for w in words:
            key = w.strip("_")
            if len(key) < 2:
                continue
            if tex_name.endswith("_" + key) or tex_name.endswith(key):
                score = max(score, 3)
            elif param.endswith(key):
                score = max(score, 2)
            elif key in param or key in tex_name:
                score = max(score, 1)
        if score > best_score:
            best, best_score = (name, tex), score
    return best


def _validate(spec: dict, textures: dict) -> dict:
    """Rejects implausible traces (a mask channel used as colour, a mask or the
    colour map used as normal map) and fills the gaps from names."""
    bc, nm = spec.get("base_color"), spec.get("normal")
    if isinstance(bc, dict) and bc.get("texture") and (bc.get("channel") not in ("rgb", None)
                                                         or _is_data_texture(bc["texture"].rsplit(".", 1)[-1])):
        spec.pop("base_color")
        bc = None
    if isinstance(nm, dict) and nm.get("texture") and (nm.get("channel") not in ("rgb", None)
                                                         or (isinstance(bc, dict) and nm.get("texture") == bc.get("texture"))):
        spec.pop("normal")
    for key, words in SLOT_SUFFIXES.items():
        if isinstance(spec.get(key), dict) and spec[key].get("texture"):
            continue
        exclude = {spec["base_color"].get("texture")} if key == "normal" and isinstance(spec.get("base_color"), dict) else set()
        best = _best_texture(textures, words, exclude)
        if best:
            spec[key] = {"texture": best[1], "channel": "rgb", "parameter": best[0]}
    return spec


def _cleanup(spec: dict) -> dict:
    """An emissive that just reuses the base color texture comes from graphs like
    BaseColor * EmissiveMask * Intensity whose factors we can't evaluate; in
    practice those are off unless the material is an emissive one."""
    e, b = spec.get("emissive"), spec.get("base_color")
    if isinstance(e, dict) and isinstance(b, dict) and e.get("texture") and e.get("texture") == b.get("texture"):
        if "emiss" not in spec.get("name", "").lower():
            del spec["emissive"]
    if isinstance(e, dict) and _is_zero(e.get("constant")) and not e.get("texture"):
        spec.pop("emissive", None)
    return spec


# --- meshes ------------------------------------------------------------------

def _source_mesh_description(pkg: Package, export) -> meshdesc.MeshDescription:
    models = export.properties.get("SourceModels") or []
    bulk_ref = models[0].get("StaticMeshDescriptionBulkData") if models and isinstance(models[0], dict) else None
    if isinstance(bulk_ref, Ref) and bulk_ref.index > 0:
        # UE5: the description lives in a separate object whose payload is in the package trailer.
        bulk = pkg.exports[bulk_ref.index - 1]
        pkg.read_export(bulk)
        trailer = Trailer(pkg.data)
        ident = trailer.find_in(pkg.data[bulk.tail_offset:bulk.serial_offset + bulk.serial_size])
        if ident is None:
            raise FormatError("static mesh has no MeshDescription payload")
        return meshdesc.parse_ue5(trailer.payload(ident))
    r = Reader(pkg.data, export.tail_offset)
    if r.u32():
        r.guid()
    r.u8(); r.u8()  # strip flags
    if r.bool32():
        raise FormatError("cooked static mesh; only editor assets are supported")
    r.i32()  # BodySetup
    r.i32()  # NavCollision
    for _ in export.properties.get("SourceModels") or [None]:
        read_bulk(pkg, r)  # legacy RawMesh
        r.guid()
        _skip_int_list_or_flag(r)
        if r.bool32():
            blob = read_bulk(pkg, r)
            r.guid(); r.u32()
            return meshdesc.parse(blob)
        raise FormatError("static mesh has no MeshDescription (legacy RawMesh not supported yet)")
    raise FormatError("static mesh has no source model")


def _skip_int_list_or_flag(r: Reader):
    """After the RawMesh GUID, some 4.26 saves write a bool and others an int32
    list (count + values, seen as [7, 8] or [7, 8, 9]). Pick the reading after
    which a valid MeshDescription header (bIsValid + bulk flags) follows."""
    start = r.pos
    n = r.i32()

    def plausible(pos: int) -> bool:
        if pos + 12 > len(r.data):
            return False
        valid, flags, count = struct.unpack_from("<Iii", r.data, pos)
        return valid == 0 or (valid == 1 and 0 <= flags < 0x40000 and count > 0)

    if 0 <= n < 4096 and plausible(start + 4 + 4 * n):
        r.pos = start + 4 + 4 * n
    else:
        r.pos = start + 4


def convert_static_mesh(pkg: Package, export, out_file: str) -> dict:
    pkg.read_export(export)
    md = _source_mesh_description(pkg, export)
    va = md.attributes.get("vertex_instance", {})
    positions = md.attributes["vertex"]["Position"][0]
    normals = (va.get("Normal") or [None])[0]
    uvs = va.get("TextureCoordinate") or []
    colors = (va.get("Color") or [None])[0]

    # Material slots: polygon group slot names -> StaticMaterials index.
    static_materials = export.properties.get("StaticMaterials") or []
    slot_names = [m.get("ImportedMaterialSlotName") or m.get("MaterialSlotName") for m in static_materials]
    group_names = (md.attributes.get("polygon_group", {}).get("ImportedMaterialSlotName") or [[]])[0]
    section_map = {k: v.get("MaterialIndex", k) for k, v in ((export.properties.get("SectionInfoMap") or {}).get("Map") or [])}

    def slot_of_group(g: int) -> int:
        if g < len(group_names) and group_names[g] in slot_names:
            return slot_names.index(group_names[g])
        return section_map.get(g, g)

    def conv(v):  # UE (x fwd, y right, z up; left-handed) -> glTF (y up; right-handed)
        return (v[0], v[2], v[1])

    n_inst = len(md.vertex_ids)
    pos = [tuple(c * UE_TO_GLTF_SCALE for c in conv(positions[vid])) for vid in md.vertex_ids]
    nrm = None
    if normals:
        nrm = []
        for n in normals:
            x, y, z = conv(n)
            ln = (x * x + y * y + z * z) ** 0.5 or 1.0
            nrm.append((x / ln, y / ln, z / ln))

    # The axis swap mirrors the mesh, so the winding may need flipping: compare
    # geometric normals with the vertex normals and follow the majority.
    flip = False
    if nrm:
        agree = 0
        for a, b, c, _p in md.triangles[:2000]:
            pa, pb, pc = pos[a], pos[b], pos[c]
            u = [pb[i] - pa[i] for i in range(3)]
            w = [pc[i] - pa[i] for i in range(3)]
            gn = (u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0])
            vn = [nrm[a][i] + nrm[b][i] + nrm[c][i] for i in range(3)]
            agree += 1 if sum(gn[i] * vn[i] for i in range(3)) >= 0 else -1
        flip = agree < 0

    prims: dict[int, list[int]] = {}
    for a, b, c, poly in md.triangles:
        g = md.polygon_groups_of_polygon[poly] if poly < len(md.polygon_groups_of_polygon) else 0
        idx = prims.setdefault(slot_of_group(g), [])
        idx += (a, c, b) if flip else (a, b, c)

    gltf = _GltfBuilder()
    attrs = {"POSITION": gltf.accessor(pos, "VEC3", minmax=True)}
    if nrm:
        attrs["NORMAL"] = gltf.accessor(nrm, "VEC3")
    for ch, uv in enumerate(uvs[:2]):
        if uv:
            attrs[f"TEXCOORD_{ch}"] = gltf.accessor(uv, "VEC2")
    if colors and any(c != (1.0, 1.0, 1.0, 1.0) for c in colors[:200]):
        attrs["COLOR_0"] = gltf.accessor(colors, "VEC4")
    materials = []
    primitives = []
    slots = []
    for slot in sorted(prims):
        mat_ref = static_materials[slot].get("MaterialInterface") if slot < len(static_materials) else None
        mat_path = mat_ref.path if isinstance(mat_ref, Ref) else ""
        mat_name = mat_ref.name if isinstance(mat_ref, Ref) else (slot_names[slot] if slot < len(slot_names) else f"Slot{slot}")
        materials.append({"name": mat_name})
        slots.append({"name": slot_names[slot] if slot < len(slot_names) else f"Slot{slot}", "material": mat_path, "material_name": mat_name})
        primitives.append({"attributes": attrs, "indices": gltf.accessor(prims[slot], "SCALAR", index=True, count_max=n_inst), "material": len(materials) - 1})
    gltf.doc["materials"] = materials
    gltf.doc["meshes"] = [{"name": export.object_name, "primitives": primitives}]
    gltf.doc["nodes"] = [{"name": export.object_name, "mesh": 0}]
    gltf.doc["scenes"] = [{"nodes": [0]}]
    gltf.doc["scene"] = 0
    gltf.write_glb(out_file)
    return {"file": out_file, "slots": slots, "counts": md.counts, "winding_flipped": flip}


class _GltfBuilder:
    def __init__(self):
        self.bin = bytearray()
        self.doc = {"asset": {"version": "2.0", "generator": "Asset Bridge uasset converter"},
                    "buffers": [], "bufferViews": [], "accessors": []}

    def accessor(self, data, kind: str, minmax=False, index=False, count_max=0) -> int:
        comps = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[kind]
        while len(self.bin) % 4:
            self.bin.append(0)
        start = len(self.bin)
        if index:
            self.bin += struct.pack(f"<{len(data)}I", *data)
            ctype = 5125
            count = len(data)
        else:
            flat = [c for v in data for c in (v if isinstance(v, tuple) else (v,))]
            self.bin += struct.pack(f"<{len(flat)}f", *flat)
            ctype = 5126
            count = len(data)
        view = {"buffer": 0, "byteOffset": start, "byteLength": len(self.bin) - start}
        if index:
            view["target"] = 34963
        else:
            view["target"] = 34962
        self.doc["bufferViews"].append(view)
        acc = {"bufferView": len(self.doc["bufferViews"]) - 1, "componentType": ctype, "count": count, "type": kind}
        if minmax:
            acc["min"] = [min(v[i] for v in data) for i in range(comps)]
            acc["max"] = [max(v[i] for v in data) for i in range(comps)]
        self.doc["accessors"].append(acc)
        return len(self.doc["accessors"]) - 1

    def write_glb(self, path: str):
        while len(self.bin) % 4:
            self.bin.append(0)
        self.doc["buffers"] = [{"byteLength": len(self.bin)}]
        js = json.dumps(self.doc, separators=(",", ":")).encode()
        js += b" " * (-len(js) % 4)
        total = 12 + 8 + len(js) + 8 + len(self.bin)
        with open(path, "wb") as f:
            f.write(struct.pack("<III", 0x46546C67, 2, total))
            f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
            f.write(struct.pack("<II", len(self.bin), 0x004E4942) + bytes(self.bin))


# --- driver ------------------------------------------------------------------

def _drop_empty_alpha_inputs(manifest: dict):
    """A packed map whose alpha is all opaque has no fourth channel in practice
    (e.g. foliage RHAOM maps); reading metallic/roughness/AO from it would make
    the surface fully metallic. Such inputs fall back to defaults instead."""
    empty = {k for k, t in manifest["textures"].items() if t.get("empty_alpha")}
    for spec in manifest["materials"].values():
        for key in ("metallic", "roughness", "ao"):
            v = spec.get(key)
            if isinstance(v, dict) and v.get("channel") == "a" and v.get("texture") in empty:
                del spec[key]


def convert_content(content_root: str, out_dir: str) -> dict:
    manifest = {"textures": {}, "materials": {}, "meshes": {}, "skipped": Counter(), "errors": []}
    analyzer = MaterialAnalyzer(content_root)
    files = []
    for d, _, names in os.walk(content_root):
        files += [os.path.join(d, n) for n in names if n.endswith(".uasset")]
    material_paths = set()
    for f in sorted(files):
        rel = os.path.relpath(f, content_root)
        game = file_to_game_path(content_root, f)
        try:
            pkg = load(f)
            main = pkg.main_export()
            cls = main.class_name if main else ""
            dst = os.path.join(out_dir, os.path.splitext(rel)[0])
            if cls == "Texture2D":
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                info = convert_texture(pkg, main, dst + ".png")
                info["file"] = os.path.relpath(info["file"], out_dir).replace(os.sep, "/")
                manifest["textures"][game] = info
            elif cls == "StaticMesh":
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                info = convert_static_mesh(pkg, main, dst + ".glb")
                info["file"] = os.path.relpath(info["file"], out_dir).replace(os.sep, "/")
                manifest["meshes"][game] = info
                material_paths.update(s["material"] for s in info["slots"] if s["material"])
            elif cls == "Material" or cls.startswith("MaterialInstance"):
                material_paths.add(game)
            else:
                manifest["skipped"][cls or "unknown"] += 1
        except OodleUnavailable as err:
            manifest["oodle_missing"] = manifest.get("oodle_missing", 0) + 1
            if manifest["oodle_missing"] == 1:
                manifest["errors"].append(str(err))
        except (FormatError, KeyError, IndexError, ValueError, struct.error, zlib.error) as err:
            manifest["errors"].append(f"{rel}: {err}")
    for mp in sorted(material_paths):
        try:
            spec = analyzer.analyze(mp)
            if spec:
                manifest["materials"][mp] = spec
        except (FormatError, KeyError, IndexError, ValueError, struct.error) as err:
            manifest["errors"].append(f"{mp}: {err}")
    _drop_empty_alpha_inputs(manifest)
    manifest["skipped"] = dict(manifest["skipped"])
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1, default=str)
    return manifest


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    m = convert_content(argv[0], argv[1])
    print(json.dumps({"textures": len(m["textures"]), "materials": len(m["materials"]),
                      "meshes": len(m["meshes"]), "skipped": m["skipped"], "errors": m["errors"]}))
    return 1 if m["errors"] and not m["meshes"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
