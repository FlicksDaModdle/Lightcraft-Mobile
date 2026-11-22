# Building and installing on your iPhone

The app is built by GitHub Actions on a macOS runner (`.github/workflows/ios.yml`). You don't need
Xcode on your own machine to get an installable `.ipa`; you need an Apple Developer account for the
certificate and provisioning profile.

## One-time setup

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

Push to `main` or run the **iOS** workflow by hand (Actions → iOS → Run workflow). The first build
takes a long time (the whole engine compiles); later ones reuse the cache. The artifact
`LightCraft-iOS` holds `LightCraft.ipa`. Without the secrets the workflow still compiles the app and
uploads an unsigned zip, which can't be installed but proves the build.

## Installing

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
