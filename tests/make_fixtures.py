#!/usr/bin/env python3
"""Builds synthetic test inputs for Asset Bridge.

Creates, in the given output directory:
  demo.unitypackage   Unity package: FBX model + .meta, Standard and URP
                      materials, textures (incl. TIFF), prefabs (plain,
                      model variant, nested) and a scene.
  cosmos_style.zip    Loose download: FBX models + T_*_BaseColor/_Normal/_ORM
                      texture sets + a dummy Unreal .uasset folder.

Needs: python3, blender (for FBX export), ImageMagick (for the TIFF).
Usage: make_fixtures.py <out_dir>
"""
import io
import os
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import zlib

BLENDER_SCRIPT = r'''
import bpy, sys
args = sys.argv[sys.argv.index("--") + 1:]
kind, out = args[0], args[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
def mat(name):
    return bpy.data.materials.get(name) or bpy.data.materials.new(name)
if kind == "rock":
    bpy.ops.mesh.primitive_cube_add(size=1)
    o = bpy.context.active_object; o.name = "Rock_A"; o.data.name = "Rock_A_geo"
    o.data.materials.append(mat("M_Rock")); o.data.materials.append(mat("M_Moss"))
    for i, p in enumerate(o.data.polygons): p.material_index = i % 2
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.25, location=(1, 0, 0))
    s = bpy.context.active_object; s.name = "Pebble"; s.data.name = "Pebble_geo"; s.parent = o
    s.data.materials.append(mat("M_Moss"))
elif kind == "crate":
    bpy.ops.mesh.primitive_cube_add(size=1)
    o = bpy.context.active_object; o.name = "SM_Crate"; o.data.materials.append(mat("M_Crate"))
elif kind == "fern":
    bpy.ops.mesh.primitive_plane_add(size=1)
    o = bpy.context.active_object; o.name = "SM_Fern"; o.data.materials.append(mat("Fern_Leaves_Mat"))
elif kind == "bush":
    bpy.ops.mesh.primitive_plane_add(size=1)
    o = bpy.context.active_object; o.name = "SM_Bush"; o.data.materials.append(mat("M_Bush_Leaves"))
bpy.ops.export_scene.fbx(filepath=out)
'''


def png(path, w, h, fn):
    """Writes an RGBA PNG; fn(x, y) -> (r, g, b, a)."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(fn(x, y))
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


def blender(kind, out):
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(BLENDER_SCRIPT)
        script = f.name
    subprocess.run(["blender", "-b", "--factory-startup", "--python", script, "--", kind, out],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.unlink(script)


G = {  # fixed GUIDs
    "fbx": "a1000000000000000000000000000001",
    "m_rock": "a2000000000000000000000000000002",
    "m_moss": "a3000000000000000000000000000003",
    "t_albedo": "a4000000000000000000000000000004",
    "t_normal": "a5000000000000000000000000000005",
    "t_metal": "a6000000000000000000000000000006",
    "t_moss": "a7000000000000000000000000000007",
    "p_rock": "a8000000000000000000000000000008",
    "p_variant": "a9000000000000000000000000000009",
    "p_nested": "b1000000000000000000000000000010",
    "scene": "b2000000000000000000000000000011",
    "script": "b3000000000000000000000000000012",
}
HDR = "%YAML 1.1\n%TAG !u! tag:unity3d.com,2011:\n"

FBX_META = f"""fileFormatVersion: 2
guid: {G['fbx']}
ModelImporter:
  serializedVersion: 21300
  internalIDToNameTable:
  - first:
      1: 919132149155446097
    second: rock
  - first:
      4: -4216859302048453862
    second: rock
  - first:
      1: 1001
    second: Rock_A
  - first:
      4: 4001
    second: Rock_A
  - first:
      43: 4300000
    second: Rock_A
  - first:
      23: 2300000
    second: Rock_A
  - first:
      1: 1002
    second: Pebble
  - first:
      4: 4002
    second: Pebble
  - first:
      43: 4300002
    second: Pebble
  - first:
      23: 2300002
    second: Pebble
  externalObjects:
  - first:
      type: UnityEngine:Material
      assembly: UnityEngine.CoreModule
      name: M_Rock
    second: {{fileID: 2100000, guid: {G['m_rock']}, type: 2}}
  materials:
    materialImportMode: 2
  meshes:
    globalScale: 1
    useFileScale: 1
