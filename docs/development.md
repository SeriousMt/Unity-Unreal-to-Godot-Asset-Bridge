# Development

## Repository layout

```
addons/asset_bridge/          the addon (copy this into a project)
  plugin.cfg, plugin.gd       editor plugin entry
  dock.gd                     editor dock UI
  cli.gd                      headless command line (inspect / import / verify)
  core/pipeline.gd            detection, variant choice, orchestration (public API)
  core/unity_importer.gd      .unitypackage / Unity folders → Godot
  core/unity_yaml.gd          Unity YAML parser
  core/loose_importer.gd      FBX/OBJ/glTF + texture sets → Godot
  core/unreal_importer.gd     runs the Unreal converter, manifest → Godot
  core/materials.gd           material .tres, .import settings, image operations
  core/model_probe.gd         reads FBX/glTF names before import
  core/text_writer.gd         writes .tscn/.tres text
  core/report.gd              the JSON result
  core/util.gd                files, archives, external tools
  unreal/.gdignore            keeps Godot away from the Python code and binaries
  unreal/uasset/              Python .uasset reader and converter (stdlib only)
  unreal/bin/                 built ab-ooz (git-ignored)
tools/asset-bridge            bash wrapper: JSON on stdout
tools/ooz-helper/             build script + sources for ab-ooz
tools/uasset-dump             prints an Unreal package's tables and properties
tools/unreal_export.py        export script for people who have Unreal Editor (untested)
tests/run.sh                  end-to-end test
tests/make_fixtures.py        builds synthetic test inputs (needs Blender + ImageMagick)
tests/test_uasset.py          unit tests for the Unreal format code
tests/dump_scene.gd           prints an instantiated scene tree as JSON
tests/render_scene.gd         renders a scene to PNG
docs/                         this documentation
```

`project.godot` at the root makes the repository itself a Godot project with
the plugin enabled, for working on the dock.

## Running the tests

```bash
GODOT=/path/to/godot tests/run.sh
```

This runs:

1. the Unreal format unit tests (`tests/test_uasset.py`): `TSCF_UEDELTA` round
   trips for 8 and 16 bit, through Python and through `ab-ooz` if built; packed
   map names; UE5 type trees;
2. `tests/make_fixtures.py`, which builds a synthetic `.unitypackage` (FBX from
   Blender, Standard and URP materials, a TIFF texture, plain/variant/nested
   prefabs, a scene) and a Cosmos-style zip (FBX models, texture sets in 2K and
   4K, a suffix-less foliage texture with alpha, an Unreal folder);
3. imports both into a throwaway project in `tests/out/` and checks the
   results, including instantiated scene trees (positions, materials,
   overrides).

It needs Blender and ImageMagick for the fixtures. The unit tests alone:

```bash
python3 -I tests/test_uasset.py
```

Real store content can't be committed, so the Unreal converter was verified on
real Fab packs by hand; see [Unreal internals](unreal-internals.md#verified-packs).

## Visual checks

`verify` only proves that files load. To see whether they look right, render
them. `tests/render_scene.gd` frames a scene, lights it and saves a PNG. It
needs a display; on a headless machine use `xvfb-run`:

```bash
cp tests/render_scene.gd ~/my_game/
```

```bash
xvfb-run -a godot --path ~/my_game --rendering-driver opengl3 --resolution 640x560 --script res://render_scene.gd -- res://imported/pack/Prefab.tscn out.png 35
```

The arguments are the scene, the output file, the camera yaw in degrees, and an
optional animation name to pose a character.

Most bugs found during development were only visible this way: swapped colour
channels, normal-map compression applied to colour textures, emission added
instead of multiplied, metallic foliage.

## Debugging tools

- `tools/asset-bridge --verbose …`: Godot's log on stderr.
- `--keep-staging`: keeps extracted archives and the Unreal converter's
  `manifest.json` in `user://asset_bridge_staging/`.
- `tools/uasset-dump file.uasset`: prints a package's summary, imports,
  exports and properties.
- Run the Unreal converter on its own:

```bash
python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); from uasset.convert import main; sys.exit(main(sys.argv[2:]))" addons/asset_bridge/unreal /path/to/Content /tmp/out
```

- `tests/dump_scene.gd`: prints a scene's instantiated node tree with
  positions and materials as JSON.

## Conventions

- **No `class_name`** in the addon: scripts reference each other with
  `preload` and relative paths, so headless `--script` runs work without an
  imported project.
- **No loading during conversion:** generated files reference each other by
  path and are written as text, so a whole import works in one pass before
  Godot has imported anything. See [How it works](how-it-works.md#writing-godot-files-without-loading-them).
- **Godot 4.3 compatibility:** avoid APIs newer than 4.3 in the addon.
- **Python:** standard library only, run with `-I` (isolated mode). Downloads are
  untrusted data; the converter only reads them.
- **Hand-written `.import` files must set `fbx/importer=0`.** Otherwise Godot
  falls back to FBX2glTF and the import fails.

## Adding support for something new

1. Get a real sample and look at it: `--keep-staging`, `uasset.dump`, or the
   files themselves.
2. Add detection in `pipeline.gd` if it's a new kind of source.
3. Convert in the matching importer. Write Godot text files rather than
   loading resources.
4. Add a synthetic fixture to `tests/make_fixtures.py` and a check to
   `tests/run.sh`, or a unit test to `tests/test_uasset.py`.
5. Render a real sample with `render_scene.gd` and compare it with how the asset
   should look.
6. Note new limitations in the docs.

Ideas for next steps: Unreal maps → `.tscn` (placed static meshes, lights,
foliage instances as `MultiMesh`), Unreal skeletal meshes and animations, Unity
`.anim` clips and Animator state machines, and a Windows build of `ab-ooz`.
