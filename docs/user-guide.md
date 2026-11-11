# Using Savenest

[Back to the project](../README.md) · [Privacy](privacy.md)

Local saving, search, reading, browser tools, and import/export remain free. The optional [Pro MCP connection](mcp.md), included in 0.13.0, lets Codex or Claude use selected links and quick notes, organize the library, and manage permitted tabs. Claude Desktop setup is available, but its compatibility is unverified.

The [Read & note workspace](read-and-note.md) opens an article beside its Obsidian Markdown file. It is available in the 0.12 preview series.

## Launcher

Press **⌘O**, then type. Commands, open tabs, saved links, notes, tags, and recent browser history share one search. **Enter** runs the selected command, switches to an open tab, or opens a saved/visited page. Pasting a URL offers **Save this link**. Saving with a note and choosing multiple tabs happen inside the same panel. The launcher keeps its borderless search field, scope dropdown, quick actions, and result list.

Click **Actions** or press **⌘K** for actions on the selected page and app-wide commands. The searchable panel includes **Settings**, **Keyboard shortcuts**, all search scopes, capture actions, and library tools. It remains available in every search scope, even when there are no results. For example, choose **Actions → Search saved links** to browse your saved library, or **Search all pages** to return to the combined search. Changing scope starts a fresh query. Use the arrow keys and Enter to choose an action, or click it.

