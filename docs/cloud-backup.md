# Savenest Pro backup and restore

The desktop integration is implemented locally. It is not a published release, and the default production website does not acquire cloud routes from these changes alone. Account migration, server deployment, paid entitlement verification, and a real signed-in end-to-end check are release prerequisites.

## Product behavior

All local saving, search, organization, import, export, and quick notes continue working offline and without an account. Signing in alone does not upload a library.

Savenest Pro cloud backup is explicitly enabled for the signed-in account on each Mac. The confirmation explains which content leaves the device. A verified Pro subscription and server-side upload permission are both required. Saving a local change schedules a backup after a three-second debounce. Failed requests retry while the app remains open; an unchanged pending snapshot keeps its ID, so a lost response does not create a duplicate upload. Unchanged libraries do not generate another backup request.

Each Mac has its own stream of snapshots. This is backup and restore, not automatic merging or live multi-Mac sync. The server retains up to 30 daily copies per device and supports up to five devices per account. The latest snapshot's retention is managed by account entitlement, not a blanket object expiration rule. After the subscription expires, the server can allow restoration for 90 days without permitting new uploads.

Turning backups off stops subsequent uploads; a request already accepted by the server may have completed. Signing out or switching accounts revokes the previous account's local opt-in. Restarting the app with the same account can resume an existing opt-in. Tokens remain in native account transport and macOS Keychain; neither tokens nor database credentials enter the Electron renderer.

If the library file is missing or cannot be loaded at startup, saved cloud opt-ins are revoked and a persistent review flag pauses automatic backup. Creating a new local library or restarting the app does not clear that flag. The user must explicitly restore a backup or confirm enabling backups for the current library. This prevents an empty replacement library from silently replacing the last useful cloud copy.

## Included content and limits

The version 1 snapshot contains the library version, collections, and saved links with their IDs, web URLs, titles, icon URLs, browser names, creation dates, quick notes, tags, favorite/archive flags, and importance choices. It excludes Obsidian Markdown files, offline article contents, browser history, cookies, credentials, device paths, and app preferences.

- Maximum encoded snapshot: 2 MiB. This leaves room for API Gateway's JSON event escaping inside Lambda's invocation limit.
- At most 10,000 links and 1,000 collections, subject to the total size limit.
- URL, title, and icon URL: at most 8,192 UTF-8 bytes each. Quick note: 65,536 bytes.
- Browser and collection names: at most 500 bytes each. Up to 100 tags of 200 bytes each.
- URLs must be HTTP(S), without credentials, ASCII whitespace, or control characters. Icon URLs follow the same rule.
- Collections must be nonblank and unique, and every link must refer to an existing collection. Duplicate link IDs and equivalent URLs are rejected. Strings cannot contain NUL.
- Wire dates use UTC ISO 8601, including milliseconds on upload. UUIDs are compared as UUIDs; server lowercase canonicalization is supported.

Limits reject a backup rather than silently removing links or truncating notes. Local data remains unchanged.

## Safe restore

The account screen lists available snapshots and identifies this Mac versus another Mac. Selecting Restore downloads and validates the snapshot. A native confirmation shows the backup date and the before/after link counts.

The restore path rechecks account/session identity and local content after the download and after confirmation. It also compares a fingerprint of the exact on-disk bytes before replacement. A changed library cancels restoration instead of overwriting later edits. Raw-byte checks also protect malformed files that cannot be decoded.

Before the atomic replacement, the exact original library bytes are saved to `~/Library/Application Support/SaveNest/Cloud Recovery/before-restore-<UUID>.json`. The recovery directory is created with mode 0700 and the file with 0600. Failure to preserve the recovery copy aborts replacement. The account screen offers **Show recovery copy** after a successful restore. Undo state is cleared because it belongs to the previous library.

Restoration turns automatic backup off. The user must explicitly enable it again after reviewing the restored library. Obsidian files and offline articles are not changed. A damaged library can be restored through this flow: the exact damaged bytes are preserved first, and the local write restriction clears only after successful replacement. If the file cannot be read at all, restore stops rather than discarding it.

