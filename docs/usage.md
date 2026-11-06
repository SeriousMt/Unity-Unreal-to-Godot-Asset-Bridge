# Usage

Asset Bridge has three front ends that share one pipeline: the editor dock, the
command line, and a GDScript API.

## Editor dock

Enable the plugin (see [Getting started](getting-started.md)), then in the
*Asset Bridge* dock:

| Control | Meaning |
|---|---|
| **Source** + File…/Folder… | A `.unitypackage`, `.zip`, model file, Unity project or any folder with assets. Paths outside the project are fine. |
| **Output folder** | Where results go, a `res://` path. Filled in from the source name. |
| **Convert prefabs to scenes** | Unity prefabs → `.tscn`. |
| **Convert Unity scenes (.unity)** | Unity scenes → `.tscn`. |
| **Normal maps (loose textures)** | `auto`, `opengl` or `directx`, for loose texture sets (see [How it works](how-it-works.md#normal-map-conventions)). |
| **If Unity + FBX both present** | `auto` (best variant only), `all`, or `unreal` (prefer the Unreal files). |
| **Inspect** | Shows what would be imported. Writes nothing. |
| **Import** | Converts, then lets Godot import the new files. |

The conversion runs on the editor's main thread, so the editor is busy until it
finishes. Large Unreal packs can take minutes; prefer the command line for those.

## Command line

```bash
tools/asset-bridge [--project DIR] [--verbose] <command> [args]
```

- `--project` is the Godot project (default: current directory). It must
  contain `addons/asset_bridge`.
- `--verbose` sends Godot's own log to stderr.
- `GODOT` selects the Godot binary (default: `godot4` or `godot` on `PATH`).
- Relative file paths are made absolute before Godot starts.

### Commands

| Command | What it does |
|---|---|
| `inspect <source>` | Detects what's inside and how it would be imported. Writes nothing to the project. |
| `import <source>... [options]` | Converts, runs Godot's importer on the results, then verifies them. |
| `verify <res://dir>` | Loads every scene, material and model under a folder and reports failures and mesh nodes without a mesh. |

### Import options

| Option | Default | Meaning |
|---|---|---|
| `--out res://path` | `res://imported/<source name>` | Output folder. |
| `--no-prefabs` | off | Don't convert Unity prefabs. |
| `--no-scenes` | off | Don't convert Unity scenes. |
| `--normal-convention auto\|opengl\|directx` | `auto` | Normal map convention of loose texture sets. |
| `--prefer auto\|all\|unreal` | `auto` | Which variants of a download to import. |
| `--texture-resolution 1k\|2k\|4k\|8k\|max` | `2k` | Which variant to use when textures come in several resolutions. |
| `--no-reimport` | off | Only convert; skip Godot's import and the verify step. |
| `--report file.json` | — | Also write the JSON result to a file. |
| `--keep-staging` | off | Keep the extracted temporary files (for debugging). |

Several sources in one `import` are treated as one download, which is useful when
a store splits models and textures into separate archives:

```bash
tools/asset-bridge --project ~/my_game import ~/Downloads/fbx.zip ~/Downloads/textures.zip --out res://imported/beech
```

Exit codes: `0` success, `1` errors (see `errors` in the JSON), `2` usage error.

### Without the wrapper

On Windows, or in your own scripts, call Godot directly:

```bash
godot --headless --path ~/my_game --script res://addons/asset_bridge/cli.gd -- import ~/Downloads/pack.zip --out res://imported/pack
```

Godot prints its own log too; the result is the line that starts with
`ASSET_BRIDGE_RESULT ` followed by JSON.

## The JSON result

```json
{
  "ok": true,
  "source": "/home/me/Downloads/pack.zip",
  "output": "res://imported/pack",
  "units": [
    {"kind": "unitypackage", "name": "Pack", "status": "imported", "output": "res://imported/pack"},
    {"kind": "models", "status": "skipped", "reason": "Unity version of this download is imported instead …"}
  ],
  "stats": {"materials": 12, "models": 8, "prefabs": 8, "textures": 30, "colliders": 5},
  "files": ["res://imported/pack/…"],
  "warnings": ["…"],
  "errors": [],
  "hints": ["…"],
  "verify": {"ok": true, "checked": 28, "failed": [], "empty_mesh_nodes": []}
}
```

- `units`: what was found. `kind` is one of `unitypackage`, `unity_folder`,
  `models` (loose files), `unreal`, `substance`, `vray`. `status` is
  `imported`, `skipped`, `unsupported` or `failed`, and `reason` explains why.
- `stats`: counts of what was created. Keys like `unity_skipped_.cs` or
  `unreal_skipped_Blueprint` count what was deliberately left out.
- `warnings`: things that were imported imperfectly or skipped.
- `hints`: concrete next steps, e.g. "Install ImageMagick so PSD/TIFF textures
  can be converted" or "Build the optional decompressor once with
  tools/ooz-helper/build.sh".
- `verify` (after `import`): every generated resource was loaded; `failed`
  lists resources that didn't load.

A copy is saved as `<output>/asset_bridge_report.json`.

## Using it from an AI agent or CI

The command line was designed for this:

1. Run `inspect` first and read `units` to see what a download contains.
2. Run `import`. Treat `ok: false`, a non-zero exit code or `verify.failed` as
   failure.
3. Act on `hints`: they are written as instructions (rerun with an option,
   install a tool, download another format).
4. Imports are repeatable: running the same import again overwrites the
   generated files, so an agent can retry with different options.

## Output layout

Results keep the source's folder structure under the output folder:

| Source | Output |
|---|---|
| `Assets/Pack/Models/rock.fbx` (Unity) | `<out>/Pack/Models/rock.fbx` + `rock.fbx.import` (material remaps), `rock_meshes/*.res` (meshes used by prefabs) |
| `Assets/Pack/Materials/M_Rock.mat` | `<out>/Pack/Materials/M_Rock.tres` (+ `M_Rock_roughness.png` if generated) |
| `Assets/Pack/Prefabs/Rock.prefab` | `<out>/Pack/Prefabs/Rock.tscn` |
| `T_Crate_BaseColor.png` … (loose) | copied as is; the material goes to `<out>/materials/Crate.tres` |
| `Content/Pack/Meshes/SM_X.uasset` (Unreal) | `<out>/Pack/Meshes/SM_X.glb` |
| `Content/Pack/Materials/MI_X.uasset` | `<out>/Pack/Materials/MI_X.tres` |

Generated `.tres`/`.tscn` files are plain Godot resources. Edit them freely, but
note that importing the same source again overwrites them.

## GDScript API

```gdscript
var Pipeline = preload("res://addons/asset_bridge/core/pipeline.gd")

# What's in a download?
var info: Dictionary = Pipeline.inspect("/home/me/Downloads/pack.zip")

# Import it (the same options as the command line, as a dictionary).
var report: Dictionary = Pipeline.import_source(
	"/home/me/Downloads/pack.zip", "res://imported/pack",
	{"scenes": false, "texture_resolution": "4k", "prefer": "all"})

# Several archives of one download:
Pipeline.import_source(["/dl/fbx.zip", "/dl/textures.zip"], "res://imported/beech")
```

`import_source` only writes files. In the editor, call
`EditorInterface.get_resource_filesystem().scan()` afterwards so Godot imports
them.

Option keys: `prefabs`, `scenes` (bool), `normal_convention`, `prefer`,
`texture_resolution` (string), `keep_staging` (bool).
