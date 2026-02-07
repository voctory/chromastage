# Release Signing, Notarization, and Updates

- **Signing** uses a **Developer ID Application** identity and is sufficient for local testing and internal distribution.
- **Notarization** submits the signed app to Apple’s notary service and **requires credentials** (notarytool profile or Apple ID/app-specific password, or App Store Connect API key).
- The release script `scripts/sign-and-notarize.sh` **defaults to sign-only** unless notarization credentials are provided.
- **Apple Development** identities are **not valid** for notarized distribution; use **Developer ID Application**.
- Sparkle updates are published via GitHub Releases; appcast is `appcast.xml` attached to the latest release.
- For the full release workflow (Sparkle keys, appcast generation, GitHub release), see `RELEASING.md`.
- Optional wrapper: `scripts/release.sh --version X.Y` (build, appcast, GitHub Release).