## Endpoint configuration and contract

`AccountController` continues using the existing account origin. Backup requests default to `https://savenest.app` as well. A release can set the trusted bundle `Info.plist` string `SaveNestCloudBaseURL` to a different HTTPS origin after authentication compatibility is verified. The origin must have no credentials, query, fragment, or non-root path. User defaults, renderer messages, imported snapshots, and environment variables cannot redirect bearer credentials. Redirect responses are not followed.

The native client uses these authenticated JSON endpoints:

- `GET /api/cloud/status`: `{ enabled, canUpload, canRestore, retentionEndsAt, snapshots }`.
- `POST /api/cloud/snapshots`: snapshot body; response `{ snapshot: summary }`.
- `GET /api/cloud/snapshots/:id`: response `{ snapshot: payload }`.

A payload is `{ version: 1, deviceId, snapshotId, createdAt, library }`. A summary is `{ id, deviceId, createdAt, linkCount, byteCount }`; its creation time is authoritative server time. The server must derive ownership and paid access from authentication, never from a client account ID. Server storage keys and signed object URLs are not exposed to the client.

## Verification

`swift run SaveNestChecks` includes payload boundary checks, supported/unsupported dates and schema versions, duplicate links, unsafe URLs and icons, NUL handling, collection coherence, payload limits, missing-library automatic-backup policy, stale restore rejection, exact recovery-byte preservation, damaged-file recovery, missing-file recovery, recovery permissions, and failure to write a recovery copy.

For a cross-language contract check, set `SAVENEST_CLOUD_FIXTURE_PATH` to an output path when running the checks. The resulting synthetic snapshot contains Swift-encoded UUIDs, ISO dates, icon and importance metadata, Unicode tags, and a quoted multiline quick note. Validate it with the server's `validateSnapshot` function. It contains no user library data.

A passing local test or preview does not verify a live authenticated upload, entitlement check, account isolation, or recovery from deployed storage. Those require a controlled end-to-end test before release.

## Private AWS acceptance build

Run `bash scripts/build-aws-beta.sh` to build `~/Applications/SaveNest AWS Beta.app`. This is a standalone native acceptance app using the same account and backup controllers as the Electron helper. It is not a packaged Electron rollout or a public release. The finalized beta bundle is installed under the user’s Applications directory because macOS excludes temporary-directory applications from URL-handler resolution even when their scheme appears registered. Quit the private beta before rebuilding it. It opens Account with the test address filled in; email confirmation and PKCE remain required.

The bundle identifier is `app.savenest.aws-beta`. Only this bundle can use the pinned `SaveNestAccountBaseURL` for the Stockholm AWS deployment; production bundles retain `https://savenest.app`. The private bundle uses `savenest-beta://auth/callback`, which is normalized only after matching its private scheme. The regular state and PKCE validation still apply. Its AWS backend must select the matching trusted `NATIVE_CALLBACK_SCHEME`.

Its data is isolated:

- Library and account/library locks: `~/Library/Application Support/SaveNest AWS Beta/`.
- Recovery copies: that directory's `Cloud Recovery/` child.
- Keychain service: `app.savenest.aws-beta.account`.
- Preferences: the beta bundle's own defaults domain.
- Reader notes and icon caches: beta-specific directories.

It does not claim production global shortcuts or start clipboard monitoring at launch. Analytics and automatic updates are disabled. Backups remain off until explicit opt-in. The build script snapshots sources outside the working tree and excludes pre-existing duplicate `* 2.swift` files without deleting them from the checkout.

For the November 11 acceptance run, a new beta library was seeded with two synthetic public links, notes, and tags. The production library was not imported. The native build, signature check, 40 core checks, and focused backend-origin/callback isolation checks passed. Actual sign-in, subscription, backup, and restore results must be recorded separately after exercising the app.
