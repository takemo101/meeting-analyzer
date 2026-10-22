# Verifying a built artifact (DMG, app bundle, release)

Open the artifact itself. A successful build or a script exit code is not acceptance.

- **Integrity**: check the published checksum with `shasum -a 256 -c`; mount the DMG (`hdiutil attach`) and list the contents (the `.app`, bundled licences or notices).
- **Signature and target**: `codesign -dvvv` (Identifier, Signature, TeamIdentifier, flags), `codesign --verify --strict`, `lipo -archs`, `otool -l` for `LC_BUILD_VERSION` (minos, sdk), and `plutil -p` on Info.plist (bundle ID, versions, minimum OS). State the signing kind (ad-hoc vs Developer ID) from real output.
- **Launch**: run the mounted/copied bundle with an isolated home and confirm the window, audio/IO and the settings location work. Do not touch the user's real settings.
- **Gatekeeper**: `spctl --assess` gives an assessment, but **setting `com.apple.quarantine` by hand does not reliably reproduce the warning that a browser-downloaded file produces** (it may launch with no dialog), and `curl` downloads carry no quarantine attribute. The wording of the warning and the approval steps in your install notes are "unconfirmed" until a file downloaded through a browser is opened on a clean Mac.
- **Build environment**: a local build and a CI build differ (Xcode/SDK, deployment target), so they are not the same binary. Download the CI artifact and run the same checks on it; a local result does not stand in for it.
- **Published release**: fetch the public URL without authentication and compare the checksum. Tag-triggered or manual workflow runs are separate evidence; record the run IDs.