"""

def tex_meta(guid, normal=False):
    return f"""fileFormatVersion: 2
guid: {guid}
TextureImporter:
  serializedVersion: 12
  mipmaps:
    sRGBTexture: {0 if normal else 1}
  textureType: {1 if normal else 0}
"""

def simple_meta(guid, importer="NativeFormatImporter"):
    return f"fileFormatVersion: 2\nguid: {guid}\n{importer}:\n  externalObjects: {{}}\n"

def tex_env(name, guid, sx=1, sy=1):
    ref = f"{{fileID: 2800000, guid: {guid}, type: 3}}" if guid else "{fileID: 0}"
    return f"""    - {name}:
        m_Texture: {ref}
        m_Scale: {{x: {sx}, y: {sy}}}
        m_Offset: {{x: 0, y: 0}}
"""

M_ROCK = HDR + f"""--- !u!21 &2100000
Material:
  serializedVersion: 6
  m_ObjectHideFlags: 0
  m_Name: M_Rock
  m_Shader: {{fileID: 46, guid: 0000000000000000f000000000000000, type: 0}}
  m_ShaderKeywords: _METALLICGLOSSMAP _NORMALMAP
  m_SavedProperties:
    serializedVersion: 3
    m_TexEnvs:
""" + tex_env("_BumpMap", G["t_normal"]) + tex_env("_DetailAlbedoMap", None) + tex_env("_MainTex", G["t_albedo"], 2, 2) \
    + tex_env("_MetallicGlossMap", G["t_metal"]) + tex_env("_OcclusionMap", None) + """    m_Floats:
    - _BumpScale: 1.2
    - _Cutoff: 0.5
    - _GlossMapScale: 0.8
    - _Glossiness: 0.5
    - _Metallic: 0
    - _Mode: 0
    - _SmoothnessTextureChannel: 0
    m_Colors:
    - _Color: {r: 0.9, g: 0.85, b: 0.8, a: 1}
    - _EmissionColor: {r: 0, g: 0, b: 0, a: 1}
"""

M_MOSS = HDR + f"""--- !u!21 &2100000
Material:
  serializedVersion: 8
  m_Name: M_Moss
  m_Shader: {{fileID: 4800000, guid: 933532a4fcc9baf4fa0491de14d08ed7, type: 3}}
  m_ValidKeywords:
  - _ALPHATEST_ON
  m_SavedProperties:
    serializedVersion: 3
    m_TexEnvs:
""" + tex_env("_BaseMap", G["t_moss"]) + tex_env("_MainTex", G["t_moss"]) + """    m_Floats:
    - _AlphaClip: 1
    - _Cull: 0
    - _Cutoff: 0.4
    - _Metallic: 0
    - _Smoothness: 0.3
    - _Surface: 0
    m_Colors:
    - _BaseColor: {r: 0.4, g: 0.8, b: 0.3, a: 1}
"""

ROCK_PREFAB = HDR + f"""--- !u!1 &100
GameObject:
  m_ObjectHideFlags: 0
  serializedVersion: 6
  m_Component:
  - component: {{fileID: 101}}
  - component: {{fileID: 102}}
  - component: {{fileID: 103}}
  - component: {{fileID: 104}}
  - component: {{fileID: 105}}
  m_Layer: 0
  m_Name: Rock
  m_IsActive: 1
--- !u!4 &101
Transform:
  m_GameObject: {{fileID: 100}}
  m_LocalRotation: {{x: 0, y: 0.38268343, z: 0, w: 0.9238795}}
  m_LocalPosition: {{x: 1, y: 0, z: 2}}
  m_LocalScale: {{x: 1, y: 1, z: 1}}
  m_Children:
  - {{fileID: 201}}
  - {{fileID: 301}}
  m_Father: {{fileID: 0}}
