# PostHog for the Mac app

The source is configured for the US-hosted [Savenest PostHog project](https://us.posthog.com/project/573765), shared by the website and Mac app. Existing anonymous counts also go to `savenest.app/api/usage`, so the owner report continues working. This local configuration does not update already installed apps; it takes effect when a configured build is distributed and run.

The project stays on the free plan with separate [Website](https://us.posthog.com/project/573765/dashboard/2335424) and [Mac app](https://us.posthog.com/project/573765/dashboard/2335423) dashboards. Mac events contain the fixed property `surface: "mac"`; website events use `surface: "website"`. Each saved chart filters by its surface and sums `count`. Sharing the project and public token does not create a shared user identity.

## Current project settings

The project settings were checked on November 11, 2026. **Discard client IP data** is enabled (`anonymize_ips: true`), and the reporting timezone is **Europe/Warsaw**. Autocapture, session recordings, automatic errors, console capture, performance capture, heatmaps, and surveys are disabled.

The retention setting currently displays the default 12 months. No custom retention period or deletion schedule has been configured or verified. Do not interpret the displayed default as a verified guarantee that events are deleted after 12 months. PostHog retention is separate from Savenest's existing backend retention.

## Build and release configuration

`Resources/Info.plist` contains the project's public, write-only `phc_` token in `SaveNestPostHogProjectToken` and `https://us.i.posthog.com` in `SaveNestPostHogHost`. Never put a personal or secret API key in these fields. The public token ships inside the app.

Run `swift run SaveNestChecks` and `npm run build:native`. The build copies these fields into the native helper's Info.plist. Electron embeds that helper; changing only Electron's package metadata does not configure analytics. Before distributing a configured build, check the live privacy page and project settings. Verify a deliberate test action in the project's live events and verify opt-out with network inspection. Automated checks intercept requests locally and do not prove live delivery.

The configuration validator accepts only the EU or US PostHog ingestion origin, optionally with a trailing slash. Other hosts, paths, credentials, and query strings are rejected. The region must match the project; there is no implicit region default. Leaving either field blank or invalid disables only PostHog and preserves existing Savenest reporting.

## What is sent

Savenest sends one event per action type present in a batch, with its total in the numeric `count` property. The event names are:

- `app_opened`
- `links_saved`
- `clipboard_saved`
- `note_saved`
- `tags_saved`
- `link_opened`
- `link_copied`
- `links_archived`
- `importance_labeled`

These are the existing action counters. They do not cover every interaction in the reading workspace or Obsidian editor. A count is bounded to 1–1,000 per action per batch. There is no arbitrary event or property API.

Each batch gets a fresh random UUID, used as PostHog's required `distinct_id`. It is not stored on disk or reused across batches. Besides `count` and the fixed `surface: "mac"`, PostHog receives `$process_person_profile: false`, `$geoip_disable: true`, and the nonempty placeholder `$ip: "0.0.0.0"`. No account identity, persistent installation or device identifier, URL, title, note, tag, search query, clipboard content, or local path is included. No autocapture, session recording, feature flag polling, or exception collection is installed.

The placeholder prevents PostHog's ingestion normalization from substituting the connection IP into stored event properties. It does not hide the IP used to make the network connection. Keep **Discard client IP data** enabled as an additional project-level control. A blank `$ip` is not an equivalent substitute: the normalization code treats it as missing.

## Reading the data

Filter the Mac app dashboard to `surface = mac`. For each event, create a trend with the aggregation **Sum of property → count**. For example, one `links_saved` event with `count: 4` represents four saved links. Counting event rows would count one batch contribution instead.

These are best-effort action totals. They do not measure unique people, active users, cross-session funnels, or retention: a fresh batch ID deliberately cannot identify a returning person. Do not interpret PostHog's distinct-ID count as user count. Website and Mac events have no shared user identity.

## Delivery and opt-out

The existing **Share anonymous usage counts** preference governs both destinations. Preview mode sends neither. Turning reporting off clears pending counts, cancels in-flight requests, and discards the ephemeral network session. Requests already received by a service cannot be recalled.

Counts stay in memory and flush approximately once a minute. The Savenest and PostHog requests start independently, so failure at one destination does not prevent the other request. Both use a cookie-free session without a cache or credential store, a ten-second timeout, and rejected redirects. There is no persistent queue, retry history, or guaranteed shutdown delivery. Offline activity and short sessions may be missed; reporting never blocks saving.

## Setup verification — November 11, 2026

The configured payload builder produced one synthetic `app_opened` event with `count: 1` and `surface: "mac"`. A deliberate setup request was accepted by PostHog, and both saved Mac dashboard charts returned 1. This verifies configuration and ingestion, not telemetry from an installed app.

The website integration and updated privacy page are live at `savenest.app` (Sites version 84, source `d78bc159ddefe62022db8f268051c0a398017701`). Deliberate browser page views and a download-link click reached the Website dashboard. After opting out, returning home produced no analytics request in the observed server logs. Website unit/runtime tests, typecheck, and production build passed. Setup evidence is in `build/posthog-configured/setup-verification.json`.

Swift checks and an isolated native build passed. The local Apple Silicon package is `build/posthog-configured/SaveNest-0.12.3-PostHog-local-arm64.zip`; its bundled configuration and extracted signature were verified. It is ad-hoc signed, not notarized, installed, launched, or published. The isolated build excluded only the three pre-existing duplicate `* 2.swift` files; the original workspace files remain untouched. See `build/posthog-configured/local-build-verification.json` for the hash and build evidence. Existing users still need a configured release.

## References

- [PostHog capture and batch API](https://posthog.com/docs/api/capture)
- [PostHog data storage, IP controls, and retention](https://posthog.com/docs/privacy/data-storage)
- [PostHog ingestion IP normalization](https://github.com/PostHog/posthog/blob/master/nodejs/src/common/utils/event.ts)
- [PostHog tests preserving an explicitly supplied IP property](https://github.com/PostHog/posthog/blob/master/nodejs/src/ingestion/common/steps/event-processing/normalize-event-step.test.ts)
