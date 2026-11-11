# Pro AI connections through MCP

**Release: 0.13.0 with Pro.** Codex tool calls are verified on sample data. Claude Code connection and tool discovery are verified; a complete AI workflow has not been verified. Claude Desktop setup is available, but its compatibility is unverified. The development checks below distinguish client verification from pending release checks.

Savenest’s MCP connection lets Codex, Claude Desktop, and Claude Code work with saved links and quick notes on your Mac. The AI can find research, organize links, save open tabs, and close selected tabs when permitted. The AI client provides the model and scheduling; Savenest provides the local actions.

## Requirements

- macOS 14 or later and a Pro-enabled Savenest build containing the `savenest-mcp` adapter.
- Savenest running on the same Mac as the AI client.
- A signed-in Savenest account with active Pro access, verified online.
- A compatible AI client with local stdio MCP support. Its account, usage limits, and costs are separate from Savenest Pro.
- macOS Automation permission for the supported browsers you want to manage. Browser history access has its own app and operating-system controls.

Local saving, search, reading, browser tools, and import/export remain free. A public source build can run those tools without the private MCP adapter.

## Connect a client

1. Open **Settings → AI connections** in Savenest.
2. Find the **Codex**, **Claude Desktop**, or **Claude Code** card and choose **Connect**. Savenest verifies Pro, enables the local connection, creates a separate credential, and installs that client’s local configuration.
3. Follow the result shown by Savenest. Restart the AI client or its MCP connection if requested, then ask it to check Savenest’s connection status.
4. Choose **Manage** on the app’s card when you want to allow more actions. A new connection can only read saved links and quick notes. Tabs, history, saving/editing, opening, and destructive actions require an explicit grant.

Normal setup does not require copying configuration or handling credentials. **Manage → Disconnect** revokes that app’s access without affecting other connections. **How it works** explains privacy and runtime requirements and contains **Allow AI connections**, which pauses or resumes all connections on this Mac. Connections start disabled; **Connect** enables them during setup. Public source builds omit the private adapter by default.

### Advanced setup and recovery

**Manage → Advanced setup** contains **Copy configuration**, **Repair setup**, and **Test access**. Use repair if the client’s local setup needs reinstalling. Copy configuration is available for manual configuration and troubleshooting. Test access checks the local credential and Pro verification; it does not prove that the AI client connected successfully.

Each client launches the bundled `savenest-mcp` executable over stdio with `--credential-file` pointing to its own credential file. Standard builds store these at `~/Library/Application Support/SaveNest/AI/<client UUID>.json`; the private beta uses the `SaveNest AWS Beta` directory instead. Keep that file private. Executable and credential-file paths depend on the app’s installation, so use the configuration Savenest generates when doing manual setup.

The adapter talks to the running native helper through an authenticated Unix socket. No hosted MCP endpoint or additional runtime is required. Each AI client has its own credential. Changing a client’s reported name does not grant permissions. Savenest account credentials never appear in client configuration.

## Permissions and data

Permissions cover saved-library reading, open tabs, recent history, saving/editing, opening links, removal, saving then closing tabs, and direct closing. Grant only the actions that client needs. Changes apply to later requests and remaining work; completed actions cannot be recalled by revoking a connection.

Requests expose titles, URLs, tags, collections, favorites/archive state, and quick notes. History remains read-only. Article bodies, live page text, and external Obsidian Markdown files are excluded. Returned records become part of the AI conversation and may reach the AI provider. Your provider’s terms and account settings govern its processing and retention. See [Privacy](privacy.md).

The app checks connection permissions and Pro access for every data or action request. It reuses its current 120-second subscription-verification lease and refreshes expired verification. When renewal fails, MCP access pauses until verification succeeds. Free app tools continue working. Disconnecting or cancelling Pro does not delete the local library.

## What to ask

- **Find research:** “Find my saved links about authentication. Include the quick notes for the three closest matches.”
- **Organize links:** “Show this month’s untagged research. Add the project tag to the links I select.”
- **Save and close:** “Save these research tabs with the tag `project-notes`, then close the tabs that saved successfully.”
- **Direct closing:** “Close these selected tabs without saving.” This requires the separate direct-closing permission.
- **Scheduled shortlist:** “Every Friday, find five links I saved this week and explain why I might revisit them, using their titles and notes.” Set up the schedule in the AI client.

Scheduled work needs an awake Mac, running Savenest, a running local AI client, online Pro verification, and the relevant permissions. The AI client may still require its own tool approvals. Savenest does not wake the computer or provide a scheduler.

## Tools and limits

| Tool | Purpose |
| --- | --- |
| `get_status` | Inspect connection, Pro verification, permissions, and browser availability. |
| `search_links` | Search metadata and quick notes; filter saved links, permitted tabs, or recent history. |
| `get_links` | Read selected records and complete quick notes. |
| `add_links` | Save URLs with optional titles, notes, tags, and collections. |
| `update_links` | Change selected saved links without replacing omitted fields. |
| `remove_links` | Remove selected saved records. |
| `open_links` | Focus an existing tab or open a selected URL. |
| `save_tabs` | Save selected tabs and optionally close each after a successful save. |
| `close_tabs` | Close selected tabs without saving when authorized. |
| `undo_change` | Undo the latest eligible library change using its operation token. |

