# Contributing

Thanks for helping. Asset Bridge gets better mostly through real-world packs
that don't convert well, so reports are as valuable as code.

## Reporting a pack that converts badly

Store content is copyrighted. **Don't attach paid or licensed assets, converted
files or screenshots of them to issues.** Instead, include:

- where the asset comes from: store, listing name or URL, and the format you
  downloaded (Unity, FBX, GLB, Unreal + engine version);
- the command or dock settings you used;
- the JSON result, or at least `units`, `stats`, `warnings`, `errors` and `hints`;
- what looks wrong, e.g. "base colour is a noise texture", "leaves are black",
  "door is mirrored";
- for Unreal content, the output of `tools/uasset-dump` for the material or mesh
  involved (property names and structure are fine to share).

Free assets (e.g. Fab's free listings) are the best examples, because anyone can
download them to reproduce the problem.

## Changing code

1. Read [docs/how-it-works.md](docs/how-it-works.md) and [CLAUDE.md](CLAUDE.md)
   (the rules there apply to everyone).
2. Keep the addon compatible with Godot 4.3, and the Python converter to the
   standard library.
3. Add a synthetic fixture (`tests/make_fixtures.py`) or a unit test
   (`tests/test_uasset.py`) for new behaviour.
4. Run the tests:

   ```bash
   GODOT=/path/to/godot tests/run.sh
   ```

5. For anything visual, render before and after with `tests/render_scene.gd`
   (see [docs/development.md](docs/development.md#visual-checks)).
6. Update the docs that describe the behaviour you changed.

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE). Don't contribute code copied from GPL or proprietary
projects (including ooz or Unreal Engine source). The Oodle helper stays a
separately built program.
