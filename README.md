# Chromastage

Native macOS music visualizer with Apple Music control and system audio capture.

## Highlights

- Apple Music playback control + now-playing info.
- Optional Spotify integration (metadata only).
- Live shader visuals with favorites/blocked lists and playlists.
- Lyric sync offset adjustments.
- Built on the Butterchurn visualizer engine.

## What it looks like

- (Add screenshots or short clips here.)

## Requirements

- macOS 13+ (ScreenCaptureKit).
- Xcode 15+ (recommended).

## Build & Run

### Xcode

1. Open `Chromastage.xcodeproj`.
2. Select the `Chromastage` scheme and run.

### Command Line

```sh
xcodebuild -project Chromastage.xcodeproj -scheme Chromastage -configuration Debug -derivedDataPath Build build
open Build/Build/Products/Debug/Chromastage.app
```

## Signing & Notarization

Use the release script (modeled after `../codexbar` and `../trope-mac`) to build, sign, notarize, and zip:

```sh
./Scripts/sign-and-notarize.sh
```

Notes:
- The script **requires a Developer ID Application identity** (Apple Development is not valid for notarized distribution).
- Set `ARCHES="arm64 x86_64"` to force a universal build (default).
- Notarization credentials (pick one):
  - `NOTARYTOOL_PROFILE`: created via `xcrun notarytool store-credentials`.
  - `APPLE_ID`, `APPLE_ID_PASSWORD`, `TEAM_ID`: Apple ID + app‑specific password.
  - `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, and `APP_STORE_CONNECT_API_KEY_P8` (or `APP_STORE_CONNECT_API_KEY_PATH`).
- The script **skips notarization by default** unless credentials are provided.
- The script outputs `Chromastage-<version>.zip` and `Chromastage-<version>.dmg` (with an `/Applications` link) by default.
- Use `--skip-dmg` if you only want the zip.
- When notarization is enabled, the script staples and validates the ticket.
- To force sign-only (even if credentials are present), use `./Scripts/sign-and-notarize.sh --skip-notarization`.

## Permissions

- Screen Recording: required for system audio capture (System Settings → Privacy & Security → Screen Recording).
- Automation: allow control of Apple Music when prompted.

## Engine Development

The Butterchurn engine lives in this repo. To rebuild the bundled web visualizer:

```sh
pnpm install
node scripts/build-chromastage-iife.mjs
```

The app loads the engine from:

```
Chromastage/Resources/Visualizer/butterchurn.iife.js
```

## Presets

Preset sources are stored in `PresetsSource/`. To regenerate curated and combined preset JSON files:

```sh
node scripts/build-presets-json.mjs
```

Outputs are written to:

```
Chromastage/Resources/Presets
```

## Notes

- Some protected streams can be muted by the system capture APIs.
- This app is a standalone macOS project; the engine retains Butterchurn naming.

## Troubleshooting

- No audio or visuals: Confirm Screen Recording permission is enabled for Chromastage.
- Apple Music controls unavailable: Approve the Automation prompt for Apple Music.
- Spotify not available: Install Spotify, then enable it in Settings → Music Sources.
- Presets missing: Run `node scripts/build-presets-json.mjs` to regenerate.
- Visualizer out of date: Run `node scripts/build-chromastage-iife.mjs` to rebuild the engine bundle.

## License

MIT. Original Butterchurn code: © 2013–2018 Jordan Berg. Chromastage: © 2026 Victor Vannara.
