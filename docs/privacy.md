# Savenest privacy policy

Updated November 11, 2026

This policy describes free local features, automatic saving and recovery with Pro, the Pro MCP connection in 0.13.0, and friend invitations in 0.13.1. See the [MCP guide](mcp.md) for client compatibility and release verification.

## Your library stays on your Mac

The free Savenest Mac app works without an account. Saved links, titles, notes, and tags are stored locally. With verified Pro access, the signed-in Mac app automatically saves library changes to your account when the service permits uploads and the local library is healthy. There is no separate backup toggle. Each Mac has its own saved library; changes are not merged between Macs. Teams is not included.

- **Local content:** browser history and unsaved page context are not uploaded to Savenest. Your saved library is uploaded automatically by the signed-in Mac app with verified Pro access and server permission.
- **Optional reporting:** anonymous action counts are on by default. Turn them off in Settings or the first-use notice.
- **Network requests:** website icons, account services, updates, and usage reporting can contact external servers.
- **AI connections:** enabling a Pro MCP connection shares requested link details and quick notes with the AI client, within the permissions you grant.

## Who runs Savenest

Savenest is operated by Omelabs, Inc. Dmytro (Dima) Omelian is its founder. For privacy questions, data requests, or support, email [dima@omelabs.org](mailto:dima@omelabs.org).

## Your library and browser access

Saved URLs, titles, notes, tags, favorites, and archive state are stored in a local library file inside your Mac’s Application Support folder. Savenest does not encrypt that file itself. Your Mac’s account permissions, device security, and any disk encryption you enable protect it. Exports are local files you control.

With macOS Automation permission, Savenest can read supported browsers’ open-tab URLs and titles. Optional page-context search reads text from open pages when the browser permits JavaScript through Apple Events. Open tabs and unsaved page context remain in memory. Explicitly saved links and notes become part of your local library.

History search reads supported browsers’ local history databases without changing them. It indexes a bounded set of recent visits in memory. Pausing history search clears Savenest’s history cache; it does not delete browser history. History is not included in library exports or sent with usage counts.

Clipboard offers are off by default. If you enable them, Savenest watches for a newly copied web URL and offers to save it. Clipboard contents are not uploaded. You can turn this off in Settings.

## Connections made by the app

### Read & note

The reading workspace opens the Original website by default. Choosing the optional Reader view extracts article content from the explicitly requested browser tab. Extracted content stays in memory and is not uploaded to Savenest. Browser form fields and editable regions are excluded. Reader images contact their source websites only after **Load images**; the Original view loads the website and its resources in a separate temporary browser session. Those websites receive ordinary connection information and may process interactions made within that view. Existing browser cookies are not imported.

After you choose an Obsidian vault, page notes are ordinary Markdown files containing the source URL. Savenest retains a local file-association index and pending recovery drafts in Application Support. Vault files may be synced by iCloud, Obsidian Sync, or another service you independently configure. Savenest does not upload them or include them in its library JSON backups. These notes, URLs, and article contents are not sent with usage reporting.

### Existing app connections

Savenest may request a website’s favicon or public homepage to display its icon. These requests do not use your browser cookies or a favicon proxy, but the destination receives ordinary connection information such as your IP address. Icons are cached locally and refreshed when requested after seven days. Cached files may remain on your Mac until evicted by the bounded cache or removed locally.

Update checks contact savenest.app; release downloads are hosted on GitHub. These services receive ordinary request information. Opening a saved page uses your browser. Sharing by email uses the email application you choose and sends the content you explicitly share to your selected recipient.

Automatic tag suggestions use links and tags already stored on your Mac. They do not call an AI provider. The optional Pro MCP integration shares requested records with the AI client you authorize.

### AI connections through MCP — Pro, 0.13.0

The Pro MCP adapter runs on the same Mac as Savenest and the connected Codex, Claude Desktop, or Claude Code client. It exposes saved link details and quick notes. Reading open tabs and recent browser history requires the corresponding permissions. Article text, live page content, and external Obsidian Markdown files are excluded.

Returned titles, URLs, tags, quick notes, and permitted browser records enter the AI conversation and may be processed or retained by that AI provider under its terms and your account settings. A local connection does not mean that the AI conversation stays on your Mac. Savenest does not host or proxy MCP records. Your Savenest account credential never crosses the MCP connection.

AI connections are disabled by default. Choosing **Connect** in **Settings → AI connections** enables the local connection and installs that client's configuration with read-only access to saved links and quick notes. Each client has a separate credential stored in owner-only local files. **Manage** controls tab and history access, saving/editing, opening links, removal, save-and-close, and direct closing. Once granted, permissions can be used in unattended tasks without a new Savenest confirmation for each action. The AI client may impose its own approvals. You can disconnect one client or pause all connections in **How it works**.

Connection settings and recent action results stay local. Queries, URLs, note contents, and connection credentials are excluded from usage reporting. Pro access is verified online through the existing account service without sending library contents. When verification expires and cannot be renewed, MCP data access pauses; free app tools continue working. Disconnecting does not remove content already received by the AI provider.

## Anonymous usage counts

“Share anonymous usage counts” is enabled by default. A visible notice and Settings provide an off switch. Reporting sends fixed action names and totals, such as app opens, links saved, notes saved, and links opened. It does not send URLs, titles, note text, tag names, clipboard contents, account tokens, account IDs, or persistent installation/device identifiers.

Pending counts stay in memory and are sent in batches, approximately once a minute. Each batch has a new random identifier to prevent double-counting. Turning reporting off clears pending counts and cancels reporting requests. A request already received by the server cannot be recalled.

