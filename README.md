# Asset Bridge

A Godot 4 addon that imports assets made for other engines and stores into
Godot-native resources: Unity packages and projects, Fab downloads (Unity, FBX,
GLB, and experimentally Unreal Engine), Leartes Cosmos packs, and plain
FBX/OBJ/glTF + texture folders. Use it from an editor dock, or headless from the
command line so scripts, CI and AI agents can drive it. It needs no Unity and no
Unreal Engine installation.

| Source | Result |
|---|---|
| `.unitypackage`, Unity project or folder with `.meta` files | Materials, models with remapped materials, prefabs and scenes as `.tscn` (colliders, lights, nested prefabs, variants), rigged characters with animation libraries |
| FBX / OBJ / glTF / GLB + textures (Fab, Cosmos, Megascans, …) | Texture sets become materials and are matched to the models; resolution variants and split archives handled |
| Unreal `Content/` folder (uncooked `.uasset`, UE4 and UE5) | **Experimental:** textures, static meshes and materials, converted without Unreal |
| `.zip` | Extracted and detected recursively; the best variant of a multi-format download is chosen |
| Cooked Unreal games, Substance `.sbsar`, V-Ray, DCC source files | Reported as unsupported, with what to do instead |

## Quick start

Requires **Godot 4.3+**. Optional: Python 3 (Unreal content), ImageMagick
(PSD/TIFF textures), g++ or clang++ (UE5 content).

Copy the addon into your Godot project (the folder must end up at
`res://addons/asset_bridge/`):

```bash
cp -r addons/asset_bridge ~/my_game/addons/
```

### In the Godot editor

1. Open your project in Godot and go to **Project → Project Settings →
   Plugins**. Tick **Enable** next to **Asset Bridge**. A dock named
   *Asset Bridge* appears at the top right, next to *Scene* and *Import*.
   If you don't see it, check the tabs above the Scene tree.
2. In the dock, click **File…** to pick a `.unitypackage`, `.zip`, `.fbx`,
   `.glb`, `.gltf` or `.obj`, or **Folder…** to pick a Unity project, an
   unpacked download or an Unreal `Content/` folder. The file can be anywhere
   on disk; it doesn't have to be inside the project. You can also paste a path
   into the *Source* field.
3. Check the **Output folder**. It is filled in as `res://imported/<name>`;
   change it if you want the assets somewhere else.
4. Optionally click **Inspect** to see what Asset Bridge found and how it would
   import it. Nothing is written.
5. Click **Import**. The editor is busy while the files are converted (large
   Unreal packs can take minutes), then Godot imports the new textures and
   models. The log shows **Done.** when everything is finished.
6. Read the yellow **warning** and cyan **hint** lines in the log: they say
   what was skipped and what to do about it.
7. In the *FileSystem* dock, open the output folder. Unity prefabs and scenes
   are `.tscn` files you can open or drag into your scene; models are
   `.fbx`, `.glb` or `.gltf` files with their materials already assigned (double-click one
   to open Godot's import settings, or drag it into a scene). Materials are
   `.tres` files. `asset_bridge_report.json` in the output folder records what
   happened.

The other options in the dock are explained in [Usage](docs/usage.md#editor-dock);
the defaults are right for most downloads.

### From the command line

```bash
export GODOT=/path/to/godot
```

```bash
tools/asset-bridge --project ~/my_game inspect ~/Downloads/pack.zip
```

```bash
tools/asset-bridge --project ~/my_game import ~/Downloads/pack.zip
```

For UE5-saved Unreal content, build the optional Oodle decompressor once:

```bash
tools/ooz-helper/build.sh
```

## Documentation

- [Getting started](docs/getting-started.md): requirements, installation, first import
- [Getting assets](docs/getting-assets.md): which format to download from Fab, Cosmos and the Unity Asset Store, and Unreal files without the Epic launcher
- [Usage](docs/usage.md): editor dock, command line options, JSON result, GDScript API, use from AI agents
- [How it works](docs/how-it-works.md): the pipeline and the Unity, loose-file and Unreal importers
- [Unreal internals](docs/unreal-internals.md): the `.uasset` reader, UE4/UE5 formats, Oodle, material tracing
- [Troubleshooting](docs/troubleshooting.md)
- [Development](docs/development.md): layout, tests, visual checks, debugging tools
- [Contributing](CONTRIBUTING.md): reporting packs that convert badly (without sharing paid files), changing code

## Tested with real store content

| Pack | Format | Result |
|---|---|---|
| SciFi Beast06 Bull (Fab) | `.unitypackage` | 3 rigged characters, 29 animations, materials |
| Realistic Beech Tree (Fab) | FBX + separate multi-resolution texture zip; Fab's converted GLB | Leaves with alpha cut-out, matches the GLB |
| Mobile Trees (Fab) | FBX + TGA with suffix-less names; Unreal (UE 4.26) | Both formats render the same |
| Underground Tunnel (Fab) | Unreal (UE 4.26), 5.5 GB | 317 meshes, 217 textures, 103 materials |
| Sharur's Normandy Village (Fab) | Unreal (UE 5.6), 3.9 GB | 105 meshes, 178 textures, 93 materials |

## License

Asset Bridge is released under the [MIT License](LICENSE).

It converts files; it doesn't change their license. Some marketplace
content is licensed for one engine only, so check each asset's license before you
ship it.

The optional `ab-ooz` helper is built from [ooz](https://github.com/powzix/ooz)
(GPL-3.0-or-later) and runs as a separate program. Its source isn't included
here, and it isn't exported with your game. Anyone distributing a prebuilt
`ab-ooz` must also provide its source under the GPL.

Asset Bridge is an independent project. It is not affiliated with or endorsed by
Unity Technologies, Epic Games (Unreal Engine, Fab, Oodle), Leartes Studios or
the Godot Foundation. Their names are used only to describe compatibility.
