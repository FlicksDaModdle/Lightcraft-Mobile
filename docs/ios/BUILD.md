# Latent: the SwiftUI iPhone and iPad app

Latent is a SwiftUI app over the LightCraft engine:

- `apps/latent-core` (crate `lightcraft-latent`) is the engine bridge: a static library with a small
  C interface (`include/latent.h`): open the library, run any engine command (JSON in, JSON out),
  render a photo or thumbnail to RGBA with its histogram. Every edit is an engine command, as in the
  desktop app. Its `ffi` module is allowed `unsafe` for the C pointers (a departure from the
  repository's Rust-only and no-`unsafe` rules, recorded here; it is registered in `xtask` like
  `crates/iospicker`).
- `apps/latent-ios` is the Swift app (XcodeGen spec `project.yml`). `build.sh` builds the bridge
  for `aarch64-apple-ios`, generates the Xcode project and builds `Latent-unsigned.ipa`.
- CI (`.github/workflows/ios.yml`) uploads that IPA as the `Latent-iOS` artifact. Install it with
  Sideloadly or AltStore, which sign it with your Apple ID.

Latent keeps its library in its own Documents folder (shown in the Files app); photos you add are
copied into `Documents/Import` first.

The sections below describe the earlier egui phone app (`apps/lightcraft-ios`), which is still in
the repository and still checked on Linux, but no longer packaged by CI.

# Building and installing on your iPhone

The app is built by GitHub Actions on a macOS runner (`.github/workflows/ios.yml`). You don't need
Xcode on your own machine: CI produces an `.ipa`, and either a signing tool or CI itself signs it.

## Quick way: no secrets (Sideloadly or AltStore)

Nothing to configure. Push to `main` or run the **iOS** workflow by hand (Actions → iOS → Run
workflow), then download the `LightCraft-iOS` artifact and unzip it to get `LightCraft-unsigned.ipa`.
Install it with [Sideloadly](https://sideloadly.io) or AltStore, which sign it with your Apple ID
(free or paid) as they install. On the phone: Settings → General → VPN & Device Management → trust
the developer, and turn on Developer Mode if asked (Settings → Privacy & Security).

A free Apple ID's signature lasts 7 days (re-sign then; AltStore can do it automatically); a paid
account's lasts a year. The first build takes a long time; later ones reuse the cache.

## Signed in CI: with your certificate

If you'd rather have CI produce a signed `LightCraft.ipa` that installs directly, set it up once:

1. **Register your device** (Apple Developer → Certificates, Identifiers & Profiles → Devices) with
   its UDID.
2. **Create an App ID** for the app, e.g. `com.yourname.lightcraft` (Identifiers → App IDs).
3. **Create a certificate**: *Apple Development* (or *Apple Distribution* for an Ad Hoc profile).
   Export it from Keychain Access as a `.p12` with a password.
4. **Create a provisioning profile** for that App ID, certificate and device: *iOS App Development*
   (or *Ad Hoc*). Download the `.mobileprovision`.
5. **Add repository secrets** (Settings → Secrets and variables → Actions → Secrets):

   | Secret | Value |
   |---|---|
   | `IOS_CERT_P12` | `base64 -i certificate.p12 \| pbcopy` |
   | `IOS_CERT_PASSWORD` | the `.p12` password |
   | `IOS_PROVISION_PROFILE` | `base64 -i profile.mobileprovision \| pbcopy` |

   The bundle identifier is read from the profile. Only for a wildcard profile (`TEAMID.*`) add a
   repository **variable** `IOS_BUNDLE_ID` (Variables tab) with the identifier to use.

## Building

Same as above: the artifact `LightCraft-iOS` then holds a signed `LightCraft.ipa`.

## Installing a signed build

Any of these work with a development or ad hoc profile that lists your device:

- **Xcode** → Window → Devices and Simulators → select the phone → **+** → choose `LightCraft.ipa`.
- **Apple Configurator** → drag the `.ipa` onto the device.
- **Sideloadly** or similar tools, signing with the same account.

On the phone: Settings → General → VPN & Device Management → trust your developer certificate (the
first time), and turn on Developer Mode if iOS asks (Settings → Privacy & Security).
Development profiles expire after a year (ad hoc too); rebuild before then.

## Running on a desktop (development)

`cargo run -p lightcraft-ios` opens the same app in a phone-sized window; `-- --memory` keeps the
session in memory and writes nothing. UI work can be tried and screenshot-tested this way before it
goes to a device.

## Memory

iOS ends apps that use too much memory. The app limits its caches to an eighth of the RAM (192 to 768
MiB). For big raw files, add the *Increased Memory Limit* capability to the App ID and regenerate the
profile; the app then has more room.

## Getting photos in and out

- **+** in the library opens the iPhone's Photos picker (several photos at once). Chosen photos are
  copied into the app's **Import** folder and added to the library. If the picker cannot open, the
  app falls back to adding whatever is already in that folder.
- **Export** on the photo screen writes `<name>-edit.jpg` into the **Exports** folder.

Both folders show in the Files app (On My iPhone > LightCraft).

The picker lives in `crates/iospicker`, which is allowed `unsafe` for its Objective-C calls (like
`crates/sysmem`). That departs from the AGENTS.md note on where `unsafe` may live; it is registered in
`xtask/src/roots.rs` and `xtask/src/layers.rs`.
