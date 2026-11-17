# Maintainer notes

These notes cover official Savenest distribution. Contributors only need the [development setup and checks](../CONTRIBUTING.md); no release credentials are required.

## Build boundaries

- `npm run build` produces a local development app for the current architecture under `dist/`.
- `npm run release:electron` stages signed, notarized Apple Silicon, Intel, and universal apps using existing maintainer credentials. It does not publish them.
- `scripts/package-release.sh` builds the retained native app. Electron archives come from `npm run release:electron`; only archives meeting the migration requirements below may be offered through the native Sparkle feed.

Keep local libraries, signing material, credentials, generated archives, and local staging paths out of Git.

Official 0.15.1 builds require `SAVENEST_PRO_CAPTURE_PACKAGE` pointing to a reviewed private `SaveNestProCapture` package, including its `LICENSE` and `THIRD_PARTY_NOTICES.txt`. Set `SAVENEST_MCP_PACKAGE_PATH` or `SAVENEST_MCP_BINARY` for the existing Pro MCP adapter. An existing released MCP binary may be reused with its original notices after verifying its archive checksum and signature. Record both public and private source revisions and component hashes with the staged release. Never commit the private module or capture experiments to this public repository.

All three `arm64`, `x64`, and `universal` archives are mandatory. Set both private component paths before a real release; `--plan` does not require credentials or private components.

## Official Electron distribution

