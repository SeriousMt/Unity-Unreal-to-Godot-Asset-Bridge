# Asset Bridge: notes for AI assistants and contributors

Godot 4.3+ addon that converts Unity, Fab, Cosmos, loose FBX/glTF and uncooked
Unreal assets into Godot resources. Read `docs/how-it-works.md` before larger
changes; `docs/unreal-internals.md` documents the reverse-engineered Unreal formats.

## Layout

- `addons/asset_bridge/`: the addon. `core/pipeline.gd` is the public API and
  orchestration; one importer per source kind (`unity_importer.gd`,
  `loose_importer.gd`, `unreal_importer.gd`); `cli.gd` is the headless entry.
- `addons/asset_bridge/unreal/uasset/`: Python `.uasset` reader/converter.
  Standard library only. `unreal/` has a `.gdignore`.
- `tools/asset-bridge`: CLI wrapper (JSON on stdout). `tools/uasset-dump`:
  inspect a package. `tools/ooz-helper/`: builds the optional Oodle decoder.
- `tests/`: `run.sh` (end to end), `test_uasset.py` (unit), fixtures, render/dump scripts.

## Commands

```bash
GODOT=/path/to/godot tests/run.sh          # everything (needs Blender + ImageMagick)
python3 -I tests/test_uasset.py            # Unreal format unit tests only
tools/asset-bridge --project <proj> import <source> --out res://imported/x
tools/uasset-dump file.uasset
```

Syntax-check a script: `godot --headless --path <proj> --check-only --script res://addons/asset_bridge/<file>.gd`

## Rules that matter

- **No `class_name`** in the addon; use `preload` with relative paths, so
  headless `--script` runs work in projects that were never opened in the editor.
- **Write Godot files as text** (`core/text_writer.gd`) instead of loading and
  saving resources. Imports must work in one pass, before Godot has imported
  the textures and models they reference.
- **Hand-written FBX `.import` files must set `fbx/importer=0`.** Without it
  Godot falls back to FBX2glTF and the import silently fails (`valid=false`).
- Keep the addon compatible with **Godot 4.3** APIs. CI tests 4.3 and the latest
  release. Godot < 4.4 needs a second import pass for models with external
  material remaps (`util.models_needing_second_import`); keep it working.
- Python: **standard library only**, run with `python3 -I`. `-I` ignores the
  current directory, so use `sys.path.insert(...)` (see `tools/uasset-dump`),
  not `-m`.
- GDScript: avoid `:=` on `Variant` expressions (dictionary `get`, untyped
  loop variables); Godot rejects inferring types from them.
- Don't vendor GPL code. `ab-ooz` is built from ooz by `build.sh` and is
  git-ignored; the addon only calls it as a separate program.

## Testing changes for real

- `verify` only proves files load. **Render the result** with
  `tests/render_scene.gd` under `xvfb-run` and look at it. Most real bugs
  (swapped colour channels, colour maps compressed as normal maps, emission
  added instead of multiplied, metallic foliage) were only visible in renders.
- When changing Unreal material heuristics, recheck materials from several packs,
  not just the one that prompted the change. Heuristics that fix one pack have
  broken others.
- Real store content is **never committed**: no packs, converted output or
  renders of store assets. Keep them in git-ignored `tests/out_real/`.
- On the main dev machine `/tmp` is a 16 GB RAM disk. Put large outputs on
  disk (`tests/out_real/`), never in `/tmp`.

## Conventions

- Report problems through `report.warn()` / `report.hint()`; hints are
  instructions a user or agent can act on.
- Update the docs in `docs/` together with behaviour changes, and add a
  fixture or unit test for every new format rule.
- Commit messages: imperative subject, body explaining why.
