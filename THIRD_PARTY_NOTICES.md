# Third-party notices

Savenest's own source is licensed under MIT. Dependencies retain their own licenses.

- **CodeMirror 6 and Lezer** — MIT. Used for Markdown editing and syntax parsing. Complete bundled notices are included in `reader-third-party-licenses.txt`. Source: https://codemirror.net/.
- **Mozilla Readability** — Apache-2.0. Used for local article extraction. Complete license is included in `reader-third-party-licenses.txt`. Source: https://github.com/mozilla/readability.
- **DOMPurify** — Apache-2.0 OR MPL-2.0. Used to sanitize captured article markup. Complete license is included in `reader-third-party-licenses.txt`. Source: https://github.com/cure53/DOMPurify.

- **Electron** — MIT, Copyright Electron contributors and GitHub Inc. Electron includes Chromium, Node.js, and other components with additional licenses. Distributed applications retain Electron's `LICENSE` and `LICENSES.chromium.html`; consult those files for the complete bundled notices. Source: https://github.com/electron/electron.
- **Sparkle 2.10.0** — MIT, Copyright Sparkle Project contributors. The native helper bundles Sparkle; its license is included with the application. Source: https://github.com/sparkle-project/Sparkle.
- **SQLite** — public domain. Savenest uses macOS's system SQLite for read-only browser-history queries. Source: https://sqlite.org/copyright.html.
- **Swift and Apple frameworks** — supplied by the developer toolchain or operating system, under their respective terms; not relicensed by Savenest.

Build tools such as `@electron/packager`, `@electron/fuses`, and their dependencies are installed from the locked npm dependency graph. Their license files remain in their packages; they are not part of Savenest's own MIT grant. Release packaging must retain notices for every component actually distributed.

Website names, browser names, and third-party marks remain the property of their owners. Favicon downloads are runtime user-library data and are not included in the source release. The generated Savenest icon is built by `scripts/make-icon.swift`.
