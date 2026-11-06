# Asset Bridge documentation

| Page | Read it when you want to… |
|---|---|
| [Getting started](getting-started.md) | install the addon, the command line wrapper and the optional helpers, and do a first import |
| [Getting assets](getting-assets.md) | know which format to download from Fab, Leartes Cosmos, the Unity Asset Store and others, and how to fetch Unreal-format files without the Epic launcher |
| [Usage](usage.md) | use the editor dock, the command line, the JSON report, or the GDScript API (including from AI agents and CI) |
| [How it works](how-it-works.md) | understand the pipeline: detection, staging, the Unity, loose-file and Unreal importers, and verification |
| [Unreal internals](unreal-internals.md) | understand the `.uasset` reader: package layout, UE4/UE5 mesh and texture formats, Oodle, material tracing |
| [Troubleshooting](troubleshooting.md) | fix a failed or wrong-looking import |
| [Development](development.md) | work on Asset Bridge itself: layout, tests, debugging tools, adding formats |
| [Asset Library](asset-library.md) | publish a release to the Godot Asset Library |

Short version:

```bash
cp -r addons/asset_bridge ~/my_game/addons/
```

```bash
tools/asset-bridge --project ~/my_game import ~/Downloads/some_pack.zip
```
