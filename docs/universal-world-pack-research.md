# Universal World Pack Research

## Goal

Use one downloadable PCK per world for all client platforms:

- Web
- Windows
- macOS
- Linux
- iOS
- Android

The workflow should avoid separate platform-specific world-pack exports.

## Result

Yes, one universal world-pack flow is valid in Godot 4.6.3 for this project.

The key requirement is not "use the Web preset". The real requirement is:

1. The world-pack export preset must include both texture families:
   - `texture_format/s3tc_bptc=true`
   - `texture_format/etc2_astc=true`
2. The project must keep both texture-import settings enabled so imported VRAM textures actually generate both variants:
   - `rendering/textures/vram_compression/import_s3tc_bptc=true`
   - `rendering/textures/vram_compression/import_etc2_astc=true`

With those enabled, one exported `World Pack - <world>` PCK can serve both desktop-class and mobile/Web-class texture formats.

## Why This Works

Godot's importer generates platform texture variants when a texture is imported in VRAM-compressed mode and the project import settings allow both format families.

Relevant Godot source:

- `editor/import/resource_importer_texture_settings.cpp`
  - `should_import_s3tc_bptc()`
  - `should_import_etc2_astc()`
- `editor/import/resource_importer_texture.cpp`
  - generates `.s3tc.ctex` and `.etc2.ctex` variants when `compress/mode == COMPRESS_VRAM_COMPRESSED`
- `editor/export/editor_export_platform.cpp`
  - includes matching `path.<feature>` remaps in the exported PCK based on export features
- `platform/web/export/export_plugin.cpp`
  - Web preset exposes desktop/mobile VRAM feature flags
- `editor/export/editor_export_platform_pc.cpp`
  - PC preset exposes `texture_format/s3tc_bptc` and `texture_format/etc2_astc`

## Important Finding

The old split was not harmless for future real assets.

During the research spike, a temporary VRAM-compressed probe texture was placed
inside `server/worlds/hub/` and exported through the old split presets:

- old `World Pack - hub` exported only the desktop `s3tc` variant
- old `Web World Pack - hub` exported both `s3tc` and `etc2`

After enabling `texture_format/etc2_astc=true` on `World Pack - hub`, the pack
became byte-for-byte identical to the Web version.

That showed the split was only covering a preset configuration difference, not
a true engine limitation.

## Chosen Project Rule

Use only one world-pack preset family:

- `World Pack - hub`
- `World Pack - left_world`
- `World Pack - right_world`
- `World Pack - top_world`

Each of these is now the universal world-pack preset.

For deployment:

- export universal packs once into `builds/world_packs/`
- mirror those same files into `builds/web/world_packs/` for static hosting

This keeps:

- one source-of-truth pack build
- editor PackRat testing simple
- Web hosting layout unchanged
- native and Web clients on the exact same downloadable world files

## Validation Performed

Research:

- Godot docs:
  - exporting PCKs
  - Web export
  - feature tags
- Godot source review in:
  - `C:\Programming_Files\Godot\godot-master`

Testing:

1. Compared current native/world and web/world PCKs for the existing tiny
   worlds.
   - They were already byte-identical.
2. Added temporary probe textures that forced VRAM platform variants.
3. Exported old native/world and old web/world packs.
   - Confirmed native-only vs dual-format difference.
4. Enabled both texture families on the `World Pack - hub` preset.
5. Re-exported and compared hashes.
   - Native/world and web/world became byte-identical.
6. Added ongoing artifact verification that now enforces:
   - project import settings keep both VRAM families enabled
   - every `World Pack - <world>` preset keeps both texture families enabled
   - the hosted web copies remain byte-for-byte mirrors of the source packs

The current shipped worlds are still intentionally tiny and do not yet include
committed imported texture content, so the automated guardrail today enforces
the export configuration rather than re-running the temporary probe experiment
inside CI on every build.

## Recommendation

Keep the universal-pack workflow.

Do not reintroduce separate Web world-pack presets unless a future Godot bug or platform-specific resource edge case is reproduced with evidence.
