# Unreal internals

How Asset Bridge reads Unreal assets without Unreal Engine. Everything here was
worked out from real Fab packages and checked against them; where a detail was
inferred rather than taken from documentation, that's noted.

Code: [`addons/asset_bridge/unreal/uasset/`](../addons/asset_bridge/unreal/uasset),
Python 3 standard library only.

| Module | Reads |
|---|---|
| `uasset.py` | package summary, name/import/export tables |
| `properties.py` | tagged properties (UE4 and UE5 tag formats), material pins |
| `bulk.py` | UE4 bulk data, including zlib-compressed chunks |
| `trailer.py` | UE5 package trailer, `FCompressedBuffer`, `TSCF_UEDELTA` |
| `meshdesc.py` | `FMeshDescription` (UE4.26/4.27 and UE5 layouts) |
| `convert.py` | textures → PNG, static meshes → GLB, material tracing, `manifest.json` |
| `dump.py` | debugging: prints a package's tables and properties |

## Scope

Only **uncooked editor assets** are supported: the `Content/` folder of a
project, which is what Fab and Cosmos deliver. Shipped games use *cooked*
packages (`.pak`, `.utoc/.ucas`, unversioned properties, no source data), which
are a different problem and out of scope.

Uncooked assets keep their *source* data, the original texture image and the
editor's mesh description, so converting them loses nothing that the seller put
in.

## Package layout

A `.uasset` starts with a summary (magic `0x9E2A83C1`, the legacy file version,
UE4/UE5 object versions, custom versions, then offsets of the tables).
`uasset.py` follows the version-dependent fields for legacy versions −7 (UE4)
down to −9 (UE5.4+). After the summary come:

- the **name table**: every name used in the package;
- the **import table**: objects from other packages, e.g.
  `/Game/Pack/Textures/T_X.T_X`;
- the **export table**: the objects in this package, with their class, offset
  and size.

### Tagged properties

Each export starts with tagged properties: name, type, size, value, ending with
`None`. UE5.4+ replaced the per-type extras with a flattened *type tree*. For
example, a map from int to a struct is written as
`MapProperty(2) → IntProperty(0), StructProperty(1) → MeshSectionInfo(1) → /Script/Engine(0)`,
where each count is the number of child nodes. UE5 also writes one
serialization-control byte before an object's first property.

After the properties comes class-specific *native* data (for textures and
meshes, the source data or references to it).

## Textures

### UE4

The texture's `Source` property describes the image (size, format such as
`TSF_BGRA8`, `bPNGCompressed`). After the properties come the object GUID flag,
the strip flags and an `FByteBulkData` header (flags, element count, size on
disk, offset). Payloads at the end of the file are zlib-compressed in chunks.

Most UE4 sources are stored as a PNG. **UE4 writes `TSF_BGRA8` sources into the
PNG without reordering the channels, so red and blue come out swapped.** This
was confirmed by comparing a converted texture with the seller's own TGA: the
channel means matched exactly with R and B exchanged. The importer swaps them
back.

### UE5

UE5 keeps source payloads in a **package trailer** at the end of the file (tag
`0xD1C43B2E80A5F697`). The trailer has a table of entries (content hash, offset,
compressed and raw size), and the texture's native data contains the hash of its
payload. Each payload is an `FCompressedBuffer`: a 64-byte big-endian header
(magic `0xB7756362`, CRC, method, compressor, level, block size exponent, block
count, raw size, compressed size, BLAKE3 hash), a table of block sizes, then the
blocks. Method 0 means stored; method 3 means **Oodle**.

UE5 texture sources usually use `CompressionFormat = TSCF_UEDELTA`. Derived from
real assets and checked on full images:

- the image is split into **strips of 8 × bytes-per-pixel rows** (G8: 8, G16: 16,
  BGRA8: 32, RGBA16: 64);
