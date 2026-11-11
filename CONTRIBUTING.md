# Contributing to Savenest

Savenest is a free Mac app for saving and finding browser pages. Bug reports, documentation, accessibility improvements, and code contributions are welcome. This repository contains the MIT-licensed desktop app; the hosted backend is separate.

## Start here

Check [open issues](https://github.com/dmytro-omelian/savenest/issues) for existing work. For a substantial change, open an issue describing the user problem and proposed behavior before coding. Small fixes can go straight to a pull request. You can also help by reproducing a bug with sample data or clarifying a confusing instruction.

Keep discussions respectful and focused on the work. Report security problems privately using [SECURITY.md](SECURITY.md).

Maintainers classify issues by type, area, priority, and any outstanding triage or acceptance needs. See the [issue label policy](docs/issue-labels.md) for definitions and maintenance rules. Reporters do not need to choose labels.

## Set up a development copy

You need macOS 14+, Apple's command-line tools with Swift 5.9+, and Node.js 22.12+ with npm. Install Apple's tools with `xcode-select --install` if they are missing.

1. [Fork the repository](https://github.com/dmytro-omelian/savenest/fork) into your GitHub account.
2. Clone your fork and create a branch. Replace `YOUR-USERNAME` below with your GitHub username.

```sh
git clone https://github.com/YOUR-USERNAME/savenest.git
cd savenest
git switch -c fix/describe-your-change
npm ci
npm run preview
```

`npm run preview` builds the Swift helper and opens Electron with a sample library. Preview does not read real browser history, write your library, register global shortcuts, or send analytics. Start here for UI changes and screenshots.

No account, subscription, server credentials, or Apple signing credentials are needed to contribute. Maintainers handle official releases; contributors do not need to package, sign, notarize, or publish the app.

Use `npm start` only when you need to exercise normal app behavior: it uses your real library. Quit other Savenest copies and export a backup first. Use a separate macOS account or VM with disposable data for migration, permission, and installed-app checks.

## Find the relevant code

| Area | Location |
| --- | --- |
| Launcher UI and keyboard interaction | [`electron/renderer/`](electron/renderer/) |
| Electron windows, process bridge, and updates | [`electron/`](electron/) |
| macOS capture, native dialogs, and app integration | [`Sources/SaveNest/`](Sources/SaveNest/) |
| Library models, search, and browser data | [`Sources/SaveNestCore/`](Sources/SaveNestCore/) |
| Swift and Electron checks | [`Tests/SaveNestCoreTests/`](Tests/SaveNestCoreTests/) and [`electron/tests/`](electron/tests/) |

## Check your change

For code changes, run the same checks as CI:

```sh
swift run SaveNestChecks
npm test
npm run build:native
```

`SaveNestChecks` is this project's core check runner, not an XCTest target. For launcher or process-integration changes, also run `npm run test:smoke`. It drives the real Electron UI and Swift helper with sample data and saves screenshots in `build/`.

For browser capture, tab, or page-context changes, also run the browser fixture checks:

```sh
node scripts/check-metadata.mjs
node scripts/check-tab-close.mjs
node scripts/check-browser-tabs.mjs
node scripts/check-tab-context.mjs
```

Add regression coverage when it can catch a meaningful behavioral failure, especially data loss, authorization, or privacy regressions. Documentation-only changes need link and command review, not a full app build. Report checks you could not run.

Preview and automated checks do not establish real-browser permissions, installed-app migration, or update behavior. See the [preview acceptance checklist](docs/preview-acceptance.md) for those checks.

If Swift reports paths from a previous checkout location, regenerate the disposable `.build` directory. Do not change source paths to match stale build metadata.

## Open a pull request

Push your branch to your fork and open a pull request against `dmytro-omelian/savenest`'s `main` branch. Explain the problem, resulting behavior, and checks actually run. Link a related issue when one exists. Keep the change focused and include screenshots with sample data for visible UI changes.

Preserve local data compatibility and offline use. Do not put local saving, editing, import, or export behind account or subscription checks. Browser history and unsaved page context remain local and ephemeral. Keep renderer isolation and validate all commands crossing process boundaries.

Never commit credentials, real user libraries, browser databases, personal screenshots, signing material, or generated build artifacts.

By submitting a contribution, you confirm you have the right to contribute it under this repository's MIT license. No separate contributor agreement is required.
