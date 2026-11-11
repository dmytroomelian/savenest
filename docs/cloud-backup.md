# Savenest Pro cloud sync, backup and restore

These notes describe automatic Pro saving and recovery prepared for Savenest 0.12.6. They are release preparation, not a publication announcement. The behavior requires backend migration `003-library-sync.sql`, the matching AWS service, and the rebuilt Mac app. Backend deployment, paid entitlement checks, and signed-in end-to-end acceptance must be verified before publishing the app.

## Product behavior

All local saving, search, organization, import, export, and quick notes continue working offline and without an account. Automatic remote saving requires a signed-in, currently verified Pro account and server upload permission.

Savenest Pro starts automatically when the signed-in account has verified Pro access, the service is available, the server allows uploads, and the local library is healthy and requires no recovery review. There is no normal enable or pause toggle. Adding, editing, deleting, importing, or undoing saved library content schedules a sync after a three-second debounce. The current library is saved atomically in PostgreSQL, separately from the recovery backup. Failed requests retry every minute while the app remains running; the local library persists unsent changes across restart. An unchanged pending request keeps its ID, content, and revision precondition, so a lost response does not create a duplicate write. Unchanged libraries do not repeatedly sync during the same session.

Each Mac has its own current cloud library and recovery backup; changes are not merged between Macs. The server creates an initial backup, then replaces it about once every 24 hours from the current database copy, even while the app is closed. The scheduler checks every 15 minutes, so the daily interval is approximate and may be longer after a service failure or backlog. A delayed retry keeps its original capture time, allowing a fresh catch-up backup after a long outage. The immediate-backup endpoint can request a replacement even when the library has not changed; the ordinary app UI does not expose a backup control. The server keeps one successful recovery backup per Mac, across up to five Macs. It uploads and commits the new backup before retiring the previous backup; failed object deletion is retried by cleanup. Existing historical backups are preserved until a successful replacement. Retention is managed by account entitlement, not a blanket object expiration rule. After the subscription expires, restoration remains available for 90 days without permitting new uploads.

Signing out stops subsequent uploads from this Mac; a request already accepted by the server may have completed. Account or session changes discard acknowledgements and pending requests from the previous session. Signing in with verified Pro access starts saving automatically once the same health and server-permission checks pass. Daily server backups continue from the last saved cloud library while the subscription is active. Tokens remain in native account transport and macOS Keychain; neither tokens nor database credentials enter the Electron renderer.

A first installation may start with a new, healthy empty library. A previously known library that is missing, or any library that cannot be loaded, instead sets a persistent recovery-review flag. Restarting or creating a replacement local file does not clear that flag. The user must restore a saved copy or explicitly confirm **Use this library…** before the current library can replace the previously saved copy. A corrupt library must be successfully loaded or restored first.

## Status indicator

The normal Pro status is **Sync is active** with a green pulse. It appears only after the server acknowledges a current-library send in the current account session, Pro access is freshly verified, and recent service status still permits uploads. The status response must be less than 150 seconds old. Merely signing in, subscribing, or restoring a cached account does not show green.

Checking, offline, failure, recovery review, and restoration states are not green. The pulse respects Reduce Motion. Status is refreshed and eligible failures retried every 60 seconds while the app runs; unsent changes remain in the local library. Recovery details and exceptional **Use this library…** confirmation stay inside **Restore library**, rather than becoming normal sync controls.

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

The account screen keeps recovery actions inside **Restore library**. Available copies identify this Mac versus another Mac. Selecting **Restore…** downloads and validates the copy. A native confirmation shows its date and the before/after link counts.

The restore path rechecks account/session identity and local content after the download and after confirmation. It also compares a fingerprint of the exact on-disk bytes before replacement. A changed library cancels restoration instead of overwriting later edits. Raw-byte checks also protect malformed files that cannot be decoded.

Before the atomic replacement, the exact original library bytes are saved to `~/Library/Application Support/SaveNest/Cloud Recovery/before-restore-<UUID>.json`. The recovery directory is created with mode 0700 and the file with 0600. Failure to preserve the recovery copy aborts replacement. The account screen offers **Show recovery copy** after a successful restore. Undo state is cleared because it belongs to the previous library.

Restoration suspends uploads while it runs. A successful, explicitly confirmed restore clears the recovery-review flag and automatically saves the restored library when verified Pro access and server upload permission are still available. Restoration during the 90-day recovery period remains local when new uploads are no longer allowed. Obsidian files and offline articles are not changed. A damaged library can be restored through this flow: the exact damaged bytes are preserved first, and the local write restriction clears only after successful replacement. If the file cannot be read at all, restore stops rather than discarding it.

## Endpoint configuration and contract

`AccountController` continues using the existing account origin. Backup requests default to `https://savenest.app` as well. A release can set the trusted bundle `Info.plist` string `SaveNestCloudBaseURL` to a different HTTPS origin after authentication compatibility is verified. The origin must have no credentials, query, fragment, or non-root path. User defaults, renderer messages, imported snapshots, and environment variables cannot redirect bearer credentials. Redirect responses are not followed.

The native client uses these authenticated JSON endpoints:

- `GET /api/cloud/status`: `{ enabled, canUpload, canRestore, retentionEndsAt, snapshots, libraries }`.
- `POST /api/cloud/library`: snapshot body with `If-Match: <previous revision UUID>` or `none`; response `{ library: revisionSummary }`. This atomically replaces the current database copy, including deletions.
- `POST /api/cloud/snapshots`: explicit immediate backup body; response `{ snapshot: summary }`.
- `GET /api/cloud/snapshots/:id`: response `{ snapshot: payload }`.

A revision summary is `{ id, deviceId, updatedAt, linkCount, byteCount }`. An unchanged retry uses the original request ID and `If-Match`; HTTP 412 holds automatic sync for an explicit review or refresh. The client does not silently overwrite a concurrently changed cloud revision. Status decoding remains compatible with older servers for recovery, but sync requires the new endpoint.

A payload is `{ version: 1, deviceId, snapshotId, createdAt, library }`. A summary is `{ id, deviceId, createdAt, linkCount, byteCount }`; its creation time is authoritative server time. The server must derive ownership and paid access from authentication, never from a client account ID. Server storage keys and signed object URLs are not exposed to the client.

## Verification

`swift run SaveNestChecks` includes add/edit/delete sync state, edits made during an upload, stable retry IDs and preconditions, explicit unchanged-library backups, old/new status response decoding, payload boundary checks, supported/unsupported dates and schema versions, duplicate links, unsafe URLs and icons, NUL handling, collection coherence, payload limits, missing-library automatic-backup policy, stale restore rejection, exact recovery-byte preservation, damaged-file recovery, missing-file recovery, recovery permissions, and failure to write a recovery copy.

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

It does not claim production global shortcuts or start clipboard monitoring at launch. Analytics and automatic updates are disabled. Pro saving starts automatically after the isolated account passes the same entitlement, server-permission, and local-library checks. The build script snapshots sources outside the working tree and excludes pre-existing duplicate `* 2.swift` files without deleting them from the checkout.

An earlier November 11 acceptance run used two synthetic public links, notes, and tags without importing the production library. Its native build, signature check, 40 core checks, and focused backend-origin/callback isolation checks passed. Those earlier results do not verify the 0.12.6 automatic-saving flow. Record current sign-in, automatic upload, status indicator, failure recovery, daily replacement, and restore acceptance separately before release.
