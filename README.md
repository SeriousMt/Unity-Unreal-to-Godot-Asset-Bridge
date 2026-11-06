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

```bash
cp -r addons/asset_bridge ~/my_game/addons/
```

Enable **Asset Bridge** under *Project → Project Settings → Plugins* and use
the dock, or use the command line:

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

## Tested with real store content

| Pack | Format | Result |
|---|---|---|
| SciFi Beast06 Bull (Fab) | `.unitypackage` | 3 rigged characters, 29 animations, materials |
| Realistic Beech Tree (Fab) | FBX + separate multi-resolution texture zip; Fab's converted GLB | Leaves with alpha cut-out, matches the GLB |
| Mobile Trees (Fab) | FBX + TGA with suffix-less names; Unreal (UE 4.26) | Both formats render the same |
| Underground Tunnel (Fab) | Unreal (UE 4.26), 5.5 GB | 317 meshes, 217 textures, 103 materials |
| Sharur's Normandy Village (Fab) | Unreal (UE 5.6), 3.9 GB | 105 meshes, 178 textures, 93 materials |

## Licensing

Asset Bridge converts files; it doesn't change their license. Some marketplace
content is licensed for one engine only, so check each asset's license before you
ship it.

The optional `ab-ooz` helper is built from [ooz](https://github.com/powzix/ooz)
(GPL-3.0-or-later) and runs as a separate program. Its source isn't included
here, and it isn't exported with your game.