**Settings** and **Shortcuts** stay visible in the footer, including while editing a link. Click **Shortcuts** or press **⌘/** to open the keyboard guide; Escape or **⌘/** closes it. The guide separates launcher keys from shortcuts that work in other apps and displays your configured capture bindings, including missing assignments or registration errors. **Customize in Settings** opens the shortcut preferences. Preview mode shows the bindings but does not register global shortcuts.

The floating launcher opens on the display containing the pointer, including over fullscreen apps, and stays out of the Dock. Click elsewhere to hide it. Escape closes actions, goes back from an editor or scope, then dismisses root search. Unsaved edits require an explicit discard. The launcher remembers context for 60 seconds; after that it resets root search unless a draft is open. **⌘O** toggles it. The old **⌘⇧O** default migrates automatically; custom shortcuts remain unchanged and can be edited in Settings.

Account, Settings, sharing, and system dialogs retain their native implementation and are reachable from root search. Optional email sign-in and billing management are handled by savenest.app. Local links and notes remain available; Pro saving and enabled AI connections have the separate data flows described below. Existing saved links and Keychain sessions use the same storage, with no conversion. Settings → Appearance changes both interfaces. [Launcher design](launcher-design.md).

### Browser history

History search reads local Chrome/Chromium-family, Firefox, and Safari databases without modifying them. It indexes up to 2,000 recent records per profile from the last 90 days, across at most 30 profiles, with a 20,000-URL memory cap. Standard profile locations for Chrome/Beta, Brave, Edge, Arc, Vivaldi, Chromium, Opera, Firefox, and Safari are supported. External/custom profile locations and Safari profile layouts outside the standard history database are not scanned.

History remains in memory and is excluded from library exports and Savenest uploads. If you enable an AI connection and grant history access, requested history records can reach your AI provider. Launcher history refreshes on opening (at most once per minute) or explicitly via **Refresh tabs and history**. Failed reads clear that source’s old results and show an access/format error. **Browser history sources** shows connected profiles and a pause control that cancels reads and clears the cache. macOS may require file access for protected browser folders; Savenest does not change those permissions.

A URL found in multiple sources becomes one result with its source labels. If it is open, Enter switches to that tab. Separate open instances remain distinct so profiles/windows are not confused. Title and keyword relevance rank before page-context matches; abbreviated single-word titles are also supported. History-only results can be saved, annotated, or opened like other pages.

## Capture

1. Open a normal web page in Safari or a supported Chromium browser.
2. Press **⌘⇧K**. On first use, macOS asks whether Savenest may automate that browser. Allow it to enable capture. If denied, use System Settings → Privacy & Security → Automation.
3. The tab's title and URL are saved locally. Quick Save can also attach up to three existing tags learned from your saved links. A small top-right confirmation appears; the browser keeps focus and its tabs stay open. Capture errors appear in the same place for eight seconds, with a clear reason and an Automation Settings action when permission is needed. They never open the library or a modal dialog. You can preview the popup in Settings.

Use **Savenest → Settings** (**⌘,**) to record each shortcut separately:

| Action | Default shortcut |
| --- | --- |
| Save current link | ⌘⇧K |
| Save with a note | ⌘⌥K |
| Save selected tabs | ⌘⌃⇧K |
| Save all tabs in the current window | ⌘⌥⇧K |
| Open Savenest launcher | ⌘O |
| Close duplicate tabs | ⌘⇧D |

Settings → **After saving** can close the source tab after Save link or Save with a note. Save-only is the default; your choice is remembered. Closing happens only after a successful library write or confirmed editor save (including a link already saved), and only for the originally captured browser tab. A navigated, missing, or ambiguous tab is left open with a saved-but-not-closed notice. Selected-tab and whole-window capture always keep tabs open.

Your previously configured quick-save shortcut is preserved. Choose a key with Command, Option, or Control. Escape cancels recording. Conflicts with another Savenest action are rejected; an unavailable system shortcut leaves the previous binding unchanged. Each row has its own reset button.

Save with a note reads the browser link first, then opens only a small editor without activating Savenest or raising the library. The editor includes both the note and tags, with the note focused. For new links, Savenest can pre-fill up to three existing tags from repeated patterns in the page title and exact website host. Quick Save uses the same learning and applies those tags silently; clipboard and open-tab single-link saves do too. Suggestions come only from links and tags already stored on this Mac; they remain editable later and never use a cloud model. Auto-tagging is on by default and can be disabled in Settings. **⌘Return** saves and **Escape** cancels. Nothing in the note editor is saved until you confirm. Capturing an existing link opens its existing note and tags without adding automatic tags; saving updates that link without losing its original date or archive state. A second capture while editing brings the existing draft forward instead of discarding it.

Selected-tab capture opens a checklist of the web tabs in the current browser window and saves only the checked tabs. Bulk capture saves every web tab in that window. Neither action extracts hyperlinks from a page or closes tabs. The menu bar and File menu expose the capture actions as well.

The foreground supported browser takes priority. From Savenest or another non-browser app, capture uses the last active supported browser (remembered across restarts). On a cold start, visible browser windows or a single running browser provide a fallback. Known unsupported foreground browsers get a specific message rather than capturing a different browser.

Direct capture adapters: Safari, Safari Technology Preview, Chrome, Chrome Beta, Brave, Edge, Arc, Vivaldi, Chromium, and Opera. These rely on each browser's scripting support; not all adapters have been exercised on this machine. Firefox doesn't expose the same tab scripting interface: copy a URL and paste it into launcher search, choose **Add a link**, or press **⌘N**.

## Clipboard and usage counts

Settings → Clipboard → **Offer to save copied links** is off by default. Enable it to offer Save or Add note when you copy a single HTTP(S) URL. Monitoring starts with the next clipboard change; it ignores previously copied contents, prose, credentials in URLs, private/transient/generated pasteboard types, and links already saved (including Archive). The offer lasts 12 seconds and never takes keyboard focus. It saves the URL shown by that offer even if you copy something else. Turning monitoring off dismisses any offer. **Save copied link** in File or the menu bar works without continuous monitoring. No account or subscription is needed.

Settings also offers an optional shortcut preset: **⇧⌘K** saves and **⇧⌘N** adds a note with optional tags. Existing bindings are retained until selected; a registration conflict rolls back the entire preset. Every binding remains configurable.

**Share anonymous usage counts** is enabled by default, announced by a dismissible library banner, and can be turned off in Settings or directly from the banner. Every 60 seconds, the app sends only fixed event names/counts to `https://savenest.app/api/usage`. It includes no account token, cookie, persistent installation/device identifier, URLs, titles, note text, tag names, clipboard contents, or importance choices. A fresh random batch ID prevents counting one upload twice. Turning reporting off clears pending counts, cancels in-flight requests, and discards the session. Events remain in memory only; offline, failed, short sessions, and shutdown activity may be missed. Reporting does not block saving. Counts already sent cannot be associated with an individual for deletion.

The service aggregates by UTC day, retaining approximately 90 days of counts and seven days of upload receipts. Ordinary network information (including IP address) reaches the hosting provider but is not stored in the usage tables. These are best-effort action totals, not unique-user, retention, or revenue metrics. Preview mode sends no analytics and does not monitor the clipboard.

## Browser tab adapters

Open tabs participate in the main **⌘O** search. Choose **Search open tabs** or the Open tabs scope to narrow results. Titles rank above URLs and browser names. Results refresh on opening; cached pages remain searchable while browsers respond. Safari and the supported Chromium adapters expose tabs across scriptable windows and profiles. Hidden Safari tab groups, Firefox tabs, and embedded browser views are not included. Firefox history is supported separately. Use **⌘S** or **⌘K → Save to library** to save a tab without switching browsers. Tab titles and URLs remain in memory unless explicitly saved.

**⌘⇧D** closes exact duplicate web addresses within each supported browser window and removes known empty/new-tab pages. It keeps an active duplicate when the browser exposes that state and otherwise keeps the first copy. Separate windows and browser profiles are left independent, URLs with different queries or fragments remain separate, and tabs that move or navigate before closing are left open. This shortcut overlaps Chromium’s Bookmark all tabs command and can be changed in Settings.

## Better titles

Capture attempts a fixed, read-only script in the captured page to read Open Graph/Twitter metadata and, for a matching social post permalink, the post text. X extraction matches the current status ID so a reply or promoted post does not become the title. No metadata is sent to another service, and Savenest does not change the browser’s security preferences.

Browsers may block this unless **Allow JavaScript from Apple Events** is enabled by the user. Browser Automation access and this JavaScript setting are separate. If metadata is blocked, unavailable, or a page navigates during capture, Savenest retains a useful native title or builds a descriptive fallback from the URL (for example `@anna on X · 123` or `Instagram reel · ABC123`). Login-only pages and changing social site markup can limit results. These fallbacks identify the link; they do not invent a caption. A captured title can always be edited.

## AI connections — Pro, 0.13.0

In the official 0.13.0 build, open **Settings → AI connections** and choose **Connect** on the Codex, Claude Desktop, or Claude Code card. Savenest verifies Pro and installs the local setup with read-only access to saved links and quick notes. Follow any restart guidance shown. No configuration copying is needed for normal setup. Public source builds omit the private adapter by default.

Codex tool calls are verified on sample data. Claude Code connection and tool discovery are verified; a complete AI workflow has not been verified. Claude Desktop setup is available, but its compatibility is unverified.

Choose **Manage** to change that app’s permissions or disconnect it. **Advanced setup** contains configuration copying, setup repair, and a local access test. **How it works** explains privacy and runtime requirements and lets you pause all AI connections. Disconnecting one app does not affect another.

History and destructive permissions start disabled. Grant removal, save-and-close, or direct closing only when that client needs them. Direct closing does not save a link first. Your AI client can use already-approved permissions in a scheduled task, subject to its own approval rules. Keep the Mac awake with Savenest and the AI client running.

The connection reads link details and quick notes, not article text or external Obsidian files. Requested records reach your AI provider. It requires online Pro verification; a failed verification pauses MCP access while free app tools continue working. See the [MCP guide](mcp.md) for setup, examples, and recovery.

## Library and backups

Saved data lives at `~/Library/Application Support/SaveNest/library.json`. Use Settings to export or merge-import JSON backups. Writes are atomic; an unreadable or newer-format library is preserved and further writes are blocked. Keep a backup before testing changes with real data.

The [native interface reference](legacy-native.md) describes the retained Swift UI.

## Automatic Pro saving and recovery

Open **Account & Pro**, sign in using the email link, and choose **monthly ($4.99 USD)** or **yearly ($49.90 USD)**. Applicable tax is added at checkout. Stripe opens in your browser; return to Savenest after checkout. Expand **Membership** to see your plan and billing date or choose **Manage billing**. Core saving, search, reading, and import/export stay free.

Pro starts saving automatically after account, service-permission, and local-library checks pass. **Sync is active** shows a gently pulsing green dot after the server acknowledges a save. Offline changes remain on this Mac and retry automatically. Each Mac has its own saved library; changes do not merge between Macs.

To recover, expand **Restore library**, choose **Restore…**, and confirm the date and link counts. Savenest preserves the previous local file before replacing it. **Show recovery copy** reveals that file. The restored library saves automatically when verified Pro access and upload permission remain available.

Saved copies include links, quick notes, tags, and collections. Obsidian files and offline articles stay on this Mac. Limits: 2 MiB per library copy, five Macs, one latest successful daily recovery copy per Mac, and 90 days of recovery after Pro ends. See [Pro saving and recovery](cloud-backup.md) for details.

## Invite a friend

In 0.13.1, open **Account & Pro → Invite a friend**, sign in, enter your friend's email, and choose **Send invitation**. Your friend must sign in with that invited address, open the invitation link or enter its promo code under **Have an invitation code?**, and choose monthly Pro.

A friend new to paid Savenest pays **$1.99 for the first monthly payment**, then **$4.99/month**, before applicable tax. After they pay, you get one **$3 discount** on your first eligible monthly checkout or a later monthly renewal. Yearly plans are excluded. Each account gets at most one discounted month across both roles, even when it sends several invitations. Monthly Pro renews automatically until cancelled.

Invitations expire 30 days after sending. A reward for a new checkout expires 30 days after qualification. The [privacy policy](privacy.md) explains invitation email delivery and referral records.
