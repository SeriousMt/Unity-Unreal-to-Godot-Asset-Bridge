# Getting started

## Requirements

| What | Needed for | Notes |
|---|---|---|
| **Godot 4.3 or newer** | everything | 4.3 added the built-in FBX importer (ufbx). Tested with 4.7.2. |
| **Python 3.10+** | Unreal content only | Standard library only, no `pip install`. On Windows, `python` must be on `PATH`. |
| **ImageMagick** (`magick` or `convert`) | PSD/TIFF/GIF textures; faster texture processing | Optional. Without it PSD/TIFF are skipped with a warning, and channel operations fall back to slower GDScript code. |
| **g++ or clang++** (x86-64) | UE5-saved Unreal content | Optional, only to build the `ab-ooz` Oodle decompressor once. |
| **bash** | the `tools/asset-bridge` wrapper | Linux and macOS. On Windows, call Godot directly (see [Usage](usage.md#without-the-wrapper)). |

Asset Bridge runs on Linux, macOS and Windows. Everything was developed and
tested on Linux.

## 1. Add the addon to your project

Copy the addon folder into your Godot project:

```bash
cp -r addons/asset_bridge ~/my_game/addons/
```

Then open the project in Godot, go to **Project → Project Settings → Plugins**
and enable **Asset Bridge**. A dock named *Asset Bridge* appears at the top
right of the editor.

The `addons/asset_bridge/unreal/` folder contains a `.gdignore` file, so Godot
never scans or exports the Python converter or the `ab-ooz` helper. Nothing of
Asset Bridge ends up in your exported game unless your game code uses it.

## 2. (Optional) Put the command line wrapper on your PATH

The wrapper `tools/asset-bridge` runs Godot headless and prints one JSON result.
It finds Godot through the `GODOT` environment variable, or `godot4`/`godot` on `PATH`:

```bash
export GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64
```

```bash
ln -s "$PWD/tools/asset-bridge" ~/.local/bin/asset-bridge
```

## 3. (Optional) Build the Oodle helper for UE5 content

Only needed for Unreal assets saved by UE5. Most Fab Unreal packs made with UE4
don't need it. Run this from the Asset Bridge repository:

```bash
tools/ooz-helper/build.sh
```

It downloads [powzix/ooz](https://github.com/powzix/ooz) (GPL-3.0-or-later) at a
pinned commit, builds `ab-ooz`, and puts it in `addons/asset_bridge/unreal/bin/`.
If you copied the addon into your game project before building, copy `bin/` over
too, or point `ASSET_BRIDGE_OOZ` at the binary:

```bash
export ASSET_BRIDGE_OOZ=/path/to/ab-ooz
```

See [Unreal internals](unreal-internals.md#oodle-and-the-ab-ooz-helper) for why
it's a separate program and what the license means for you.

## 4. First import

In the editor: in the Asset Bridge dock, click **File…** or **Folder…**, pick a
download, check the output folder (default `res://imported/<name>`), and click
**Import**. The log in the dock shows what was found and converted, then Godot
imports the new files.

From the command line:

```bash
asset-bridge --project ~/my_game inspect ~/Downloads/pack.zip
```

```bash
asset-bridge --project ~/my_game import ~/Downloads/pack.zip
```

`inspect` only reports what's inside and writes nothing. `import` converts, lets
Godot import the result, and then loads every generated scene and material to
verify it. Look at the `warnings` and `hints` in the output: they say what was
skipped and what to do about it.

The results land in `res://imported/<name>/`, keeping the source's folder
structure. Open a generated `.tscn` (from Unity prefabs) or the imported
`.fbx`/`.glb` to see the assets with their materials. An `asset_bridge_report.json`
in the output folder records what happened.

Next: [Getting assets](getting-assets.md) explains which download format to
pick on each store, and [Usage](usage.md) covers all options.
