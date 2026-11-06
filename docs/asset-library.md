# Publishing to the Godot Asset Library

Ready-to-paste values for submitting Asset Bridge at
https://godotengine.org/asset-library/asset/submit (requires a Godot Asset
Library account). Submissions are reviewed by moderators.

| Field | Value |
|---|---|
| Asset name | Asset Bridge |
| Category | Tools |
| Godot version | 4.3 |
| Version | 0.1.0 |
| Repository host | GitHub |
| Repository URL | https://github.com/SeriousMt/Unity-Unreal-to-Godot-Asset-Bridge |
| Issues URL | https://github.com/SeriousMt/Unity-Unreal-to-Godot-Asset-Bridge/issues |
| Download commit | the commit hash of the `v0.1.0` tag |
| License | MIT |
| Icon URL | a 128×128 PNG in the repository (raw GitHub URL); not created yet |

Description:

> Import Unity packages, Fab and Leartes Cosmos downloads, plain FBX/OBJ/glTF +
> texture folders, and (experimental) uncooked Unreal Engine assets into Godot.
> Converts materials, models, Unity prefabs and scenes (colliders, lights,
> nested prefabs, rigged characters with animations) and Unreal textures, static
> meshes and materials, without Unity or Unreal installed. Includes an editor
> dock and a headless command line with JSON output for scripts, CI and AI
> agents. Python 3 is needed for Unreal content; UE5-saved content also needs a
> small optional decompressor built from source.

The Asset Library installs the repository's `addons/` folder into the user's
project, which is exactly what's needed.

Before submitting:

1. Push the `v0.1.0` tag and create a GitHub release from it.
2. Add an icon (128×128 PNG) and, ideally, a screenshot of the dock and of
   converted assets you made yourself. **Don't use renders of store assets.**
3. Make sure CI is green on the tagged commit.
