# Troubleshooting

Start with the import result: `errors`, `warnings` and `hints` usually name the
problem. Add `--verbose` to see Godot's own log, and `--keep-staging` to keep
the extracted files for inspection.

## The command line

**`{"ok":false,"error":"Godot not found; set GODOT=/path/to/godot"}`**
Set `GODOT` to your Godot 4.3+ binary, or put `godot4`/`godot` on `PATH`.

**`addons/asset_bridge missing in …`**
`--project` must point at a Godot project that contains the addon. Copy
`addons/asset_bridge` into it.

**`no result from Godot; rerun with --verbose`**
Godot exited before printing a result, usually from a script error or a crash.
Rerun with `--verbose` and look at the last lines.

**`cannot write …/.godot/asset_bridge_cli.….log (disk full?)`**
The wrapper keeps Godot's log inside the project. Free some disk space. If
`/tmp` is a small RAM disk on your system, also keep large output folders off it.

## Imports that look wrong

**A material is flat white or glows**
A white emission colour with a dark emission texture: Godot adds them by
default. Asset Bridge sets the emission operator to *multiply*. If you see this
on a material you edited by hand, set *Emission → Operator* to *Multiply*.

**Textures look green and magenta / a material looks "chewed"**
A colour texture was imported as a normal map: Godot compresses normal maps
to two channels. Check the texture's *Import* tab (*Compress → Normal Map*
should be *Disabled* or *Detect* for colour maps). Re-importing with Asset
Bridge resets textures that it wrongly marked before.

**Lighting looks inverted on bumps**
The normal map uses the other convention. For loose downloads, re-import with
`--normal-convention directx` (or `opengl`). For a single texture, toggle
*Import → Normal Map Invert Y* and reimport.

**Leaves or plants are black**
A metallic value of 1 without reflections renders black. Check the material's
*Metallic* texture and channel. Asset Bridge drops metallic inputs that read an
alpha channel without data, but a seller's packed map can still contain
unexpected data.

**Wrong texture on a material (loose files)**
Matching is by name. Rename the texture set or the model material so they share
a name, or edit `materials/<name>.tres` and assign it in the model's import
settings (*Advanced Import Settings → Materials → Use External*).

**Wrong texture on a material (Unreal)**
Unreal master materials can be too complex to trace exactly. Look at the
material in `manifest.json` (keep staging), or inspect the package:

```bash
tools/uasset-dump /path/to/MI_Thing.uasset
```

Then fix the `.tres` by hand, or report the pattern so the heuristics can learn it.

**Models keep their original materials (Godot 4.3)**
Godot 4.3 imports models before their remapped materials can be loaded. Asset
Bridge reimports those models once more automatically. If you imported files
some other way, select the model and click *Reimport*.

**Objects are rotated or mirrored**
Unity scenes are converted by mirroring the X axis, which matches how both
engines import FBX files. A model whose FBX was imported in Unity with
*Bake Axis Conversion* or a custom scale can still differ; check the model's
`.import` settings (*Root Scale*).

## Missing pieces

**`ImageMagick not found; cannot convert X.psd`**
Install ImageMagick (`magick` or `convert` on `PATH`) and import again.

**`Unreal content needs Python 3 …`**
Install Python 3 and make `python3` (or `python` on Windows) available.

**`UE5-saved Unreal content is Oodle-compressed …`**
Build the helper once with `tools/ooz-helper/build.sh` (needs g++ or clang++),
or set `ASSET_BRIDGE_OOZ` to an existing `ab-ooz` binary.

**`texture source format TSF_RGBA16F not supported yet`**
Half-float textures are skipped. In the packs tested they were wind or effect
data with no Godot equivalent.

**Characters are static / no animation**
Unity characters only get animations through an Animator Controller in the
package. Unreal skeletal meshes aren't converted yet.

**Unreal levels or foliage are missing**
Maps, World Partition actors, landscapes, foliage and PCG aren't converted yet.
The meshes they use are.

## Performance and disk space

- **Godot's import takes most of the time** for big packs: it compresses every
  texture for the GPU (about 19 minutes for 217 large textures on a fast
  machine). Use `--texture-resolution 1k` or `2k` for loose packs that offer
  several resolutions.
- Conversion temporarily needs the source data twice (staging plus output).
  Large Unreal packs (several GB) need several GB free in the project and in
  Godot's user data folder.
- The dock blocks the editor while converting. Use the command line for big packs.
