# SaveNest privacy policy

Updated November 11, 2026

This policy covers SaveNest’s free local features and optional Cloud backup and recovery.

## Your library stays on your Mac

The free SaveNest Mac app works without an account. Saved links, titles, notes, and tags are stored locally. Optional Cloud backup uploads a copy only after you sign in, subscribe, and turn on backups. Live sync and Teams are not included.

- **Local content:** browser history and unsaved page context are not uploaded to SaveNest. Your saved library is uploaded only when you enable Cloud backup.
- **Optional reporting:** anonymous action counts are on by default. Turn them off in Settings or the first-use notice.
- **Network requests:** website icons, account services, updates, and usage reporting can contact external servers.

## Who runs SaveNest

SaveNest is operated by Omelabs, Inc. Dmytro (Dima) Omelian is its founder. For privacy questions, data requests, or support, email [dima@omelabs.org](mailto:dima@omelabs.org).

## Your library and browser access

Saved URLs, titles, notes, tags, favorites, and archive state are stored in a local library file inside your Mac’s Application Support folder. SaveNest does not encrypt that file itself. Your Mac’s account permissions, device security, and any disk encryption you enable protect it. Exports are local files you control.

With macOS Automation permission, SaveNest can read supported browsers’ open-tab URLs and titles. Optional page-context search reads text from open pages when the browser permits JavaScript through Apple Events. Open tabs and unsaved page context remain in memory. Explicitly saved links and notes become part of your local library.

History search reads supported browsers’ local history databases without changing them. It indexes a bounded set of recent visits in memory. Pausing history search clears SaveNest’s history cache; it does not delete browser history. History is not included in library exports or sent with usage counts.

Clipboard offers are off by default. If you enable them, SaveNest watches for a newly copied web URL and offers to save it. Clipboard contents are not uploaded. You can turn this off in Settings.

## Connections made by the app

### Read & note

The reading workspace opens the Original website by default. Choosing the optional Reader view extracts article content from the explicitly requested browser tab. Extracted content stays in memory and is not uploaded to SaveNest. Browser form fields and editable regions are excluded. Reader images contact their source websites only after **Load images**; the Original view loads the website and its resources in a separate temporary browser session. Those websites receive ordinary connection information and may process interactions made within that view. Existing browser cookies are not imported.

After you choose an Obsidian vault, page notes are ordinary Markdown files containing the source URL. SaveNest retains a local file-association index and pending recovery drafts in Application Support. Vault files may be synced by iCloud, Obsidian Sync, or another service you independently configure. SaveNest does not upload them or include them in its library JSON backups. These notes, URLs, and article contents are not sent with usage reporting.

### Existing app connections

SaveNest may request a website’s favicon or public homepage to display its icon. These requests do not use your browser cookies or a favicon proxy, but the destination receives ordinary connection information such as your IP address. Icons are cached locally and refreshed when requested after seven days. Cached files may remain on your Mac until evicted by the bounded cache or removed locally.

Update checks contact savenest.app; release downloads are hosted on GitHub. These services receive ordinary request information. Opening a saved page uses your browser. Sharing by email uses the email application you choose and sends the content you explicitly share to your selected recipient.

SaveNest does not upload your saved library to an AI provider. Automatic tag suggestions use links and tags already stored on your Mac.

## Anonymous usage counts

“Share anonymous usage counts” is enabled by default. A visible notice and Settings provide an off switch. Reporting sends fixed action names and totals, such as app opens, links saved, notes saved, and links opened. It does not send URLs, titles, note text, tag names, clipboard contents, account tokens, account IDs, or persistent installation/device identifiers.

Pending counts stay in memory and are sent in batches, approximately once a minute. Each batch has a new random identifier to prevent double-counting. Turning reporting off clears pending counts and cancels reporting requests. A request already received by the server cannot be recalled.

The service keeps daily aggregate counts for approximately 90 days and random batch receipts for seven days. Cleanup runs when new batches arrive, so expired records may remain until the next cleanup. These tables do not contain IP addresses. The hosting provider still receives ordinary network information. Because counts have no person or device identifier, we cannot locate one person’s contribution in an aggregate for deletion.

## Optional accounts and subscriptions

If you request a sign-in link, we process your email address, optional name, and authentication records to provide your account. Sign-in does not upload your library. The app keeps its session credential in macOS Keychain. The server stores hashed tokens. A successful browser confirmation can also set a secure, HttpOnly account-session cookie.