- the **first row of each strip is stored raw**;
- every other row stores its **difference to the row above**: byte by byte
  for 8-bit channels; as **16-bit values with a +0x8080 bias** for 16-bit
  channels.

How this was checked: with the right rules, the last decoded row of a strip
matches the next raw row as closely as neighbouring rows match each other, and a
constant alpha channel decodes to exactly 255 over all 16.7 million pixels of a
4K texture. Wrong strip heights or predictors show up as visible horizontal
bands every strip.

8-bit sources become 8-bit PNGs, `TSF_RGBA16`/`TSF_G16` become 16-bit PNGs.
Half-float formats (`TSF_RGBA16F`) are skipped; in the packs tested they were
only PivotPainter wind data and bloom kernels.

## Static meshes

The importer reads the editor's **source mesh description**, not render data
(uncooked assets have none).

### UE4.26/4.27

`UStaticMesh` native data: object GUID flag, strip flags, `bCooked`, BodySetup
and NavCollision references, then per LOD source model: an (empty) legacy
RawMesh bulk block, its GUID, then either a boolean or a small int list (both
were seen in 4.26 saves; the converter decides by lookahead), then
`bIsValid` and the `MeshDescription` bulk data.

The mesh description holds:

- **element arrays** (allocation bit arrays plus per-element data): vertices,
  vertex instances (→ vertex index), edges (2 vertex indices), polygons
  (→ polygon group), polygon groups;
- **attribute sets** per element kind: name, type index (0 vector4, 1 vector3,
  2 vector2, 3 float, 4 int, 5 bool, 6 name), channel count, then per channel
  element size, count and raw values, then a default value and flags. Bools
  store their default as 32 bits. The position attribute is really named
  `"Position "`, with a trailing space;
- **triangles** (3 vertex instances + polygon) at the end.

### UE5

`SourceModels[i].StaticMeshDescriptionBulkData` points to a separate object
whose payload is in the package trailer. The UE5 layout is self-describing: a
count of named element types (`Vertices`, `VertexInstances`, `UVs`, `Edges`,
`Triangles`, `Polygons`, `PolygonGroups`), each with channels; a channel is an
allocation bit array plus an attribute set. Attributes carry an *extent*
(values per element, e.g. 3 vertex-instance indices per triangle). Triangles
carry their polygon group directly.

### Conversion to glTF

- One glTF vertex per vertex instance: position (from its vertex), normal, up
  to two UV channels, vertex colour (if not all white). Tangents are left to
  Godot's MikkTSpace generation.
- Coordinates: Unreal is left-handed, Z-up, in centimetres. The converter maps
  `(x, y, z) → (x, z, y) × 0.01`, a mirror that gives right-handed Y-up metres.
  Because a mirror flips triangle winding, the converter compares geometric
  normals with the vertex normals and flips the index order if most disagree.
- One primitive per material slot. Slots are matched by
  `ImportedMaterialSlotName`, falling back to `SectionInfoMap`. Each glTF
  material is named after the Unreal material asset, which the GDScript side
  remaps to the converted `.tres`.

## Materials

Unreal materials are node graphs, so there's no direct equivalent in Godot's
`StandardMaterial3D`. The converter finds, for each output pin (Base Color,
Normal, Roughness, Metallic, Ambient Occlusion, Emissive, Opacity Mask,
Opacity), the texture or constant that mostly determines it:

1. **Pins** (`FExpressionInput`/`FMaterialInput`) are read natively: expression
   reference, output index (0 RGB, 1 R, 2 G, 3 B, 4 A), mask flags, constant.
2. **Tracing** follows the pin back through the graph:
   - texture samples and texture parameters give a texture plus channel;
   - constants and scalar/vector parameters give a value;
   - other nodes are searched through their inputs. `Lerp` nodes only follow
     A and B, never the alpha mask. Material function calls follow their
     inputs. A `Multiply` by a constant 0 switches the pin off.