--- !u!33 &102
MeshFilter:
  m_GameObject: {{fileID: 100}}
  m_Mesh: {{fileID: 4300000, guid: {G['fbx']}, type: 3}}
--- !u!23 &103
MeshRenderer:
  m_GameObject: {{fileID: 100}}
  m_Enabled: 1
  m_CastShadows: 1
  m_Materials:
  - {{fileID: 2100000, guid: {G['m_rock']}, type: 2}}
  - {{fileID: 2100000, guid: {G['m_moss']}, type: 2}}
--- !u!65 &104
BoxCollider:
  m_GameObject: {{fileID: 100}}
  m_IsTrigger: 0
  m_Enabled: 1
  serializedVersion: 3
  m_Size: {{x: 1, y: 1, z: 1}}
  m_Center: {{x: 0.25, y: 0.5, z: 0}}
--- !u!114 &105
MonoBehaviour:
  m_GameObject: {{fileID: 100}}
  m_Enabled: 1
  m_Script: {{fileID: 11500000, guid: {G['script']}, type: 3}}
  speed: 2
--- !u!1 &200
GameObject:
  m_Component:
  - component: {{fileID: 201}}
  - component: {{fileID: 202}}
  - component: {{fileID: 203}}
  - component: {{fileID: 204}}
  m_Name: PebbleChild
  m_IsActive: 1
--- !u!4 &201
Transform:
  m_GameObject: {{fileID: 200}}
  m_LocalRotation: {{x: 0, y: 0, z: 0, w: 1}}
  m_LocalPosition: {{x: 0.5, y: 0.5, z: 0}}
  m_LocalScale: {{x: 1, y: 1, z: 1}}
  m_Children: []
  m_Father: {{fileID: 101}}
--- !u!33 &202
MeshFilter:
  m_GameObject: {{fileID: 200}}
  m_Mesh: {{fileID: 4300002, guid: {G['fbx']}, type: 3}}
--- !u!23 &203
MeshRenderer:
  m_GameObject: {{fileID: 200}}
  m_Materials:
  - {{fileID: 2100000, guid: {G['m_moss']}, type: 2}}
--- !u!135 &204
SphereCollider:
  m_GameObject: {{fileID: 200}}
  m_IsTrigger: 1
  m_Radius: 0.3
  m_Center: {{x: 0, y: 0, z: 0}}
--- !u!1 &300
GameObject:
  m_Component:
  - component: {{fileID: 301}}
  - component: {{fileID: 302}}
  m_Name: Lamp
  m_IsActive: 0
--- !u!4 &301
Transform:
  m_GameObject: {{fileID: 300}}
  m_LocalRotation: {{x: 0, y: 0, z: 0, w: 1}}
  m_LocalPosition: {{x: 0, y: 2, z: 0}}
  m_LocalScale: {{x: 1, y: 1, z: 1}}
  m_Children: []
  m_Father: {{fileID: 101}}
--- !u!108 &302
Light:
  m_GameObject: {{fileID: 300}}
  m_Type: 2
  m_Color: {{r: 1, g: 0.8, b: 0.6, a: 1}}
  m_Intensity: 2
  m_Range: 5
  m_Shadows:
    m_Type: 2