The service keeps daily aggregate counts for approximately 90 days and random batch receipts for seven days. Cleanup runs when new batches arrive, so expired records may remain until the next cleanup. These tables do not contain IP addresses. The hosting provider still receives ordinary network information. Because counts have no person or device identifier, we cannot locate one person’s contribution in an aggregate for deletion.

## Optional accounts and subscriptions

If you request a sign-in link, we process your email address, optional name, and authentication records to provide your account. Website sign-in does not upload your library. The Mac app starts automatic saving after sign-in when Pro access, server permission, and local-library health checks pass. The app keeps its session credential in macOS Keychain. The server stores hashed tokens. A successful browser confirmation can also set a secure, HttpOnly account-session cookie.

Sign-in links expire after 15 minutes; the one-use code exchanged by the app expires after two minutes. Account sessions expire after 30 days. Expired authentication records are removed during later authentication cleanup, rather than by a guaranteed deletion timer. Signing out removes the app’s local credential and, when online, revokes that server session.

Stripe processes Pro payments and subscription management. Savenest stores the associated customer identifier, subscription status, plan, billing-period dates, and payment-event identifiers. Payment-card details are entered on Stripe’s pages and are not stored in Savenest’s database. Pro is optional and billed monthly or yearly.

When you send a friend invitation, we send the recipient's email address and invitation, including your name, a personal code, and a link, to Resend for delivery. We store the invited email, inviter account link, recipient account link established at checkout, invitation code and dates, delivery state, associated billing identifiers, and qualification and reward state. These records let us deliver invitations, apply the eligible monthly discount, prevent repeated rewards, and resolve billing questions. Referral processing does not give Savenest payment-card details.

Account, billing, support, and referral records, including earlier referrals, are kept while needed to operate the account, resolve requests or disputes, and meet applicable recordkeeping duties. They do not currently have an automatic deletion schedule. Request account deletion by email; we will explain any records that must be retained.

## The website, bookings, and service providers

The website does not add advertising trackers. Essential account cookies and hosting/security infrastructure may still process request data. Authentication abuse controls use hashed email/IP-derived keys and expiry times; they do not add raw IP addresses to the usage-count tables.

- [Cloudflare](https://www.cloudflare.com/privacypolicy/) hosts the website and forwards account and backup API requests through the Sites hosting platform.
- [Amazon Web Services](https://aws.amazon.com/privacy/) hosts the backend, PostgreSQL account and current-library database, and encrypted recovery-backup storage in Stockholm, Sweden.
- [Resend](https://resend.com/legal/privacy-policy) delivers account and friend-invitation emails.
- [Stripe](https://stripe.com/privacy) processes billing and payment records.
- [GitHub](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) hosts the public source and desktop downloads. We fetch the public star count from our server, not your browser.
- [Cal.com](https://cal.com/privacy) handles demo bookings when you follow the booking link. Information you enter there is used to arrange your requested meeting.

Following these links, downloading a release, or booking a meeting connects you to the relevant provider. Provider operations may involve processing outside your country. Their linked notices describe their handling of data. We do not claim that all website or account data stays in one country.

## Why we process information and your choices

We use requested account, support, and billing information to provide those services. We use limited security and operational information to protect the service and understand whether basic features work, and retain records where required by law. Optional usage reporting can be turned off without losing any local feature.

You can export or delete local links in the app, revoke browser access in macOS, pause history, disable clipboard offers, and turn off usage reporting. Uninstalling the app may leave its Application Support files, preferences, and Keychain entries on your Mac. Export anything you want to keep before deleting those files.

Depending on your location, you may have rights to access, correct, erase, or receive personal data, restrict or object to its processing, and complain to your data-protection authority. Email [dima@omelabs.org](mailto:dima@omelabs.org) to make a request. We may need to verify that the account belongs to you. We cannot remotely delete local files on your Mac.

## Automatic Pro saving and recovery

Automatic Pro saving uploads saved links, URLs, titles, quick notes, tags, collections, favorite/archive state, importance choices, and creation dates. The current library is stored in the service database. Recovery copies include a random device identifier to keep each Mac’s saved library separate. Obsidian Markdown files, offline articles, browser history, unsaved page context, browser cookies, credentials, and app preferences are excluded.

Connections use TLS and AWS encrypts the stored database and backup objects. This is server-side encryption, not end-to-end encryption: the Savenest backend can read backup contents to validate and restore them. Backups are private to the signed-in account and require server-verified Pro access.

The service keeps each Mac’s current library and one latest successful daily recovery backup, across up to five Macs, with a 2 MiB limit per library copy. An initial recovery copy is created, then the server schedules replacement about once every 24 hours from the current saved library. The previous recovery copy is retired only after its replacement is successfully uploaded and committed. The schedule may be delayed by service failures or a backlog. Recovery remains available for 90 days after Pro access ends; new uploads stop. Superseded and expired data is removed by scheduled cleanup; deletion can be delayed while services are unavailable. Database backups can retain older records for up to seven days. Contact support for an account or backup deletion request; we will explain any billing records that must be retained.

Signing out stops subsequent uploads from that Mac without deleting existing server copies. A request already accepted by the service may have completed. The daily server backup continues from the last saved current library while Pro remains active. A previously known local library that goes missing, or a corrupt library, is held for review so an empty replacement does not overwrite useful saved content. A new, healthy first-install library may start automatically. To clear a recovery hold, restore a saved copy or explicitly confirm **Use this library…** after the local library can be loaded.

Restoring replaces the current local library only after confirmation and preserves its exact previous bytes in a local Cloud Recovery folder. If that preservation fails, restoration stops. A successful restore clears the review hold and automatically saves the restored library when verified Pro access and server permission remain available. During the post-subscription recovery period, restoration remains local because new uploads are not permitted.

## Policy changes

We update this policy when the service’s actual data flows change. Material new data collection or sharing will be explained before it is enabled.
