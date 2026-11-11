# Savenest for Mac

Save links. Keep the context. Find them again with **⌘O**.

Savenest is a macOS launcher with a free, open-source core for saved links, notes, open browser tabs, and recent history. Local saving, search, reading, and import/export work without an account or subscription. Optional Pro integrations are separate.

[Download](https://savenest.app/download) · [Website](https://savenest.app) · [Contribute](CONTRIBUTING.md) · [Report a bug](https://github.com/dmytro-omelian/savenest/issues/new?template=bug.yml)

[![Checks](https://github.com/dmytro-omelian/savenest/actions/workflows/checks.yml/badge.svg)](https://github.com/dmytro-omelian/savenest/actions/workflows/checks.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

![Savenest launcher with commands, open tabs, and saved pages using sample data](docs/assets/launcher.png)

## What it does

- Search saved links, notes, tags, open tabs, and recent browser history in one place.
- Save the current page, selected tabs, or a whole window with keyboard shortcuts.
- Add notes and tags while saving; reopen a page or switch to its existing tab.
- Read a page beside its Obsidian Markdown note, with Original view by default and optional Reader.
- Organize links with favorites and an archive, and import or export JSON backups.

Press **⌘O** to open the launcher, **Enter** to open a result, and **⌘K** for actions. See the [user guide](docs/user-guide.md) for shortcuts and browser support.

## Pro AI connections — 0.13.0

Use your saved links in Codex and Claude. The local MCP integration exposes selected links and quick notes, library organization, and permitted tab actions. Each connection has its own revocable permissions; closing tabs without saving requires a separate permission. Article text and external Obsidian files are excluded.

In a Pro-enabled build, open **Settings → AI connections** and choose **Connect** on the Codex, Claude Desktop, or Claude Code card. Savenest verifies Pro and installs the local setup with saved-library reading only. Use **Manage** to allow more actions or disconnect. Manual configuration and repair are under **Advanced setup**.

The 0.13.0 release adds MCP with online Pro verification and Savenest running on the same Mac as the AI client. Shared records reach the connected AI provider; AI-client costs are separate. Codex tool calls are verified on sample data. Claude Code connection and tool discovery are verified; a complete AI workflow has not been verified. Claude Desktop setup is available, but its compatibility is unverified. See [MCP setup, compatibility, and release checks](docs/mcp.md).

## Invite a friend — 0.13.1

Open **Account & Pro → Invite a friend** to send an invitation. A friend new to paid Savenest gets their first monthly Pro payment for **$1.99**, then **$4.99/month**, before applicable tax. After they pay, you get one **$3 discount** on eligible monthly Pro. Yearly plans are excluded; each account gets at most one discounted month across both roles. See the [user guide](docs/user-guide.md#invite-a-friend) for redemption and expiry details.

## Try the app

Get the current signed app from the [download page](https://savenest.app/download) for **macOS 14+**, on Apple Silicon or Intel. Pro AI connections are included in 0.13.0.

This is still a preview. Installed-app migration, offline import/export, live browser permissions, Intel runtime, and real update checks remain open. See the [acceptance checklist](docs/preview-acceptance.md). Before upgrading, export a backup. Native 0.10.0 can install this preview through **Savenest → Check for Updates…**. Quit the old app first only when installing manually.

## Run a development preview

You need **macOS 14+**, **Node.js 22.12+** with npm, and **Apple's command-line tools with Swift 5.9+**. If Apple's tools are missing, run `xcode-select --install` first.

```sh
git clone https://github.com/dmytro-omelian/savenest.git
cd savenest
npm ci
npm run preview
```

Preview builds the Swift helper and opens Electron with sample data. It does not read your browser history, write your library, register global shortcuts, or send analytics. No account, server setup, or Apple signing credentials are needed.

For normal app behavior, `npm start` uses your real library. Quit other Savenest copies and export a backup first.

## Contribute

Bug reports, documentation, accessibility improvements, and small fixes are welcome. Start with [open issues](https://github.com/dmytro-omelian/savenest/issues), or report a reproducible problem. For a larger change, discuss the user problem in an issue before coding.

The [contribution guide](CONTRIBUTING.md) covers forking, the code layout, checks, and pull requests. Maintainers handle official releases; contributing does not require packaging or publishing the app.

For code changes, run the checks used by CI:

```sh
swift run SaveNestChecks
npm test
npm run build:native
```

For launcher or process-integration changes, also run `npm run test:smoke`. It exercises Electron and the Swift helper with sample data.

## Privacy and project scope

The free app keeps saved links and notes local. With Pro, the signed-in app automatically saves your library to your account. Browser history is read without modification and kept in memory. An enabled Pro MCP connection shares requested records with the AI client, within the permissions you grant. **Anonymous usage counts are on by default** and can be disabled in Settings or the first-use notice. Icons, account services, update checks, and reporting can make network requests. Read the [privacy policy](docs/privacy.md) for details.

This repository contains the Electron app, Swift helper, and shared automation operations. The hosted backend and private Pro MCP adapter are separate. Public builds remain usable without the private adapter. Savenest Pro automatically saves changes once the signed-in account, service permissions, and local library pass their checks. There is no sync toggle. **Sync is active** shows a green pulse only after a server acknowledgement in the current session and a recent successful status check. Offline and failure states stay non-green and retry every minute.

Each Mac has its own current saved library and latest successful daily recovery copy; changes are not merged between Macs. Recovery remains available for 90 days after Pro access ends. A missing previously known library or corrupt file requires restoration or an explicit **Use this library…** confirmation before automatic saving resumes. A confirmed restore preserves the previous local bytes and saves the restored library automatically when Pro access is active. Signing out stops new uploads. See [Pro saving and recovery](docs/cloud-backup.md) for limits, safety checks, and release prerequisites.

## Reference

- [User guide](docs/user-guide.md): shortcuts, capture, and browser support.
- [MCP guide](docs/mcp.md): Pro AI connections, permissions, and setup.
- [Launcher design](docs/launcher-design.md): interaction and process boundaries.
- [Preview acceptance](docs/preview-acceptance.md): remaining manual checks.
- [Security reporting](SECURITY.md): report vulnerabilities privately.
- [Maintainer notes](docs/maintainers.md): official distribution and legacy update boundaries.

## License

The desktop core and shared automation operations in this repository use [MIT](LICENSE), which permits use, modification, redistribution, and resale when its notice requirements are met. The private adapter has a separate [Pro MCP component license](docs/pro-mcp-license.md), permitting personal and work use of the official bundled executable with valid Pro access. Hosted services have their own applicable terms. These terms do not restrict MIT code or contributions.

Resale of proprietary paid components or paid service access requires a separate written commercial agreement with the rights holder. See the [licensing policy](docs/licensing.md) for the boundary. Bundled dependency licenses are documented in [third-party notices](THIRD_PARTY_NOTICES.md).
