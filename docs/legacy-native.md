# Legacy native interface

[Back to the project](../README.md)

The current app uses the Electron launcher. This reference covers the retained Swift interface and native services. For native UI development, `./scripts/preview-app.sh` opens an isolated sample app; it does not load or write the saved library, register account callbacks, or register global shortcuts.

## Library interface

- A floating rail gives direct access to Library, Tags, open-tab search, Add link, Account, and Settings. Date groups sit in rounded cards; notes and tags stay with their links. Editors, onboarding, capture feedback, and tab search share the selected appearance.
- Links are grouped by local calendar date, newest first.
- Website icons replace letter tiles when available. New captures retain the page’s icon URL; older links use the site favicon or public homepage icon. Requests use no browser cookies or favicon proxy, run in the background (six at a time), and cache locally for seven days. Missing icons keep the letter fallback.
- Click a title to open it in your default browser; click a note preview to edit it. Row actions become more prominent on hover.
- Swipe left with two fingers to reveal Delete and Archive (Restore inside Archive); a long left swipe performs Archive. Swipe right for Email and Copy. Escape closes revealed actions. All actions are also in the row menu.
- Email opens a preview with an editable subject and an optional note (off by default). Include a note starts from your saved note without changing it. Open Mail prepares a draft; you choose the recipient and send it.
- “Archive all links…” in Settings → Your library clears the active library after confirmation. Both individual and bulk archive/restore offer Undo in the footer for the last action.
- “Empty archive…” lives inside Archive. It confirms the count before permanently deleting archived links, notes, and tags. Links outside Archive, restored links, and links added after the confirmation opened are kept.
- Search titles, full URLs, notes, tags, and archived links with **⌘F**. Search starts in Everywhere; scope it to Library, Favorites, Notes, or Archive when needed. Archived matches are labeled. All keywords must match somewhere and results are ranked by relevance. Use **#tag** to match a single-word tag exactly.
- Refine results by tag, website, or whether a note is present. The same filters work inside Archive.
- Add tags with Return or commas, press Tab to accept the first matching suggestion, and click a tag to remove it. Suggestions mirror lowercase or leading-uppercase input; automatic tags follow the casing used by most existing tags. Saving includes any unfinished tag input; **⌘Return** saves the editor.
- Existing libraries and backups without tags load automatically; notes and saved dates are preserved.
- A row’s **…** menu has copy, note/tag editing, Delete, and archive.
- **⌘Z** restores the last library change. Text fields keep standard typing undo.
- A long swipe grows and highlights its direct action, then labels it before release applies it: Copy to the right, Archive or Restore to the left.
- Account and Settings are in the right-hand rail. The library header only shows the local status; individual links retain their **…** menus. Archived links can be restored.
- Duplicates are skipped without overwriting existing notes or dates.
- Internal browser pages, local files, and URLs with embedded credentials are skipped.
- Settings can export and merge-import JSON backups.

Data lives at `~/Library/Application Support/SaveNest/library.json`. Writes are atomic. If loading fails, the original file is left intact and further writes are blocked, so a damaged or newer-format library cannot be silently overwritten. Restore a valid backup at that path and restart the app to recover.

## Legacy updates

Release builds use Sparkle 2.10.0. **Check for Updates…** is available in the Savenest application menu, the menu bar icon, and **Settings → App updates**, alongside the version/build and **Automatically check for updates** switch. Sparkle asks for permission for automatic checks on the second launch; it remembers the user's choice and checks daily when enabled. Downloads and installation require user action. Sparkle's system profiling is disabled. Updates do not require sign-in or an active subscription.

The feed is `https://savenest.app/downloads/appcast.xml`. Sparkle verifies update archive signatures before installation, replaces the application, and relaunches it. Library data remains in Application Support. Development builds from `build-app.sh`, ad-hoc release previews, and Savenest Preview disable updates; the preview never creates a Sparkle updater. The build scripts embed and sign the framework and each helper, preserving their entitlements and symlinks.

Version 0.9.3 (build 26) introduces the updater. Users on 0.9.2 or earlier need one manual installation. Publishing a feed alone cannot add an updater to their old app.

The Sparkle feed can offer the specially prepared Electron preview starting with 0.11.1 (build 35). It must preserve the existing EdDSA public key, carry an archive signature from that key, and use an increasing numeric build. Ordinary Electron archives must not be inserted without these checks. Subsequent Electron updates use its separate Squirrel feed. See [maintainer notes](maintainers.md).