Search defaults to saved links, 50 results per page, and a maximum page size of 100. Mutations accept at most 20 explicit targets. Each action returns completed, skipped, or failed results for its targets. Search does not change the launcher’s query, selection, or focus.

Saving an existing URL returns its saved record without overwriting notes or tags. Edits and removals require the record’s current revision. If the record changed after the client read it, the client must fetch it again before retrying. A repeated mutation request ID reuses its result within the running app session; it is not a durable retry guarantee after a restart.

Live-tab references differ from saved-link IDs. Tabs are checked again before closing. Changed, ambiguous, or unavailable targets stay open. A save-and-close action closes only successfully saved or already-saved targets. Direct closing does not create a backup. Reopening a URL cannot recover form state or guarantee restoration of the original tab.

Library undo is limited to the latest eligible mutation. Its token expires after another library mutation or an app restart, including edits made through the normal app. Tab closure has no guaranteed undo.

## Troubleshooting

- **App unavailable:** open Savenest on this Mac and check that connections are allowed in **How it works**. Retry after resuming the connection.
- **Client setup missing:** use **Manage → Advanced setup → Repair setup**, then follow the restart guidance. Manual configuration is available in the same panel.
- **Adapter missing:** use an official 0.13.0 build containing the adapter. Public source builds do not include the private component by default.
- **Pro cannot be verified:** check the account and connection, refresh account status, then retry. MCP does not fall back to unchecked access.
- **Permission denied:** choose **Manage** on that app’s card and inspect its permissions. Browser Automation and history access may also need macOS approval.
- **Tab changed or cannot be identified:** refresh the tab list and select the intended target again. Ambiguous Safari duplicates stay open.
- **Record changed:** fetch the current saved record before editing or removing it.
- **Some actions failed:** inspect each target’s result. Do not assume the entire batch succeeded or retry completed actions under a new request ID.

The 0.13.0 release includes Claude Desktop setup with compatibility explicitly marked unverified. Availability copy must retain that distinction. Deploy the website's 0.13.0 availability copy only after the app release is published.

## Development checks

Run `swift run SaveNestChecks`, `npm test`, and `npm run test:mcp`. The MCP integration checks use the real native controller and Unix socket with a disposable preview library, simulated browser actions, and a test-only Pro verifier. They never read or modify real browser tabs or the user’s library. These checks do not replace live-client and signed-release verification.

The private adapter has its own Swift tests and stdio protocol fixtures. Opt into packaging with `SAVENEST_MCP_PACKAGE_PATH` pointing to that private package, or `SAVENEST_MCP_BINARY` pointing to a reviewed architecture-matching binary beside its license and third-party notices. Public builds omit it by default.

Validation recorded during 0.13.0 release preparation on November 11, 2026:

| Check | Evidence |
| --- | --- |
| Codex CLI 0.166.0 | Real MCP handshake, `get_status`, and `search_links` passed against synthetic fixture data. |
| Claude Code | Connection and tool discovery verified. A complete AI workflow has not been verified. |
| Claude Desktop | Setup available; app compatibility unverified. |
| Shared Swift checks | 40 passed on the release branch. |
| Electron tests | 52 passed on the release branch. |
| Intel CI | Passed on commit `a42e371`: 40 Swift checks, 52 Electron tests, native build, and MCP fixtures. This does not establish Intel installed-app runtime. |
| Private adapter Swift tests | 5 passed before the release-source port. |
| Private adapter stdio protocol checks | 11 passed before the release-source port. |
| Native MCP integration checks | Passed with a disposable preview library, simulated browser actions, and test-only Pro verification. Intel CI also passed the MCP fixtures. |
| Connect setup | Passed against disposable settings, including Codex's real CLI, existing configuration preservation, credential repair, concurrent edits, cancellation, and failure cleanup. Claude configuration merges are fixture-tested. |
| Earlier local Mac packages | Apple Silicon and Intel architecture and local ad-hoc signature checks passed before the release-source port. The packaged Apple Silicon adapter passed 11 stdio checks. |
| Live Safari and Chrome actions | Passed search, focus, preview-library save, verified close, and repeat-close refusal using disposable tabs. Live checks exposed and fixed transient process lookup and Chromium tab-reordering issues; process-birth and reference regression checks pass. |
| Signed release | Signing, notarization, installed-app update checks, and publication pending. |

These results do not verify a real Claude Desktop connection, a complete Claude Code AI workflow, scheduled client workflows, Intel installed-app runtime, or notarized-release installation and updates. Fixture checks and local ad-hoc signatures are not evidence that the signed release has passed those checks. Remaining release results must be recorded after they run.