Sign-in links expire after 15 minutes; the one-use code exchanged by the app expires after two minutes. Account sessions expire after 30 days. Expired authentication records are removed during later authentication cleanup, rather than by a guaranteed deletion timer. Signing out removes the app’s local credential and, when online, revokes that server session.

Stripe processes Cloud payments and subscription management. SaveNest stores the associated customer identifier, subscription status, plan, billing-period dates, and payment-event identifiers. Payment-card details are entered on Stripe’s pages and are not stored in SaveNest’s database. Cloud is optional and billed monthly or yearly. Paid referral invitations remain closed.

For earlier referrals, we retain the invited email, inviter/account links, delivery state, and reward state to resolve existing offers and billing. Account, billing, support, and historical referral records are kept while needed to operate the account, resolve requests or disputes, and meet applicable recordkeeping duties. They do not currently have an automatic deletion schedule. Request account deletion by email; we will explain any records that must be retained.

## The website, bookings, and service providers

The website does not add advertising trackers. Essential account cookies and hosting/security infrastructure may still process request data. Authentication abuse controls use hashed email/IP-derived keys and expiry times; they do not add raw IP addresses to the usage-count tables.

- [Cloudflare](https://www.cloudflare.com/privacypolicy/) hosts the website and forwards account and Cloud API requests through the Sites hosting platform.
- [Amazon Web Services](https://aws.amazon.com/privacy/) hosts the backend, PostgreSQL account database, and encrypted Cloud backup storage in Stockholm, Sweden.
- [Resend](https://resend.com/legal/privacy-policy) delivers requested account emails and processed earlier referral emails.
- [Stripe](https://stripe.com/privacy) processes billing and payment records.
- [GitHub](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) hosts the public source and desktop downloads. We fetch the public star count from our server, not your browser.
- [Cal.com](https://cal.com/privacy) handles demo bookings when you follow the booking link. Information you enter there is used to arrange your requested meeting.

Following these links, downloading a release, or booking a meeting connects you to the relevant provider. Provider operations may involve processing outside your country. Their linked notices describe their handling of data. We do not claim that all website or account data stays in one country.

## Why we process information and your choices

We use requested account, support, and billing information to provide those services. We use limited security and operational information to protect the service and understand whether basic features work, and retain records where required by law. Optional usage reporting can be turned off without losing any local feature.

You can export or delete local links in the app, revoke browser access in macOS, pause history, disable clipboard offers, and turn off usage reporting. Uninstalling the app may leave its Application Support files, preferences, and Keychain entries on your Mac. Export anything you want to keep before deleting those files.

Depending on your location, you may have rights to access, correct, erase, or receive personal data, restrict or object to its processing, and complain to your data-protection authority. Email [dima@omelabs.org](mailto:dima@omelabs.org) to make a request. We may need to verify that the account belongs to you. We cannot remotely delete local files on your Mac.

## Optional Cloud backup and recovery

Turning on Cloud backup uploads saved links, URLs, titles, quick notes, tags, collections, favorite/archive state, importance choices, and creation dates. Backups also include a random device identifier to keep each Mac’s backup history separate. Obsidian Markdown files, offline articles, browser history, unsaved page context, browser cookies, credentials, and app preferences are excluded.

Connections use TLS and AWS encrypts the stored database and backup objects. This is server-side encryption, not end-to-end encryption: the SaveNest backend can read backup contents to validate and restore them. Backups are private to the signed-in account and require server-verified Cloud access.

The service keeps up to 30 daily copies per Mac, with up to five Macs and a 2 MiB snapshot limit. Recovery remains available for 90 days after your subscription ends. Superseded and expired data is removed by scheduled cleanup; deletion can be delayed while services are unavailable. Database backups can retain older records for up to seven days. Contact support for an account or backup deletion request; we will explain any billing records that must be retained.

You can turn off automatic backup in Account. Turning it off stops new uploads and does not immediately delete existing recovery copies. Signing out also turns off that Mac’s backup opt-in. Restoring replaces the current local library only after confirmation and preserves the previous file in a local Cloud Recovery folder. Automatic backup stays off after restoration until you enable it again.

## Policy changes

We update this policy when the service’s actual data flows change. Material new data collection or sharing will be explained before it is enabled.
