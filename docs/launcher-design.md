# One place to save and find a page

Savenest is a browser-focused launcher. Press Command-O, express intent, then act on the selected result. Saving, open-tab search, saved links, and browser history belong to this same interaction. A separate library dashboard is not the default entry point.

The launcher retains its borderless search field, scope dropdown, quick-action rows, and result list. Persistent Settings and Shortcuts buttons in the footer make preferences and keyboard help visible. Actions is the shared entry point for contextual operations and app-wide commands.

## Research and decisions

The references below were checked on October 30, 2026. These are interaction principles adapted for Savenest, not claims of feature parity with Raycast.

| Principle | Source | Savenest decision |
| --- | --- | --- |
| One search input and root results are the entry point to both content and commands. | [Raycast Search Bar](https://manual.raycast.com/search-bar) | Match commands and pages together. Detect pasted URLs and offer saving. Keep scope optional. |
| Enter performs the primary action; Command-K exposes contextual alternatives. | [Raycast Action Panel](https://manual.raycast.com/action-panel) | Open tabs switch; closed pages open. Save, copy, edit, archive, and close are secondary actions with visible shortcuts. |
| Escape moves back through navigation before dismissing the launcher. | [Raycast Settings](https://manual.raycast.com/settings) | Actions close first, editors protect dirty drafts, scoped search returns to All, and root search dismisses. |
| A launcher should reopen predictably on the relevant screen and preserve short interruptions. | [Raycast Settings](https://manual.raycast.com/settings) | Open on the pointer's display. Retain root context for 60 seconds. Never reset a draft merely because the panel was hidden. |
| Search starts with lightweight results; richer actions live behind selection. | [Raycast File Search](https://manual.raycast.com/file-search) | Compact rows show title, domain, and provenance. Notes edit inline; advanced native preferences remain searchable commands. |
| Local browser databases must be opened without write access. | [SQLite open flags](https://www.sqlite.org/c3ref/open.html) | Use read-only SQLite connections with bounded queries, deadlines, cancellation, and no temporary history copies. |

## Interaction contract

- **Command-O:** summon or dismiss the launcher. The native shortcut service owns registration so existing shortcut recording and conflict reporting remain in use. The old default migrates; custom user choices remain. Command-O deliberately occupies the normal Open shortcut because the user requested it; it remains configurable in Settings.
- **Empty query:** show Read & note current tab, Save current tab, Save with a note, Add a link, then available open/saved/recent-history pages. Suggestions use existing local data; searches themselves are not logged.
- **Typed text:** rank title/word matches above URL, notes, and optional page context. Single-word title abbreviations provide a restrained fallback. Commands rank exact names and prefixes first.
- **Same URL across sources:** one page result contains its saved annotations and history metadata; an open tab takes precedence for Enter. Multiple live instances remain distinct because activating the wrong browser profile would be worse than showing two tabs.
- **Saving:** current-tab capture keeps the native browser identity and damaged-library checks. Local saving does not require an account or subscription. Note drafts and selected-tab lists use the Electron panel. Existing saved records retain their original dates and archive state.
- **Actions:** Command-K opens a searchable panel from any root-search scope, including empty results. Selected-page or selected-command actions appear first, followed by Savenest, Search, Save & read, and Library groups. Global commands include Settings, keyboard help, every search scope, capture, and library tools. Arrow keys, Enter, and mouse clicks activate actions. Changing scope through Actions or the dropdown starts a fresh query. Destructive close/delete actions retain confirmation. Shift-Space marks pages for bulk actions.
- **Settings and shortcuts:** labeled footer buttons remain available while browsing and editing. Command-/ opens keyboard help and closes it again; Escape also closes help and restores focus. The guide shows fixed launcher keys separately from the user's configured global capture bindings, including unassigned keys and registration errors. Customize in Settings opens native preferences. Preview displays these bindings without registering global shortcuts.
- **Focus:** the panel floats over normal and fullscreen windows without a Dock entry. Clicking elsewhere hides it without pulling focus back. Explicit dismissal restores the previous app. Confirmations keep the panel visible; unfinished drafts survive hiding.
- **No false success:** blocked saves keep the editor or selection. Browser history permission/format failures are visible in History Sources. Helper failures disable data actions and retain a clear error.

## Process boundaries

- The Electron renderer loads bundled assets through `savenest-ui://app`, with a restrictive content policy, sandboxing, context isolation, and no Node access. Navigation, popups, webviews, and permission requests are blocked.
- The preload bridge accepts validated actions from the main frame only. Login callbacks pass through Electron to the native controller for state and PKCE validation. Tokens never enter renderer state.
- The Swift helper is the sole writer of the local library. It preserves atomic writes, damaged-library protection, and browser-tab identity checks.
- Settings, account management, email sharing, tag management, and cleanup review retain native dialogs.

## History boundaries

The current implementation reads standard local Chromium-family, Firefox, and Safari history stores. Chromium's schema is checked against its [URL database source](https://raw.githubusercontent.com/chromium/chromium/main/components/history/core/browser/url_database.cc); Firefox uses its Places database. Safari's local schema is treated as an adapter that can fail explicitly when the installed format differs.

Recent-history indexing is bounded to 90 days, 2,000 records per profile, 30 profiles, and 20,000 unique URLs. Search scans the cached index rather than querying SQLite on every keystroke. At most 200 matching pages reach the renderer; the total count prompts refinement when larger. These bounds are intentional and displayed in History Sources rather than implying an exhaustive lifetime history search.

SQLite reads account for each browser's timestamp epoch and live WAL state. Queries exclude hidden entries where the schema exposes them. URL validation excludes internal/file URLs and embedded credentials. History remains in memory and is absent from library backups and analytics. Disabling history cancels work and removes indexed visits immediately; explicitly saved links remain saved. This does not recover private/incognito sessions or deleted browser history.

macOS may block Safari or other browser files. Savenest reports the inaccessible source and offers a user-initiated link to system privacy settings. It never changes OS permissions. Nonstandard profile paths and Safari profile layouts outside the conventional History.db are not discovered in this iteration.

## Verification

Native tests create temporary Chromium, Firefox, and Safari databases, including live uncheckpointed WAL data. They check timestamp conversion, the 90-day cutoff, hidden/unsafe URLs, malformed/missing files, bounded reads, and byte-for-byte preservation of database and WAL files. Workspace tests check merged source identities, cross-field search, abbreviations, and removing history without losing saved links.

Electron tests exercise root command discovery, URL detection, IPC isolation, history save/pause/resume, inline capture and editing, dirty-draft handling, selected-tab saving, actions, archive/restore, delete/undo, save-and-close, root dismissal/reopening, and helper shutdown. Live browser permission prompts and real account/payment flows are not exercised by the sample-data tests.
