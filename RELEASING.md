# Releasing Chromastage (Sparkle + GitHub Releases)

This repo uses Sparkle 2 for auto-updates and GitHub Releases for distribution.
The app is configured to read its feed from:

```
https://github.com/voctory/chromastage/releases/latest/download/appcast.xml
```

## Prereqs

- Xcode 15+.
- `gh` CLI authenticated for `voctory/chromastage`.
- Developer ID Application signing identity for release distribution.
- Optional notarization credentials (see `Scripts/sign-and-notarize.sh`).

## One-time Sparkle key setup

Sparkle uses an ed25519 keypair. The private key lives in your login keychain,
the public key is stored in `Chromastage/Info.plist` as `SUPublicEDKey`.

Build the Sparkle CLI tools (from the SPM checkout) and generate keys:

```
xcodebuild -project Build/SourcePackages/checkouts/Sparkle/Sparkle.xcodeproj -scheme generate_keys -configuration Release -derivedDataPath Build/SparkleTools build
Build/SparkleTools/Build/Products/Release/generate_keys
```

Copy the printed `SUPublicEDKey` value into:

```
Chromastage/Info.plist
```

## Release steps

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in:
   `Chromastage/Info.plist`
2. Build and sign (notarization optional):

```
./Scripts/sign-and-notarize.sh
```

This outputs `Chromastage-<version>.zip` and `Chromastage-<version>.dmg`.

3. Build Sparkle appcast tool (one-time per machine):

```
xcodebuild -project Build/SourcePackages/checkouts/Sparkle/Sparkle.xcodeproj -scheme generate_appcast -configuration Release -derivedDataPath Build/SparkleTools build
```

4. Generate `appcast.xml` from the release zip:

```
VERSION=0.1
TAG="v${VERSION}"
mkdir -p dist/sparkle
cp -f "Chromastage-${VERSION}.zip" dist/sparkle/
Build/SparkleTools/Build/Products/Release/generate_appcast \
  --download-url-prefix "https://github.com/voctory/chromastage/releases/download/${TAG}/" \
  -o dist/sparkle/appcast.xml \
  dist/sparkle
```

5. Publish the GitHub Release (assets must include the appcast):

```
gh release create "${TAG}" \
  "Chromastage-${VERSION}.zip" \
  "Chromastage-${VERSION}.dmg" \
  dist/sparkle/appcast.xml \
  --title "${TAG}" \
  --notes "Release ${VERSION}."
```

Because the app uses the `latest` feed URL, uploading `appcast.xml` to the
latest release is enough for updates to work.

## Updating an existing release

If you need to re-point a tag or replace assets:

```
git tag -f "${TAG}"
git push -f origin "${TAG}"
gh release upload "${TAG}" dist/sparkle/appcast.xml --clobber
```

If your environment blocks `git push -f`, you can update the tag via the API:

```
gh api -X PATCH "repos/voctory/chromastage/git/refs/tags/${TAG}" \
  -F sha="$(git rev-parse HEAD)" \
  -F force=true
```

## Commands used for the v0.1 release (Feb 7, 2026)

```
xcodebuild -project Build/SourcePackages/checkouts/Sparkle/Sparkle.xcodeproj -scheme generate_keys -configuration Release -derivedDataPath Build/SparkleTools build
xcodebuild -project Build/SourcePackages/checkouts/Sparkle/Sparkle.xcodeproj -scheme generate_appcast -configuration Release -derivedDataPath Build/SparkleTools build
Build/SparkleTools/Build/Products/Release/generate_keys
Scripts/sign-and-notarize.sh
mkdir -p dist/sparkle
cp -f Chromastage-0.1.zip dist/sparkle/
Build/SparkleTools/Build/Products/Release/generate_appcast --download-url-prefix "https://github.com/voctory/chromastage/releases/download/v0.1/" -o dist/sparkle/appcast.xml dist/sparkle
gh release create v0.1 Chromastage-0.1.zip Chromastage-0.1.dmg dist/sparkle/appcast.xml --title "v0.1" --notes "Sparkle-enabled release."
gh release edit v0.1 --target fe45d0a7e45410295e35dc3efc1b4da9a3ed02e3
gh api -X PATCH repos/voctory/chromastage/git/refs/tags/v0.1 -F sha=fe45d0a7e45410295e35dc3efc1b4da9a3ed02e3 -F force=true
```
