# LightCraft for iPhone and iPad: plan

Goal: the whole of LightCraft's feature set, in an app that feels made for a phone, with the
phone-first layout and gestures of Adobe's mobile photo editor. (The target is a *style*; we describe
features in our own words and use none of Adobe's names or assets.)

## What we build on

LightCraft is layered (`docs/architecture.md`). Everything below the UI has no windowing dependency:
raw and image decode, the develop pipeline, the wgpu compute twin of it (Metal on iOS), the catalog
and the command registry that every action goes through. The iOS app is a new host (`apps/lightcraft-ios`)
plus, from phase 2, a touch UI over the same commands. Nothing in the engine is forked for it, except
small platform arms (settings and library paths). This tree is a copy of storytold/lightcraft at
`8d9016a`; upstream fixes can be merged in.

**Constraint to design around:** no way of running iOS code where this was written. Every phase is
verified on a desktop (the app runs there in a phone-sized window; the UI has headless screenshots
and tests) and then built by CI for the device. A phase isn't done until it has run on a phone.

## Phases

| # | Phase | Contents | Done when |
|---|---|---|---|
| 0 | **Toolchain** | App crate, iOS bundle and signing in CI, memory budget, settings store | The signed `.ipa` installs and shows the current UI on the phone |
| 1 | **Device integration** | Photo picker (PhotoKit) and Files picker; import into the library (HEIC, raw, JPEG); safe-area insets and keyboard; save on background; export to Photos and the share sheet; open links; draw GPU renders directly (as the desktop does); iPad multitasking | Import from Photos, edit, export back to Photos |
| 2 | **Mobile shell** | Touch-first UI crate over the engine commands: bottom tab bar, photo grid with pinch zoom and multi-select, single photo with swipe, full-screen editor with a bottom tool strip, large sliders (drag, double-tap to reset, tap value to type), hold to see the original, undo/redo, ratings and flags by gesture | Everyday edit loop is comfortable one-handed |
| 3 | **Edit tools** | Light, colour (mixer, grading, point colour), curves, effects, detail, optics, geometry and crop with gestures, presets and profiles, copy and paste edits, auto | Every slider and tool of the desktop app is reachable |
| 4 | **Masking and healing** | Linear, radial, brush, range masks; healing and cloning; subject and sky masks (needs the model, see phase 6) | Local edits by touch and Apple Pencil |
| 5 | **Library** | Albums, smart albums, filters, search, keywords, metadata, stacks, versions, faces, map; iCloud Drive or Files folder as the library location; Lightroom catalog and preset import | Library features of the desktop app |
| 6 | **Heavy features** | AI denoise and AI masks on device (ONNX runtime or Core ML; the desktop uses ONNX), HDR and panorama merge, slideshow and print outputs, background export | Needs a real memory and thermal pass |
| 7 | **Polish and release** | iPad layout, accessibility (VoiceOver), localization, performance, TestFlight | Daily use |

## Phase 1 in detail (next)

- `Services::picker`: present `PHPickerViewController` (photos, original data copied to the library's
  import folder) and `UIDocumentPickerViewController` (files and folders) through `objc2-ui-kit`,
  `objc2-photos-ui`; answer on the channel the desktop picker uses (`pick::PickRequest`).
- Export: the UI writes through `Services::write`; after a write, offer the share sheet
  (`UIActivityViewController`) and *Save to Photos* (`PHPhotoLibrary`).
- Insets: read `ViewportInfo` safe-area insets and pad the layout; keyboard avoidance for text fields.
- Lifecycle: save settings when the app resigns active (winit `Suspended`), not only on a timer.
- Rendering: port the desktop's window-device adoption (`adopt_window_device`) so GPU renders are drawn
  without a read-back.

## Risks

- **Memory.** Raw files are big. Tiled or downscaled processing and the eighth-of-RAM budget are the
  levers; the increased-memory-limit capability helps. The engine already has a memory budget and gates.
- **Models.** `ort`/ONNX Runtime on iOS needs a prebuilt static library; Core ML is the alternative.
- **HEIC.** Pure-Rust decode (`heif` feature) is slower than the system's; ImageIO can be used for
  previews if it matters.
- **Touch UI scope.** The desktop UI is ~47k lines of egui for mouse and keyboard. The mobile shell
  reuses engine commands and view-models, not the panels.
- **Trademarks.** `docs/brand/` holds ArtCraft marks. They may stay in copies of the repository; remove
  them (and the About credits that use them) before distributing the app to anyone else
  (`docs/brand/LICENSE-brand.txt`).
