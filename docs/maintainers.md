# Maintainer notes

These notes cover official SaveNest distribution. Contributors only need the [development setup and checks](../CONTRIBUTING.md); no release credentials are required.

## Build boundaries

- `npm run build` produces a local development app for the current architecture under `dist/`.
- `npm run release:electron` stages signed, notarized Apple Silicon and Intel apps using existing maintainer credentials. It does not publish them.
- `scripts/package-release.sh` builds the retained native app. Electron archives come from `npm run release:electron`; only archives meeting the migration requirements below may be offered through the native Sparkle feed.

Keep local libraries, signing material, credentials, generated archives, and local staging paths out of Git.

## Official Electron distribution

1. Complete the relevant checks in [CONTRIBUTING.md](../CONTRIBUTING.md) and review the [preview acceptance checklist](preview-acceptance.md). Passing build checks does not establish installed-app migration, Intel runtime, or update behavior.
2. Keep `package.json`, `package-lock.json`, and `Resources/Info.plist` versions consistent, with an increasing native build number. Add release notes under `Resources/ReleaseNotes/`.
3. On the release machine, set `SIGNING_IDENTITY` and `NOTARY_PROFILE` to existing credentials, then run `npm run release:electron`. Never commit their values or key material.
4. Validate both staged ZIPs with `node scripts/check-electron-package.mjs <zip-path> <architecture>`, using `arm64` and `x64` respectively. Artifacts and metadata are staged under `build/releases/electron/<version>/`.
5. Publish verified ZIPs to the matching GitHub release. After the public archives exist, publish each architecture's `RELEASES.json` to `/downloads/electron/<architecture>/RELEASES.json` on the website. Update download links and architecture choices together. Follow the additional native migration checks below before changing the Sparkle feed. Never overwrite a published version's archive.
6. Verify public downloads and update metadata, then record installed-app results in the [release issue](https://github.com/dmytro-omelian/savenest/issues/18). Keep untested items open.

Signing uses a temporary workspace outside synced Desktop/iCloud folders, where file-provider metadata can invalidate signatures. The packaging script records this local staging path beside the artifacts; it is not a public asset.

## Update safety

Electron checks and downloads updates only when requested. Installation/restart requires confirmation and a fresh check that no launcher or native draft is active. Squirrel verifies the downloaded app's signing identity. The Swift helper's Sparkle updater is disabled in Electron builds.

Settings sends manual checks to the Electron host and receives its current status. Its button is available independently of the standalone native automatic-check preference; only an active check/download temporarily disables it. A plain Settings window does not block restart, but its unfinished field edits, shortcut recording, sheets, and Account view do. Failed installation restores the launcher without stopping the helper. Development and preview hosts never contact the release feed.

The native Sparkle feed and Electron's Squirrel feeds remain separate update formats. The native feed may offer the prepared 0.11.1 preview as a one-time migration into Electron, subject to the requirements below. Subsequent Electron updates use Squirrel; neither the outer Electron app nor its embedded helper starts Sparkle.

Both interfaces use the same library path and Keychain services; startup rejects a second library writer. These implementation choices do not establish installed-app preservation. Full migration acceptance remains pending. Recommend an export backup before either an in-app or manual upgrade. For manual installation, quit the existing app before replacement.

## Native-to-Electron preview migration

Version 0.11.1, native build 35, is the prepared migration target. Isolated Apple Silicon archive installation and corrupted-signature rejection passed; the [preview checklist](preview-acceptance.md) records the evidence and remaining acceptance scope. Do not treat archive installation as proof of library or account preservation.

Only newly prepared archives that meet all of these conditions are eligible:

- The outer app and embedded helper have `CFBundleShortVersionString` of `0.11.1` and the same numeric `CFBundleVersion` of `35`. The numeric build preserves ordering after native 0.10.0/build 33.
- Both bundles preserve the existing trusted `SUPublicEDKey`. Retain the existing Sparkle signing key; never generate a replacement for this release.
- Each final signed and notarized ZIP has a valid Sparkle EdDSA archive signature made with that existing key. Verify the signature against the trusted public key and use the matching archive size and URL in its enclosure. A valid Apple code signature or notarization ticket alone is insufficient for the native update.
- Architecture, bundle versions, key continuity, signatures, notarization, and tamper rejection pass for the final bytes. Do not reuse or rewrite the published 0.11.0 archives as migration artifacts.

Prepare `https://savenest.app/downloads/appcast.xml` with the Apple Silicon item first and `<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>`. Place the Intel archive second as the fallback item. Both items use `sparkle:version` 35, short version 0.11.1, and their own archive signature and size. Preserve this ordering and verify selection with the installed Sparkle 2.10.0 implementation. The optional `<sparkle:minimumUpdateVersion>33</sparkle:minimumUpdateVersion>` can limit the migration offer to the known native 0.10.0 build and later; retain a supported path for older installations.

Before publishing the migration items, use an isolated copy of the distributed native app to check feed selection, signature validation, archive installation, and the resulting app's version, build, architecture, and signature. Record the exact Sparkle version and results. This check establishes archive replacement only: it does not establish real library preservation, Keychain continuity, browser permissions, offline use, or import/export. Those require the separate installed-app acceptance checks. Manual download remains a fallback.

The [native reference](legacy-native.md) documents the older interface and updater.

The [launch tracker](https://github.com/dmytro-omelian/savenest/issues/13) is the source for rollout status. Publishing a preview does not mark full launch complete.
