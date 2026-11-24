# Feature naming

LightCraft uses **Perspective Correction**, **Guided Perspective**, and **Perspective Guides** for its own geometry controls. The section includes Off, Auto, Guided, Level, Vertical and Full modes, so its name does not imply every mode is automatic.

The previous Upright terminology is a naming-review candidate, not a verified finding about trademark registration. These descriptive names are chosen to distinguish LightCraft's own implementation.

## Compatibility boundary

The `geometry.upright`, `geometry.guides` and `tool.guidedUpright` commands, saved tool keys, Rust enum variants and serialized settings remain stable. XMP `crs:PerspectiveUpright` and `UprightTransform_*` mappings and Lightroom import messages still describe the external format accurately. No rendering, import or export logic changes.

All 17 shipped non-English catalogs contain the new labels. The normal CI, perspective-mode tests and a visual panel/tool check remain required before this draft is marked ready.

## Regression coverage

The standard-library-only `display_names` integration tests scan production Rust string literals for the retired display names and preserve explicit compatibility exceptions. They also test identifier, comment and raw-string handling. These focused checks do not replace application or visual testing.

## iOS app name: Silverbath

The iOS app (`apps/latent-ios`) shows the name **Silverbath**, replacing **Latent**: the home-screen name, permission prompts, About, messages, and the app source listing. The Xcode target, bundle identifier (`app.latent.Latent`), source identifier, folder names and code keep `Latent`, so installed copies update in place and nothing stored changes.

- 2026-11-24, check so far: App Store and web searches for "Silverbath" as a photo app found none. The searches also turned up photo apps already named Halationify, Émulsion, Emulsify, Tint and Darkroom, which ruled those names out.
- Still to do before the name goes on the App Store: the USPTO, EUIPO eSearch or TMview, and WIPO Global Brand Database searches the naming standard asks for. Until then, the name is used only in builds distributed through this repository's own source.
