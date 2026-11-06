"""Exports Unreal static meshes (with materials/textures) to glTF for Asset Bridge.

Run inside Unreal Editor (Linux, Windows or macOS), e.g. from the Output Log's
Python console or on the command line:

    UnrealEditor <Project>.uproject -run=pythonscript \
        -script="/path/to/unreal_export.py --content /Game/MyPack --out /tmp/mypack_gltf"

Then import the output folder with Asset Bridge:

    tools/asset-bridge --project <godot project> import /tmp/mypack_gltf

Uses the built-in glTF Exporter plugin (enable "glTF Exporter" under
Edit > Plugins) which bakes Unreal materials to PBR textures. Without it, falls
back to FBX meshes plus raw texture exports (materials then come from
Asset Bridge's texture-set matching, T_<Name>_D/_N/_ORM etc.).

Requires the Python Editor Script Plugin. Not tested against every engine
version; please report issues.
"""
import argparse
import os
import sys

import unreal  # only available inside Unreal Editor


def parse_args(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--content", default="/Game", help="content path to export, e.g. /Game/MyPack")
    p.add_argument("--out", required=True, help="output directory on disk")
    p.add_argument("--format", choices=["gltf", "glb", "fbx"], default="gltf")
    return p.parse_args(argv)


def assets_of_class(path, class_name):
    registry = unreal.AssetRegistryHelpers.get_asset_registry()
    flt = unreal.ARFilter(package_paths=[path], recursive_paths=True,
                          class_names=[class_name])
    return [a.get_asset() for a in registry.get_assets(flt)]


def rel_dir(asset, root):
    pkg = str(asset.get_path_name()).split(".")[0]
    rel = os.path.dirname(pkg)[len(root):].lstrip("/")
    return rel


def export_gltf(mesh, filename):
    options = unreal.GLTFExportOptions()
    options.bake_material_inputs = unreal.GLTFMaterialBakeMode.USE_MESH_DATA
    selected = unreal.Set(unreal.Actor)
    return unreal.GLTFExporter.export_to_gltf(mesh, filename, options, selected)


def export_task(obj, filename, exporter=None):
    task = unreal.AssetExportTask()
    task.object = obj
    task.filename = filename
    task.automated = True
    task.prompt = False
    task.replace_identical = True
    if exporter is not None:
        task.exporter = exporter
    return unreal.Exporter.run_asset_export_task(task)


def main(argv):
    args = parse_args(argv)
    root = args.content.rstrip("/")
    os.makedirs(args.out, exist_ok=True)
    has_gltf = hasattr(unreal, "GLTFExporter")
    fmt = args.format if (has_gltf or args.format == "fbx") else "fbx"
    if fmt != args.format:
        unreal.log_warning("glTF Exporter plugin not enabled; exporting FBX + textures instead")

    meshes = assets_of_class(root, "StaticMesh")
    ok = 0
    for mesh in meshes:
        d = os.path.join(args.out, rel_dir(mesh, root))
        os.makedirs(d, exist_ok=True)
        name = mesh.get_name()
        if fmt in ("gltf", "glb"):
            success = export_gltf(mesh, os.path.join(d, f"{name}.{fmt}"))
        else:
            success = export_task(mesh, os.path.join(d, f"{name}.fbx"))
        ok += 1 if success else 0
        if not success:
            unreal.log_warning(f"export failed: {mesh.get_path_name()}")

    if fmt == "fbx":
        # Raw textures so Asset Bridge can rebuild materials from texture names.
        for tex in assets_of_class(root, "Texture2D"):
            d = os.path.join(args.out, "Textures", rel_dir(tex, root))
            os.makedirs(d, exist_ok=True)
            export_task(tex, os.path.join(d, f"{tex.get_name()}.tga"))

    unreal.log(f"Asset Bridge export: {ok}/{len(meshes)} meshes -> {args.out}")


if __name__ == "__main__":
    main(sys.argv[1:])
