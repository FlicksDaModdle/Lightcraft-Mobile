# Silverbath

<img src="apps/latent-ios/Latent/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" alt="Silverbath app icon: a drop falling into a silver bath" width="120" align="right">

Silverbath is a non-destructive photo editor and raw developer for iPhone and iPad (iOS 26 and later), with a
Liquid Glass interface. Everything runs on the device: your photos, faces and places never leave it.

It is built on [LightCraft](https://github.com/storytold/lightcraft), the open-source photo library and raw
developer written in pure Rust. The engine (raw decoding, the develop pipeline, GPU rendering, the catalog and
its commands) is LightCraft's; this repository adds the SwiftUI app, the bridge between them, and the build.

## Install

Add this source to Feather, AltStore or SideStore:

```
https://raw.githubusercontent.com/FlicksDaModdle/silverbath/altstore/source.json
```

Every push to `main` builds the app in CI and publishes the new version to that source. To build it yourself,
see [docs/ios/BUILD.md](docs/ios/BUILD.md).

## What it does

**Editing**
- Light, color, curves, color mix and color grading, detail, optics, geometry with automatic straightening,
  effects, vignette and grain, and Glow (bloom, diffusion, halation, motion and streak).
- Profiles and LUTs (import your own `.cube` files), presets and your own looks.
- Masks: brush, linear and radial gradients, color and luminance ranges, depth range, and AI selection of
  objects, subjects, sky and people, combined and refined.
- Remove: heal, clone and AI remove of distractions.
- Lens blur from a depth map (from the camera or estimated), with a focus range you drag, a sharp area you move,
  and bokeh shapes.
- Noise reduction and AI denoise.
- Crop with ratios and social sizes, straighten, flip and rotate.
- Before and after split view, histogram with clipping warnings, versions, full history, and a toggle to turn
  each section of edits off and on.

**Library**
- Your camera roll at a glance (with a RAW tag on raw photos), and a library of the photos you bring in.
- Ratings, flags, albums and smart albums, keywords, stacks, search.
- People: faces found and grouped on the device for you to name.
- Places: a map of where photos were taken, with town and country filled in offline.
- Edit several photos at once: paste edits, apply presets, export.

**Making more**
- HDR, panorama and HDR panorama merge.
- Slideshows, saved as video.
- Export to JPG, PNG, TIFF, AVIF or JPEG XL, in several color spaces, with HDR, watermarks and presets.

## Optional AI models

Some features use models you download from Settings or when you first use them. Each runs on the device.

| Feature | Model | Licence |
| --- | --- | --- |
| Depth (lens blur, depth masks) | Depth Anything V2 Small, Apple's Core ML conversion | Apache-2.0 |
| AI remove | Big LaMa (Core ML) | Apache-2.0 |
| Object selection | SAM 2.1 Small, Apple's Core ML conversion | Apache-2.0 |
| AI denoise | NAFNet SIDD width 32 (megvii-research), converted by this repository's Models workflow | MIT |
| People | YuNet face detector and SFace recogniser (OpenCV Zoo) | MIT, Apache-2.0 |
| Place names | GeoNames cities list | CC-BY 4.0 |

## Repository

- iOS app (SwiftUI): [apps/latent-ios](apps/latent-ios)
- Bridge from the app to the engine (Rust, C interface): [apps/latent-core](apps/latent-core)
- Engine crates: [crates](crates)
- Builds: [.github/workflows/ios.yml](.github/workflows/ios.yml) (app and source) and
  [.github/workflows/models.yml](.github/workflows/models.yml) (the converted AI denoise model)

Inside the code the app is still called Latent (its folders, target and bundle identifier), so installed copies
keep updating in place.

## Licence

Silverbath is based on LightCraft by the ArtCraft team. Licensed MIT OR Apache-2.0 (LICENSE-MIT,
LICENSE-APACHE, NOTICE). The ArtCraft name and marks in `docs/brand/` are not covered by that licence; see
[docs/brand/LICENSE-brand.txt](docs/brand/LICENSE-brand.txt). Third-party assets and their sources are listed in
[assets/ATTRIBUTION.md](assets/ATTRIBUTION.md).

The upstream README is kept in [docs/upstream/README.md](docs/upstream/README.md).
