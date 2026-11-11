# Signed preview acceptance

Version 0.11.1/build 35 is the published preview, following 0.11.0. It prepares an in-app migration from native Savenest 0.10.0/build 33 through Sparkle 2.10.0. Isolated Apple Silicon archive installation has passed; full installed-app acceptance remains pending. Keep the full launch open until the following checks pass in a separate macOS user account or VM with a disposable library. Do not use a person's primary library or Keychain to fill a testing gap.

## What automated checks establish

- Clean-clone CI installs dependencies, runs core checks and Electron tests, and compiles the native app without production credentials.
- Temporary-file tests verify real library write/read equality, Unicode and notes, archive state, damaged-file preservation, and rejection of future format versions.
- Legacy JSON fixtures verify older optional fields can be decoded. They do not test an installed-app migration.
- Electron smoke tests run the real UI and helper with sample data. Preview writes are in memory, so they do not establish disk persistence or offline import/export.
- Release validation checks architectures, matching app/helper versions and numeric builds, Sparkle public-key continuity, signatures, notarization tickets, Gatekeeper, bundled licenses, and rejection of tampered resources. Package validation alone does not test the native Sparkle archive installer.

## Native migration archive checks

- [x] Verify each final 0.11.1 ZIP has build 35 in the outer app and helper, preserves the existing `SUPublicEDKey`, and has a valid archive EdDSA signature from the existing Sparkle key. Check its size and hash against the published artifact.
- [x] Test feed selection with the installed native Sparkle 2.10.0 implementation. The arm64 item must come first with `hardwareRequirements` set to `arm64`; the x64 fallback follows. Both items use build 35. `minimumUpdateVersion` 33 accepts native 0.10.0/build 33; build 32 selects preserved native build 33. Apple Silicon hardware eligibility was real; Intel eligibility was simulated.
- [x] On Apple Silicon, use an isolated signed copy of the distributed native app to exercise archive download, signature validation, installation and replacement. Verify the installed app's version, build, architecture and signature.
- [ ] Repeat archive installation on Intel hardware. Do not infer Intel runtime behavior from Apple Silicon or simulated feed eligibility.

Verified on 2026-11-03, Apple Silicon, macOS 27.0: Sparkle 2.10 downloaded, authenticated and replaced an untouched signed copy of native 0.10.0/build 33 with the final 0.11.1/build 35 archive. The resulting outer app and helper passed version, build, public-key, signature, notarization, Gatekeeper and architecture checks. A corrupted EdDSA signature was rejected and left the old copy intact. Both published ZIP hashes match their validated artifacts, and the live Sparkle and Electron feed bytes match the packaged source. The installed native app also downloaded the public Apple Silicon update and reached **Ready to Install**. The test target was disposable; app relaunch was disabled, updater preferences were isolated, and the real app, library and Keychain were untouched. This is an archive-installation test, not a full runtime migration test.

An isolated archive-installation result does not verify a person's library, Keychain account, browser permissions, or signed-out offline import/export. Keep the checks below open until separately observed in the installed app. The migration requirements are detailed in [maintainer notes](maintainers.md#native-to-electron-preview-migration).

## Remaining manual checks

- [ ] In the isolated account, create a disposable library using the previously distributed native app. Include notes, Unicode, tags, collections, favorites, archived items, and custom shortcuts. Export a backup.
- [ ] Install the matching signed preview through **Check for Updates…** in native 0.10.0 using the prepared migration feed. Confirm every field and shortcut survives. Restart and compare the library and exported data. Also verify the manual fallback with the old app quit before replacement.
- [ ] With a disposable test account, verify existing Keychain credentials and account access after migration. Check browser permissions and regrant access if macOS requests it. Do not use a primary account to replace this isolated check.
- [ ] While signed out, block network access and save/edit/delete/undo local items. Import and export through the native file dialogs; restart and verify persisted data. Repeat with an unsubscribed test account when one is available.
- [ ] Exercise browser capture with permission allowed and denied. Pause history and verify indexed history disappears. Check that unsaved browser activity is absent from the exported library.
- [ ] Observe requests in the isolated environment. Turn anonymous reporting off, create events, and verify no further usage transmissions occur; compare actual requests to the published policy.
- [ ] Run the Intel build on Intel hardware or an appropriately configured environment. Architecture/signature checks alone are insufficient.
- [ ] After native migration, install a newer signed Electron build through its Squirrel feed. Confirm signature rejection for invalid updates, explicit restart, draft protection, and library preservation. Confirm the embedded helper does not start Sparkle. Only the prepared, validated migration archives may appear in the native feed.

Record version, architecture, OS version, steps, result, and issue links. Check off only observed results. [Release issue #18](https://github.com/dmytro-omelian/savenest/issues/18) and [launch tracker #13](https://github.com/dmytro-omelian/savenest/issues/13) track the remaining work.