"""

VARIANT_PREFAB = HDR + f"""--- !u!1001 &500
PrefabInstance:
  m_ObjectHideFlags: 0
  serializedVersion: 2
  m_Modification:
    m_TransformParent: {{fileID: 0}}
    m_Modifications:
    - target: {{fileID: -4216859302048453862, guid: {G['fbx']},
        type: 3}}
      propertyPath: m_LocalPosition.x
      value: 3
      objectReference: {{fileID: 0}}
    - target: {{fileID: -4216859302048453862, guid: {G['fbx']}, type: 3}}
      propertyPath: m_LocalRotation.w
      value: 1
      objectReference: {{fileID: 0}}
    - target: {{fileID: -4216859302048453862, guid: {G['fbx']}, type: 3}}
      propertyPath: m_RootOrder
      value: 0
      objectReference: {{fileID: 0}}
    - target: {{fileID: 919132149155446097, guid: {G['fbx']}, type: 3}}
      propertyPath: m_Name
      value: RockVariant
      objectReference: {{fileID: 0}}
    - target: {{fileID: 2300000, guid: {G['fbx']}, type: 3}}
      propertyPath: 'm_Materials.Array.data[0]'
      value:
      objectReference: {{fileID: 2100000, guid: {G['m_moss']}, type: 2}}
    m_RemovedComponents: []
  m_SourcePrefab: {{fileID: 100100000, guid: {G['fbx']}, type: 3}}
--- !u!1 &501 stripped
GameObject:
  m_CorrespondingSourceObject: {{fileID: 919132149155446097, guid: {G['fbx']}, type: 3}}
  m_PrefabInstance: {{fileID: 500}}
  m_PrefabAsset: {{fileID: 0}}
--- !u!65 &502
BoxCollider:
  m_GameObject: {{fileID: 501}}
  m_IsTrigger: 0
  m_Enabled: 1
  m_Size: {{x: 2, y: 1, z: 1}}
  m_Center: {{x: 0, y: 0, z: 0}}
"""

NESTED_PREFAB = HDR + f"""--- !u!1 &600
GameObject:
  m_Component:
  - component: {{fileID: 601}}
  m_Name: Group
  m_IsActive: 1
--- !u!4 &601
Transform:
  m_GameObject: {{fileID: 600}}
  m_LocalRotation: {{x: 0, y: 0, z: 0, w: 1}}
  m_LocalPosition: {{x: 0, y: 0, z: 0}}
  m_LocalScale: {{x: 1, y: 1, z: 1}}
  m_Children:
  - {{fileID: 702}}
  m_Father: {{fileID: 0}}
--- !u!1001 &700
PrefabInstance:
  m_Modification:
    m_TransformParent: {{fileID: 601}}
    m_Modifications:
    - target: {{fileID: 101, guid: {G['p_rock']}, type: 3}}
      propertyPath: m_LocalPosition.x
      value: -5
      objectReference: {{fileID: 0}}
    - target: {{fileID: 100, guid: {G['p_rock']}, type: 3}}
      propertyPath: m_Name
      value: RockCopy
      objectReference: {{fileID: 0}}
  m_SourcePrefab: {{fileID: 100100000, guid: {G['p_rock']}, type: 3}}
--- !u!4 &702 stripped
Transform:
  m_CorrespondingSourceObject: {{fileID: 101, guid: {G['p_rock']}, type: 3}}
  m_PrefabInstance: {{fileID: 700}}
"""

SCENE = HDR + f"""--- !u!29 &1
OcclusionCullingSettings:
  m_ObjectHideFlags: 0
--- !u!1 &800
GameObject:
  m_Component:
  - component: {{fileID: 801}}
  - component: {{fileID: 802}}
  - component: {{fileID: 803}}
  m_Name: Ground
  m_IsActive: 1
--- !u!4 &801
Transform:
  m_GameObject: {{fileID: 800}}
  m_LocalRotation: {{x: 0, y: 0, z: 0, w: 1}}
  m_LocalPosition: {{x: 0, y: 0, z: 0}}
  m_LocalScale: {{x: 2, y: 1, z: 2}}
  m_Children: []
  m_Father: {{fileID: 0}}
  m_RootOrder: 0
--- !u!33 &802
MeshFilter:
  m_GameObject: {{fileID: 800}}
  m_Mesh: {{fileID: 10209, guid: 0000000000000000e000000000000000, type: 0}}
--- !u!23 &803
MeshRenderer:
  m_GameObject: {{fileID: 800}}
  m_Materials:
  - {{fileID: 10303, guid: 0000000000000000f000000000000000, type: 0}}
