# LightCraft Mobile

LightCraft for iPhone and iPad: a mobile host and, as the work goes on, a touch-first UI for
[LightCraft](https://github.com/storytold/lightcraft), the open-source, non-destructive photo library
and raw developer written in pure Rust. The engine (decode, develop pipeline, GPU rendering, catalog,
commands) is LightCraft's own; this repository adds the iOS app and its build.

- Plan and phases: [docs/ios/PLAN.md](docs/ios/PLAN.md)
- Build and install on your phone: [docs/ios/BUILD.md](docs/ios/BUILD.md)
- App crate: [apps/lightcraft-ios](apps/lightcraft-ios)

Based on LightCraft by the ArtCraft team, at upstream commit `8d9016a`. Licensed MIT OR Apache-2.0
(LICENSE-MIT, LICENSE-APACHE, NOTICE). The ArtCraft name and marks in `docs/brand/` are not covered by that
license; see [docs/brand/LICENSE-brand.txt](docs/brand/LICENSE-brand.txt) before sharing builds.

The upstream README is kept in [docs/upstream/README.md](docs/upstream/README.md).
