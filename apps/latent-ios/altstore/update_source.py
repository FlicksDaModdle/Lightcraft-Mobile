"""Adds a Silverbath build to the app source (source.json), newest first. The format is AltStore's,
which Feather and other sideloading apps read too; the newest build is also given in the older
app-level fields some of them use.

Run by CI after a build of `main` is published as a GitHub Release:

    python3 update_source.py SOURCE_JSON VERSION BUILD DOWNLOAD_URL SIZE_BYTES

SOURCE_JSON is read if it exists and written back. Keeps the latest builds only.
"""
import datetime
import json
import os
import sys

REPO = "FlicksDaModdle/Lightcraft-Mobile"
RAW = f"https://raw.githubusercontent.com/{REPO}/main/apps/latent-ios"
KEEP = 10

APP = {
    "name": "Silverbath",
    "bundleIdentifier": "app.latent.Latent",
    "developerName": "Silverbath contributors",
    "subtitle": "A raw photo editor, built on the LightCraft engine.",
    "localizedDescription": (
        "Silverbath edits photos on your iPhone and iPad: light, colour, curves, HDR, colour grading, "
        "effects, detail, crop and presets, all non-destructive. Built on the open-source LightCraft "
        "engine; every build of the main branch is published here."
    ),
    "iconURL": f"{RAW}/Latent/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
    "tintColor": "#2978F5",
    "category": "photo-video",
    "screenshots": [],
    "appPermissions": {
        "entitlements": [],
        "privacy": {
            "NSPhotoLibraryAddUsageDescription": "Silverbath saves your edited photos to your library when you ask it to.",
        },
    },
}


def main():
    path, version, build, url, size = sys.argv[1:6]
    source = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            source = json.load(f)
    old = next((a for a in source.get("apps", []) if a.get("bundleIdentifier") == APP["bundleIdentifier"]), {})
    versions = [v for v in old.get("versions", []) if v.get("version") != version]
    versions.insert(0, {
        "version": version,
        "buildVersion": build,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": f"Build {build} of the main branch.",
        "downloadURL": url,
        "size": int(size),
        "minOSVersion": "26.0",
    })
    newest = versions[0]
    app = dict(
        APP,
        versions=versions[:KEEP],
        # the older single-version fields, for readers that look for them
        version=newest["version"],
        versionDate=newest["date"],
        versionDescription=newest["localizedDescription"],
        downloadURL=newest["downloadURL"],
        size=newest["size"],
    )
    out = {
        "name": "Silverbath",
        "identifier": "app.latent.source",
        "subtitle": "Silverbath builds, straight from the repository.",
        "website": f"https://github.com/{REPO}",
        "iconURL": APP["iconURL"],
        "tintColor": APP["tintColor"],
        "apps": [app],
        "news": [],
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
