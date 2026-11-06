# How it works

## The pipeline

```
source (file, folder, zip, several archives)
  │
  ├─ detect   ─ extract archives into a staging folder, classify the contents into "units"
  ├─ choose   ─ when one download holds several variants, decide which to import
  ├─ convert  ─ one importer per unit kind writes Godot files into the output folder
  ├─ import   ─ Godot's own importer imports the new files (FBX, glTF, textures)
  └─ verify   ─ every generated scene, material and model is loaded once
```

Everything up to *convert* happens in
[`core/pipeline.gd`](../addons/asset_bridge/core/pipeline.gd). The command line
([`cli.gd`](../addons/asset_bridge/cli.gd)) then starts a second Godot process
with `--import`, and a third one that runs `verify`, so the checks see the
project exactly as the editor will. The dock asks the running editor to rescan
instead.

### Detection

| Found | Unit kind |
|---|---|
| `.unitypackage` | `unitypackage` |
| `.meta` files | `unity_folder` (the common folder of all `.meta` files) |
| `.zip` | extracted to staging, then detected again (up to 3 levels deep) |
| `.uasset`/`.umap` | `unreal` (rooted at the nearest `Content` folder) |
| `.pak`/`.utoc`/`.ucas` | unsupported (cooked game files) |
| `.sbsar`, `.vrmesh`/`.vrmat` | unsupported, with a hint |
| models and images elsewhere | `models` (loose files) |

Loose files from several archives (or several `import` arguments) are merged into
one `models` unit, so materials can find textures that shipped in a separate zip.

Staging lives in `user://asset_bridge_staging/` (on Linux
`~/.local/share/godot/app_userdata/<project>/asset_bridge_staging/`) and is
deleted afterwards unless you pass `--keep-staging`.

### Choosing variants

With `--prefer auto` (default), Unity content wins over loose models, and either
wins over Unreal files, because that order matches how much each format carries
and how reliable its conversion is. `--prefer all` imports everything and
`--prefer unreal` only the Unreal files. Skipped units are listed in the
result with a reason.

### Writing Godot files without loading them

Godot can only load a texture after importing it. To generate everything in one
pass, Asset Bridge writes Godot's text formats directly
([`core/text_writer.gd`](../addons/asset_bridge/core/text_writer.gd)):
materials as `.tres`, scenes as `.tscn`, and settings into each model's or
texture's `.import` file. Those reference files by path, so they're valid before
Godot has imported anything.

Two features of Godot's scene importer do a lot of the work, configured
through the model's `.import` file:

- **External materials** (`_subresources/materials/<name>/use_external`) replace
  a model's own materials with the converted ones, so the model looks right
  wherever it's used.
- **Mesh extraction** (`_subresources/meshes/<name>/save_to_file`) saves single
  meshes as `.res` files, which converted prefabs reference directly.

Model files are read before import with Godot's runtime `FBXDocument` and
`GLTFDocument` ([`core/model_probe.gd`](../addons/asset_bridge/core/model_probe.gd))
to learn their node, mesh, material and animation names, the keys these
settings need.

## Unity

[`core/unity_importer.gd`](../addons/asset_bridge/core/unity_importer.gd)

1. **Asset table.** A `.unitypackage` is a gzipped tar of `<guid>/asset`,
   `<guid>/asset.meta` and `<guid>/pathname`. A project folder has the asset next
   to its `.meta`. Every reference in Unity files is a GUID plus a fileID, so
   this table is the base for everything else.
2. **YAML.** `.mat`, `.prefab`, `.unity` and `.meta` files use a Unity flavour of
   YAML (`--- !u!<classID> &<fileID>` documents, flow mappings, sequences at the
   same indent as their key). [`core/unity_yaml.gd`](../addons/asset_bridge/core/unity_yaml.gd)
   parses that subset and keeps every scalar a string, because fileIDs are
   64-bit and some GUIDs look like numbers.
3. **Textures** are copied; PSD/TIFF/GIF are converted to PNG with ImageMagick.
   Textures marked as normal maps, or used in a normal map slot, get normal-map
   import settings.
4. **Materials.** Properties are read by name, so Built-in Standard, URP Lit,
   HDRP Lit and most custom shaders work: base map/color, tiling and offset (V
   offset mirrored, since Godot flips V), normal map and scale, metallic,
   smoothness, occlusion, HDRP mask maps, emission, cutout or transparent
   surfaces, and culling. Unity stores *smoothness* while Godot wants
   *roughness*, and Godot can't invert a texture channel, so a roughness map is
   generated (`1 - smoothness × scale`). Godot adds the emission texture to the
   emission colour by default, Unity multiplies, so emission uses Godot's
   multiply mode.