--- !u!1 &900
GameObject:
  m_Component:
  - component: {{fileID: 901}}
  - component: {{fileID: 902}}
  m_Name: Sun
  m_IsActive: 1
--- !u!4 &901
Transform:
  m_GameObject: {{fileID: 900}}
  m_LocalRotation: {{x: 0.40821788, y: -0.23456968, z: 0.10938163, w: 0.8754261}}
  m_LocalPosition: {{x: 0, y: 3, z: 0}}
  m_LocalScale: {{x: 1, y: 1, z: 1}}
  m_Children: []
  m_Father: {{fileID: 0}}
  m_RootOrder: 2
--- !u!108 &902
Light:
  m_GameObject: {{fileID: 900}}
  m_Type: 1
  m_Color: {{r: 1, g: 0.95, b: 0.84, a: 1}}
  m_Intensity: 1
  m_Shadows:
    m_Type: 2
--- !u!1001 &1000
PrefabInstance:
  m_Modification:
    m_TransformParent: {{fileID: 0}}
    m_Modifications:
    - target: {{fileID: 101, guid: {G['p_rock']}, type: 3}}
      propertyPath: m_LocalPosition.z
      value: 4
      objectReference: {{fileID: 0}}
    - target: {{fileID: 101, guid: {G['p_rock']}, type: 3}}
      propertyPath: m_RootOrder
      value: 1
      objectReference: {{fileID: 0}}
  m_SourcePrefab: {{fileID: 100100000, guid: {G['p_rock']}, type: 3}}