3. **Material instances** start from their parent's result and apply their
   texture, scalar and vector parameter overrides by parameter name, plus
   blend mode and two-sided overrides.
4. **Validation and fallbacks.** Large master materials (layer blends,
   functions, vertex-colour masks) defeat tracing, so results are checked and
   gaps are filled from names:
   - a base colour or normal must use RGB and must not be a mask, noise,
     variation, height or packed map; a normal map must not be the base
     colour;
   - packed maps are recognised by parameter or texture name first: `ORM`,
     `ORMH`, `ORMA`, `ARM`, `OcclusionRoughnessMetallic` (AO R, roughness G,
     metallic B), `RMA`, `MRA`, `RHAOM` (roughness R, AO B, metallic A);
   - single maps are picked by score: texture names ending in the slot keyword
     beat parameter names, and masks, noise, detail and blend textures are
     never picked;
   - an emissive that just reuses the base colour texture is dropped (in
     practice that's an emissive mask with intensity 0);
   - inputs that read an alpha channel containing no data (all opaque) are
     dropped. Foliage maps in the UE5 pack had no alpha, and reading metallic
     from it made leaves fully metallic, and therefore black.
5. **Godot side:** masked blend → alpha scissor (opacity mask packed into the
   base colour's alpha if it comes from another texture), translucent/additive
   → alpha, two-sided or foliage shading → no culling, unlit → unshaded, and
   DirectX normal maps flipped on import.

The result is an approximation of the Unreal look, not a port of the shader.
Effects that only exist in the graph (vertex-colour blending, world-aligned
textures, wind, parallax) are lost.

## Oodle and the ab-ooz helper

Almost all UE5 source payloads are compressed with **Oodle Kraken** (method 3,
compressor 3). Oodle is proprietary and there's no pure-Python decoder, so
Asset Bridge uses [ooz](https://github.com/powzix/ooz), an open-source
reimplementation of the Kraken/Mermaid/Selkie/Leviathan decoders.

[`tools/ooz-helper/build.sh`](../tools/ooz-helper/build.sh) downloads ooz at a
pinned commit, replaces its Windows-only header with
[`compat.h`](../tools/ooz-helper/compat.h), drops its Windows `main()`, and
links its decoder with [`main.cpp`](../tools/ooz-helper/main.cpp) into
`ab-ooz`:

```
ab-ooz [--undelta ROW_BYTES BYTES_PER_PIXEL CHANNEL_BYTES] <in.ucb> <out.bin>
```

It reads a whole `FCompressedBuffer`, decodes each block, and optionally
reverses `TSCF_UEDELTA` (that loop is slow in Python for 64 MB textures).

**License:** ooz is GPL-3.0-or-later, so the built `ab-ooz` binary is too. It
runs as a separate program and the addon doesn't link it, which keeps the
addon's own code free of GPL obligations. The ooz source isn't stored in this
repository; the build script fetches it. Don't ship `ab-ooz` inside a game.
It's an editor-time tool, and `addons/asset_bridge/unreal/` is excluded from
Godot exports by its `.gdignore`.

**Safety:** ooz says it isn't hardened against malicious input. Use it on
content from stores you trust.

## Verified packs

| Pack | Saved by | Result |
|---|---|---|
| Mobile Trees | UE 4.26 | 1 mesh, 3 textures, 3 materials; renders like the same listing's FBX version |
| Underground Tunnel (5.5 GB) | UE 4.26 | 317/317 static meshes, 217 textures, 103 materials |
| Sharur's Normandy Village (3.9 GB) | UE 5.6 | 105 meshes, 178 textures (8 and 16 bit), 93 materials |

Fab often stores packs in UE4 format even when you choose a UE5 engine version,
if the seller built them in UE4.

## Not supported yet

Skeletal meshes and animations, maps (`.umap`) and World Partition actors,
landscapes, foliage and PCG, Blueprints, Niagara, half-float textures, and
cooked packages.
