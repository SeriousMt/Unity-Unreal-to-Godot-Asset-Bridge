# Getting assets

Asset Bridge converts files you have downloaded; it doesn't log into stores for
you. This page explains which format to pick and how to get it.

**Licenses:** converting a file doesn't change its license. Some marketplace
content is licensed for one engine only. Check each asset's license before you
ship it in a Godot game.

## Which format to choose

When a listing offers several formats, prefer them in this order:

1. **Unity package (`.unitypackage`)** carries the most: materials, prefabs
   (with colliders and lights), scenes, and character animation setups.
2. **FBX / OBJ / glTF / GLB + textures** works well and needs no extra tools.
   Materials are rebuilt from texture names. A GLB with embedded textures is
   kept exactly as it is.
3. **Unreal Engine** is experimental: textures, static meshes and materials are
   converted without Unreal, but characters, maps and Blueprints are not.
4. **Formats that aren't supported:** 3ds Max, Maya, Cinema 4D, ZBrush, Blender
   source files (unless Godot's Blender import is set up), USD, Substance
   `.sbsar`, V-Ray `.vrmesh`/`.vrmat`.

If you download several formats into one folder, Asset Bridge picks the best one
automatically (Unity over loose files over Unreal). Use `--prefer all` or
`--prefer unreal` to change that.

## Fab (fab.com)

Open the listing, or your library at fab.com/library, and click **Download**.
The dialog lists the formats the seller provided:

- **Unity** gives a `.unitypackage`.
- **fbx / obj / Cinema 4D / Maya** each give a zip.
- **Converted files** (GLB, glTF, USDZ) are automatic conversions made by Fab.
  The GLB is a good single-file option.
- **Additional files** often hold the textures (e.g. `textures.zip` with 1K, 2K
  and 4K versions).
- **Unreal Engine** says *"available in the Epic Games Launcher, or the Fab UE5
  Plugin"*. There is no web download for it. See below.

Downloads split into several zips can be imported together:

```bash
asset-bridge --project ~/my_game import ~/Downloads/fbx.zip ~/Downloads/textures.zip --out res://imported/beech
```

### Unreal-format Fab items without the Epic launcher

Some listings only offer Unreal Engine files. The community tool
[fab-downloader](https://github.com/Fobal/fab-downloader) (GPL-3.0, Python,
standard library only) downloads items you own, for any engine version, on
Linux, macOS and Windows.

Things to know before using it:

- It is unofficial and uses the Epic Games Launcher's private endpoints and
  public client ID, so it presents itself as the launcher. Epic can break it at
  any time. Check that it fits your use of Epic's terms.
- You sign in once in your browser. Epic then shows a JSON page; you paste its
  `authorizationCode` into the tool. The session is stored unencrypted, readable
  only by your user, in `~/.config/fab-downloader/session.bin`.
  `python3 -m fabdl logout` ends the session and deletes it.
- It is a young project. Read its code before running it, as with any tool you
  give account access to. During development of Asset Bridge, `fabdl/auth.py`,
  `fabdl/net.py` and `fabdl/fab.py` were reviewed: they only talk to Epic's
  account service, `fab.com` and the download CDN URLs Fab returns.

Usage (from a clone of fab-downloader):

```bash
python3 -m fabdl list Mobile
```

```bash
python3 -m fabdl download "Mobile Trees" --engine 5.4 --out ~/Downloads/ue_mobile_trees
```

If the engine version isn't available, the error lists the ones that are.
The first output line shows the build, e.g.
`(UE_5.6, build 5.8.0-…)`: a build starting with `4.` means the pack is stored
in UE4 format (no Oodle helper needed), even if you asked for a UE5 version.

Then import the folder:

```bash
asset-bridge --project ~/my_game import ~/Downloads/ue_mobile_trees
```

## Leartes Cosmos (cosmos.leartesstudios.com)

Cosmos lists the available formats on each product page. Typically:

- meshes as **FBX** or **OBJ**, textures as **PNG/JPEG**: imported as loose
  files with texture-set materials;
- **Unity** (`.unitypackage`) and **Unreal** (`.uasset`) versions, often in one
  zip with `Unity/` and `Unreal/` folders;
- **SBSAR** materials: not supported. Render them to PNG maps with Substance
  Player or `sbsrender` first.

Download the zip from your account and import it as is. Asset Bridge extracts
it and picks the best variant.

## Unity Asset Store

Download the asset in the Unity editor, or export it from a Unity project via
**Assets → Export Package…**, and import the resulting `.unitypackage`. A whole
Unity project folder (with `Assets/` and `.meta` files) works too.

## Quixel Megascans and other texture libraries

Texture-only downloads (e.g. `*_Albedo.jpg`, `*_Normal.jpg`, `*_Roughness.jpg`)
become materials in `materials/`. Resolution suffixes such as `2K` are ignored
when grouping. Megascans normal maps are OpenGL style. Use
`--normal-convention directx` for libraries that ship DirectX-style normal maps
in files not named `_NormalDX`.