"""


def make_unitypackage(out_dir, work):
    entries = []  # (guid, pathname, asset_path or None, meta)
    mdl = os.path.join(work, "rock.fbx")
    blender("rock", mdl)
    entries.append((G["fbx"], "Assets/Demo/Models/rock.fbx", mdl, FBX_META))
    t = {}
    t["albedo"] = os.path.join(work, "rock_albedo.png")
    png(t["albedo"], 64, 64, lambda x, y: (150 + (x * 3) % 60, 120, 100, 255))
    t["normal"] = os.path.join(work, "rock_normal.png")
    png(t["normal"], 64, 64, lambda x, y: (128, 128 + (y % 16), 255, 255))
    t["metal"] = os.path.join(work, "rock_metal.png")
    png(t["metal"], 64, 64, lambda x, y: (40 if x < 32 else 220, 0, 0, 64 + y * 3))
    moss_png = os.path.join(work, "moss_src.png")
    png(moss_png, 32, 32, lambda x, y: (60, 160, 50, 255 if (x + y) % 8 else 0))
    t["moss"] = os.path.join(work, "moss.tif")
    subprocess.run([shutil.which("magick") or "convert", moss_png, t["moss"]], check=True)
    entries += [
        (G["t_albedo"], "Assets/Demo/Textures/rock_albedo.png", t["albedo"], tex_meta(G["t_albedo"])),
        (G["t_normal"], "Assets/Demo/Textures/rock_normal.png", t["normal"], tex_meta(G["t_normal"], True)),
        (G["t_metal"], "Assets/Demo/Textures/rock_metal.png", t["metal"], tex_meta(G["t_metal"])),
        (G["t_moss"], "Assets/Demo/Textures/moss.tif", t["moss"], tex_meta(G["t_moss"])),
    ]
    def text_asset(name, content):
        p = os.path.join(work, name)
        with open(p, "w") as f:
            f.write(content)
        return p
    entries += [
        (G["m_rock"], "Assets/Demo/Materials/M_Rock.mat", text_asset("M_Rock.mat", M_ROCK), simple_meta(G["m_rock"])),
        (G["m_moss"], "Assets/Demo/Materials/M_Moss.mat", text_asset("M_Moss.mat", M_MOSS), simple_meta(G["m_moss"])),
        (G["p_rock"], "Assets/Demo/Prefabs/Rock.prefab", text_asset("Rock.prefab", ROCK_PREFAB), simple_meta(G["p_rock"], "PrefabImporter")),
        (G["p_variant"], "Assets/Demo/Prefabs/RockVariant.prefab", text_asset("RockVariant.prefab", VARIANT_PREFAB), simple_meta(G["p_variant"], "PrefabImporter")),
        (G["p_nested"], "Assets/Demo/Prefabs/Nested.prefab", text_asset("Nested.prefab", NESTED_PREFAB), simple_meta(G["p_nested"], "PrefabImporter")),
        (G["scene"], "Assets/Demo/Scenes/Demo.unity", text_asset("Demo.unity", SCENE), simple_meta(G["scene"], "DefaultImporter")),
        (G["script"], "Assets/Demo/Scripts/Spinner.cs", text_asset("Spinner.cs", "public class Spinner : UnityEngine.MonoBehaviour { public float speed; }\n"), simple_meta(G["script"], "MonoImporter")),
    ]
    pkg = os.path.join(out_dir, "demo.unitypackage")
    with tarfile.open(pkg, "w:gz") as tar:
        for guid, pathname, asset, meta in entries:
            def add_bytes(name, data):
                info = tarfile.TarInfo(f"{guid}/{name}")
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
            add_bytes("pathname", (pathname + "\n00").encode())
            add_bytes("asset.meta", meta.encode())
            tar.add(asset, arcname=f"{guid}/asset")
    return pkg


def make_cosmos_zip(out_dir, work):
    root = os.path.join(work, "cosmos")
    os.makedirs(os.path.join(root, "FBX"))
    os.makedirs(os.path.join(root, "Textures"))
    os.makedirs(os.path.join(root, "Unreal", "Content", "Crate"))
    blender("crate", os.path.join(root, "FBX", "SM_Crate.fbx"))
    blender("bush", os.path.join(root, "FBX", "SM_Bush.fbx"))
    blender("fern", os.path.join(root, "FBX", "SM_Fern.fbx"))
    tx = os.path.join(root, "Textures")
    # Crate textures in 2K and 4K variants (only one should be imported).
    for res in ("2K", "4K"):
        d = os.path.join(tx, "Crate_" + res)
        os.makedirs(d)
        png(os.path.join(d, "T_Crate_BaseColor.png"), 32, 32, lambda x, y: (140, 90, 40, 255))
        png(os.path.join(d, "T_Crate_Normal.png"), 32, 32, lambda x, y: (128, 128, 255, 255))
        png(os.path.join(d, "T_Crate_ORM.png"), 32, 32, lambda x, y: (255, 180, 0, 255))
    # Base color without a suffix, transparency only in its alpha channel.
    png(os.path.join(tx, "T_Fern_Leaves.png"), 32, 32, lambda x, y: (40, 120, 30, 255 if (x + y) % 6 else 0))
    png(os.path.join(tx, "T_Fern_Leaves_Normal.png"), 32, 32, lambda x, y: (128, 128, 255, 255))
    png(os.path.join(tx, "T_Bush_Leaves_D.png"), 32, 32, lambda x, y: (50, 140, 40, 255))
    png(os.path.join(tx, "T_Bush_Leaves_Opacity.png"), 32, 32, lambda x, y: (255 if (x // 4 + y // 4) % 2 else 0,) * 3 + (255,))
    png(os.path.join(tx, "T_Bush_Leaves_N.png"), 32, 32, lambda x, y: (128, 128, 255, 255))
    with open(os.path.join(root, "Unreal", "Content", "Crate", "SM_Crate.uasset"), "wb") as f:
        f.write(b"\xc1\x83\x2a\x9e" + b"\0" * 60)
    z = os.path.join(out_dir, "cosmos_style.zip")
    with zipfile.ZipFile(z, "w") as zf:
        for d, _, files in os.walk(root):
            for fn in files:
                full = os.path.join(d, fn)
                zf.write(full, os.path.relpath(full, root))
    return z


def main():
    out_dir = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "fixtures")
    os.makedirs(out_dir, exist_ok=True)
    work = tempfile.mkdtemp()
    try:
        print(make_unitypackage(out_dir, work))
        print(make_cosmos_zip(out_dir, work))
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