1. Complete the relevant checks in [CONTRIBUTING.md](../CONTRIBUTING.md) and review the [preview acceptance checklist](preview-acceptance.md). Passing build checks does not establish installed-app migration, Intel runtime, or update behavior.
2. Keep `package.json`, `package-lock.json`, and `Resources/Info.plist` versions consistent, with an increasing native build number. Add release notes under `Resources/ReleaseNotes/`.
3. Preview the exact inputs and stages without credentials: `npm run release:electron:plan`. This is read-only: no snapshots, locks, caches, signing, network calls, or child builds are created. On the release machine, set `SIGNING_IDENTITY` and `NOTARY_PROFILE` to existing credentials, then run `npm run release:electron`. Never commit their values or key material.
4. The command freezes tracked and nonignored untracked `Sources/`, `Tests/`, `Resources/`, `electron/`, `scripts/`, lockfiles, and license inputs into a content-fingerprinted snapshot outside synced folders. Optional `SAVENEST_MCP_PACKAGE_PATH` or `SAVENEST_MCP_BINARY` inputs are frozen with their notices too; changing either rejects old reuse. The reviewed `SAVENEST_PRO_CAPTURE_PACKAGE` source and its license/notices are frozen the same way, and its commit and fingerprint are recorded in release provenance and the Swift cache key. Installed `node_modules` are reused through a symlink after the lockfile, its root version, and every pinned dependency are verified. Other source/MCP/capture symlinks are rejected because a frozen snapshot must not follow mutable links. It prepares the UI bundle, reader licenses, and icon once, runs `npm test` and `swift run -c debug SaveNestChecks` from the frozen snapshot (with an isolated Swift scratch outside sync) before any signing, builds arm64 and x64 concurrently (use `--jobs=1` when troubleshooting), then requires and notarizes universal only after both architecture ZIPs validate. Every final ZIP is checked with `check-electron-package.mjs` automatically. Stage timings and `release.json` provenance (source fingerprint, original commit/dirty state, toolchain, per-artifact hash and size) are written under `build/releases/electron/<version>/`.
5. Rerun the same command to resume. Verified completed stages are skipped only when the snapshot fingerprint, release identity, archive hash, and canonical checkpoint all match. Pending notarizations reuse the exact submitted ZIP; a pending or completed release keeps its signed helper, prepared MCP binary, and generated UI assets, and fails explicitly if they disappear rather than rebuilding different bytes. Swift scratch caches persist under `~/Library/Caches/SaveNest/release/caches` (or `RELEASE_WORK_DIR`) and are keyed by Swift toolchain, architecture, configuration, and `Package.resolved`. Concurrent releases are rejected by a lock; recover an interrupted one with `RELEASE_RECOVER_LOCK=1` only after confirming no release process is active. `RELEASE_OUTPUT_DIR` routes snapshot builds back to the canonical release directory.
6. Validate all three staged ZIPs with `node scripts/check-electron-package.mjs <zip-path> <architecture>`, using `arm64`, `x64`, and `universal` respectively. Artifacts and metadata are staged under `build/releases/electron/<version>/`. The universal app combines the two verified releases and receives its own signature and notarization. To add it to an existing release, run `node scripts/package-electron-universal.mjs <release-directory>` with the existing signing configuration; input archives are checked against their artifact metadata and remain unchanged.
7. Use the publication commands below to draft and publish the verified ZIPs to the matching GitHub release. Use the universal ZIP for the email's single Mac download button. After the public archives exist, publish each architecture's `RELEASES.json` to `/downloads/electron/<architecture>/RELEASES.json` on the website. The updater continues to use the smaller architecture-specific archives. Follow the additional native migration checks below before changing the Sparkle feed. Never overwrite a published version's archive.
8. Verify public downloads and update metadata, then record installed-app results in the [release issue](https://github.com/dmytroomelian/savenest/issues/18). Keep untested items open.

Signing and packaging use frozen snapshots and persistent caches outside synced Desktop/iCloud folders, where file-provider metadata can invalidate signatures. The command records the local staging path beside the artifacts; it is not a public asset. Archives and manifests are never silently overwritten when provenance or bytes differ.

### Publication automation

Use the publication tool after `npm run release:electron` has produced the tested `arm64`, `x64`, and `universal` ZIPs under `build/releases/electron/<version>/`. It never builds, signs, notarizes, tags, deploys, or replaces a published asset. `gh` must already be authenticated; the tool stores no credentials.

1. Plan. This is the default and is strictly read-only: it makes no remote changes and creates no logs, state, or temporary files. It verifies the manifest, tag/commit provenance, all three ZIP hashes/sizes, and the existing `artifact.json` files. Expensive archive extraction, signature checking, and `check-electron-package.mjs` evidence are deferred to `--draft`, `--publish`, and `--verify`.

   ```sh
   npm run release:publish -- --plan
   npm run release:publish -- --plan --release-dir build/releases/electron/0.12.4
   ```

2. Create or update the GitHub draft. Uploads only missing assets; an existing asset resumes only when its size and sha256 digest match. A mismatch, missing digest, or ambiguous upload stops without replacing anything. Notes are passed with `--notes-file`.

   ```sh
   npm run release:publish -- --draft --notes-file Resources/ReleaseNotes/0.12.4.md
   ```

   A dirty manifest may be inspected with `--plan`, but `--draft`, `--publish`, and `--verify` require `source.dirty: false` and a tag/commit matching `release.json` (`v<version>`). The tool does not commit or retag; reconcile the source and tag first. If the local tag is absent, the draft targets the manifest commit; GitHub creates the tag only when the release is promoted.

3. Promote deliberately. Public promotion is a separate invocation and never uploads assets.

   ```sh
   npm run release:publish -- --publish
   ```

4. Verify public bytes and stage the feeds. This action first requires a public release whose tag/commit and all three asset digests match `release.json`. It then downloads the exact URLs `https://github.com/dmytroomelian/savenest/releases/download/v<version>/SaveNest-<version>-macOS-<arch>.zip` and compares sha256 and size for all three ZIPs. Only if all three match does it copy the existing `arm64` and `x64` `RELEASES.json` files into the supplied website root.

   ```sh
   npm run release:publish -- --verify --website-dir /path/to/savenest-website
   ```

   `--website-dir` must be an existing static-public-root that already contains `downloads/` (for example the checked-out website repository root). The tool writes only `downloads/electron/<arch>/RELEASES.json`; it does not deploy the website or edit the native Sparkle appcast. Keep the separate native-to-Electron migration checks above before changing that feed. If the root is missing, pass the correct checkout path rather than guessing; the tool never infers one.

Publication state is `.publish-state.json` beside `release.json`. It records only versions, commits, hashes, URLs, and local paths so an interrupted draft can resume. Move it aside only after confirming an older publication is obsolete. `release.json` is never modified.

The default repository is `dmytroomelian/savenest`; use `--repo` only for a deliberate alternative. All `gh` calls use argv arrays, never shell interpolation.

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

The [launch tracker](https://github.com/dmytroomelian/savenest/issues/13) is the source for rollout status. Publishing a preview does not mark full launch complete.
