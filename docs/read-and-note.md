# Read & note — local development

Read & note is included in the Savenest 0.12.0 preview.

## Try it

Run `npm run preview:reader` for a sample article and disposable sample vault. **Choose vault** connects the sample vault; it does not access your personal vault. Write a note, close the window, and open the same page again during the session. Preview data is separate from the installed app.

Run `npm run try:reader` to test your actual browser and a vault you choose. This local test mode keeps the installed Savenest library, shortcuts, and privacy preferences untouched. Its launcher uses sample library data; **Read & note current tab** reads your real browser. Bring a supported browser forward, then use that command from the test app's menu bar menu. Notes are real files once you choose a vault. Test-mode vault settings and recovery drafts use a separate `ReaderNotes-Lab` application-support folder.

The regular development app (`npm start`) integrates the same workspace with the real library. Do not run two normal Savenest copies against one library.

## Read and write

Click the book button beside a page, or choose **Read & note current tab**. The workspace stays open when you switch applications. Drag the divider or focus it and use the arrow keys. At narrow widths, use the Preview and Notes tabs.

**Original** opens by default in a separate temporary web session; your browser logins are not shared. Some websites cannot be read or embedded. Use **Open in browser** in those cases. **Reader** is optional: selecting it extracts the pinned browser tab’s article. Only this view needs the browser’s “Allow JavaScript from Apple Events” setting. If unavailable, enable that setting in your browser’s developer settings and click **Try Reader again**, or return to Original. Reader images remain unloaded until you click **Load images**.

Choose an Obsidian vault in the workspace or **Settings → Library → Notes & Obsidian**. Savenest starts with the vault's configured new-note folder, or a `SaveNest` folder when there is no fixed destination. Folder changes affect new page notes; existing associations retain their original files.

Each page has one Markdown file. Opening a page alone creates no file; writing creates it. Notes save after a short pause, on ⌘S, and before closing. The footer reports the actual save state. **Open in Obsidian** opens the saved file; clicking its location reveals it in Finder. The **</>** button exposes Markdown source, including source metadata.

Existing Savenest quick notes remain separate. **Copy quick note** copies their text into the document only when you click it. Markdown files are not included in Savenest's library JSON exports; use your vault's backup process.

## External edits and recovery

Savenest checks open files for outside changes. Clean documents refresh automatically. If you also have pending edits, choose the disk version or save your writing as a separate copy. Moved/deleted files offer **Locate note**. Savenest never intentionally overwrites an unexpected revision.

Pending writing has a private local recovery copy. Failed writes block ordinary closing and update restart until resolved. An abrupt process termination may lose keystrokes made before the latest recovery write. Notes up to 100,000 characters are supported; unsupported Markdown and Obsidian syntax remain plain text without plugin execution.

## Verification

Run `swift run SaveNestChecks`, `npm test`, `node scripts/check-reader-context.mjs`, and `npm run test:smoke`. The smoke suite uses real Electron windows and the native helper with disposable files. It covers setup, autosave, external changes, conflict copies, preview isolation, themes, narrow layouts, and close/reopen.

Live browser permissions, cloud-provider coordination, VoiceOver behavior, and real Obsidian simultaneous editing require separate manual checks. Automated fixtures do not establish those results.