5. **Models** are copied. Their `.import` maps each model material to a
   converted material, following the model's `externalObjects` first and then
   Unity's own name search (same folder, `Materials/` folder, unique name).
6. **Prefabs and scenes** become `.tscn`:
   - GameObjects become nodes; a MeshFilter + MeshRenderer becomes a
     `MeshInstance3D` with the extracted mesh and per-slot material overrides.
   - Transforms are converted from Unity's left-handed space by mirroring the X
     axis: position `(-x, y, z)`, rotation quaternion `(x, -y, -z, w)`. That's
     the same relation both engines have to the FBX file, so prefab objects line
     up with the models.
   - Box, sphere, capsule and mesh colliders become shapes under a
     `StaticBody3D`, an `Area3D` (triggers) or the node itself (Rigidbody).
     Mesh colliders are built from the model's mesh.
   - Lights and cameras become Godot ones, turned 180° because Unity's look +Z
     and Godot's −Z.
   - LOD groups keep LOD0.
   - Nested prefabs and prefab variants become instanced scenes. Their overrides
     (transform, name, active state, material slots) and added children or
     components are applied.
   - MonoBehaviours can't be converted; their script names are stored as node
     metadata `unity_scripts`.
7. **Characters.** Character packs often save the skeleton as GameObjects with
   SkinnedMeshRenderers. Rebuilding that as plain nodes would lose the
   skinning, so such a subtree becomes an instance of the imported FBX scene,
   which has a proper `Skeleton3D`. The Animator Controller's clips (Unity's
   `Model@Clip.fbx` convention) are saved as `Animation` resources during
   import, collected into an `AnimationLibrary`, and attached through an
   `AnimationPlayer` named `UnityAnimations`. Clips whose names suggest idle,
   walk or run loop.

## Loose models and texture sets

[`core/loose_importer.gd`](../addons/asset_bridge/core/loose_importer.gd)

1. **Resolution variants.** If the same texture exists at several resolutions
   (`_1K/`, `_2K/` folders, `2048` in the name), only the one selected by
   `--texture-resolution` is copied.
2. **Texture sets.** File names are split into tokens. A known suffix gives the
   slot (`BaseColor`, `D`, `Normal`, `N`, `ORM`, `RMA`, `MRA`, `Roughness`,
   `Metallic`, `AO`, `Emissive`, `Opacity`, `Gloss`, …), and the rest, minus
   prefixes like `T_` and resolution tokens, is the set name. A texture without a
   suffix is the base colour. Textures extracted from an FBX (`*.fbm/`) are left
   to the FBX.
3. **Materials.** Each set becomes `materials/<name>.tres`. Packed maps use
   per-channel texture inputs (Godot's `StandardMaterial3D` can read metallic,
   roughness and AO from any channel). Gloss maps are inverted into a roughness
   map. An opacity map is packed into the base colour's alpha. A base colour
   with real alpha, or an opacity map, gives an alpha-scissor material, and
   foliage-like names (leaf, grass, branch, …) are drawn double-sided.
4. **Matching.** Each model's materials are matched to sets: by exact key
   (`M_Crate` → `T_Crate_*`), by shared name tokens (`Mobile28_Trunk` →
   `T_Mobile_Trees_Trunk`, rejecting ties), or by the model's file name if it has
   a single material. Matches go into the model's `.import`. glTF/GLB materials
   that already carry textures are left alone.

### Normal map conventions

Godot (like glTF, Unity and Blender) uses OpenGL-style normal maps (green = up);
Unreal uses DirectX style (green = down). Asset Bridge flips the green channel
through Godot's import option `process/normal_map_invert_y` when a normal map is
DirectX style: always for Unreal content, for files named `_NormalDX`, and for
loose downloads that contain Unreal content or Unreal-named folders when
`--normal-convention auto` is used.

## Unreal

[`core/unreal_importer.gd`](../addons/asset_bridge/core/unreal_importer.gd)
runs the Python converter in
[`unreal/uasset/`](../addons/asset_bridge/unreal/uasset) on the `Content` folder.
The converter writes PNG textures, GLB meshes and a `manifest.json` describing
every material: which texture and channel feeds which input, blend mode,
two-sidedness. The GDScript side turns the manifest into `.tres` materials,
copies the files, remaps each GLB's materials and marks normal maps.

A separate page describes the file formats and the material tracing:
[Unreal internals](unreal-internals.md).

## Verification

`verify` loads every `.tscn`, `.tres` and model in the output folder, instantiates
scenes, and reports resources that fail to load and `MeshInstance3D` nodes
without a mesh. A converted asset can still look wrong while loading fine, so
real packs were also checked visually; see [Development](development.md#visual-checks).
