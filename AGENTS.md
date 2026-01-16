# Release Signing & Notarization

- **Signing** uses a **Developer ID Application** identity and is sufficient for local testing and internal distribution.
- **Notarization** submits the signed app to Apple’s notary service and **requires credentials** (notarytool profile or Apple ID/app-specific password, or App Store Connect API key).
- The release script `Scripts/sign-and-notarize.sh` **defaults to sign-only** unless notarization credentials are provided.
- **Apple Development** identities are **not valid** for notarized distribution; use **Developer ID Application**.
