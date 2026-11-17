(function (root) {
  'use strict';

  const socialCapture = {
    id: 'social-capture',
    title: 'Save from other apps',
    badges: ['Pro', 'Beta'],
    summary: 'Bring saved Slack messages and LinkedIn or X posts into one library. Read How it works in Settings → Capture.',
    points: [
      'Off until you enable it; choose apps in Settings → Capture.',
      'Needs Accessibility permission and a new save while the source app is in front.',
      'LinkedIn briefly reopens its post menu to copy the link, then restores your clipboard.',
      'Saves follow your usual cloud backup and AI permissions; the text note is optional and off.'
    ],
    evidence: 'Slack and Safari are tested; Chrome is experimental.',
    action: { label: 'Set up capture', command: 'socialCaptureSettings' },
    keywords: 'social capture slack linkedin x twitter safari chrome accessibility beta pro other apps cloud backup ai'
  };

  const groups = [
    {
      id: 'capture',
      title: 'Capture from your browser',
      items: [
        {
          id: 'save-current',
          title: 'Save the current tab',
          description: 'Keep the title and URL of the page you were just viewing.',
          shortcut: 'quick',
          action: { label: 'Save current tab', command: 'capture', action: 'quick' },
          keywords: 'save current tab bookmark quick browser'
        },
        {
          id: 'add-link',
          title: 'Add a link',
          description: 'Paste a URL, then add a note and tags.',
          // Opens the launcher editor; saving there submits the existing "add" command.
          action: { label: 'Add a link', ui: 'add', command: 'add' },
          keywords: 'add link url paste note tags manual'
        },
        {
          id: 'save-note',
          title: 'Save with a note',
          description: 'Capture the current tab, then add a quick note and tags in a small editor.',
          shortcut: 'note',
          action: { label: 'Save with a note', command: 'capture', action: 'note' },
          keywords: 'save note annotate tags current tab'
        },
        {
          id: 'save-selected',
          title: 'Save selected tabs',
          description: 'Choose the tabs you want from the current browser window. Capture keeps them open.',
          shortcut: 'selected',
          action: { label: 'Choose tabs', command: 'capture', action: 'selected' },
          keywords: 'save selected tabs choose multiple bulk'
        },
        {
          id: 'save-window',
          title: 'Save a whole window',
          description: 'Save every web tab in the current browser window to your library.',
          shortcut: 'window',
          action: { label: 'Save window', command: 'capture', action: 'window' },
          keywords: 'save all window tabs session bulk'
        },
        {
          id: 'macos-services',
          title: 'Save a URL from macOS Services',
          description: 'Select a complete web URL in another app and choose Services → Add to SaveNest… to open a draft for a note and tags. Nothing is saved until you confirm.',
          keywords: 'macos services url selection add to savenest note tags draft'
        },
        {
          id: 'close-after-save',
          title: 'Close the source tab after saving',
          description: 'In Settings → Capture, choose whether Save link and Save with a note close the source tab. Bulk saves never close tabs.',
          action: { label: 'Open Settings', command: 'settings' },
          keywords: 'close source tab after save setting capture bulk'
        }
      ]
    },
    {
      id: 'find',
      title: 'Search & find',
      items: [
        {
          id: 'search-all',
          title: 'Search tabs, links and history together',
          description: 'One field searches open tabs, saved links, notes, tags, and the last 90 days of browser history.',
          action: { label: 'Search all', scope: 'All' },
          keywords: 'search all unified tabs saved links history notes tags'
        },
        {
          id: 'search-open',
          title: 'Switch to an open tab',
          description: 'Find a page that is already open in Safari or a supported Chromium browser.',
          action: { label: 'Search open tabs', scope: 'Open' },
          keywords: 'search open tabs switch browser windows'
        },
        {
          id: 'search-saved',
          title: 'Search your saved library',
          description: 'Find saved links by title, website, note, or #tag, including favorites and archive.',
          action: { label: 'Search saved', scope: 'Saved' },
          keywords: 'search saved links library bookmarks notes tags favorites archive'
        },
        {
          id: 'search-history',
          title: 'Find a page you visited',
          description: 'Search up to 2,000 recent records per profile from the last 90 days. History stays local.',
          action: { label: 'Search history', scope: 'History' },
          keywords: 'search history visited recent browser past'
        }
      ]
    },
    {
      id: 'read',
      title: 'Read & note',
      items: [
        {
          id: 'read-current',
          title: 'Read beside an Obsidian note',
          description: 'Open the current page in the reading workspace and keep its Markdown note in the vault you chose.',
          shortcut: 'reader',
          action: { label: 'Open reader', command: 'readerCurrent' },
          keywords: 'read reader obsidian markdown notes vault article'
        }
      ]
    },
    {
      id: 'organize',
      title: 'Organize & clean up',
      items: [
        {
          id: 'auto-tags',
          title: 'Suggest tags as you save',
          description: 'Local suggestions use the title, website, and tags you already use. Turn them on in Settings → Capture.',
          action: { label: 'Open Settings', command: 'settings' },
          keywords: 'tag suggestions auto tags local settings capture'
        },
        {
          id: 'manage-tags',
          title: 'Rename or remove tags',
          description: 'Clean up tags across the saved library in one place.',
          action: { label: 'Manage tags', command: 'tags' },
          keywords: 'tags rename remove organize library'
        },
        {
          id: 'favorites',
          title: 'Browse favorites',
          description: 'Keep important links close by starring them, then search the Favorites scope.',
          action: { label: 'Show favorites', scope: 'Favorites' },
          keywords: 'favorites starred pin important'
        },
        {
          id: 'archive',
          title: 'Tuck links into the archive',
          description: 'Move finished links out of the way without deleting them. Search Archive to bring them back.',
          action: { label: 'Show archive', scope: 'Archive' },
          keywords: 'archive archived later restore hide'
        },
        {
          id: 'duplicates',
          title: 'Close duplicate tabs',
          description: 'Keep one copy of each page in every browser window. Different queries and windows stay separate.',
          shortcut: 'duplicates',
          action: { label: 'Close duplicate tabs', command: 'capture', action: 'duplicates' },
          keywords: 'duplicates duplicate repeated close tabs clean'
        },
        {
          id: 'clipboard',
          title: 'Offer to save copied links',
          description: 'Off by default. Enable clipboard offers in Settings to save a newly copied web link without watching prose.',
          action: { label: 'Open Settings', command: 'settings' },
          keywords: 'clipboard copied paste offer settings link'
        }
      ]
    },
    {
      id: 'library',
      title: 'Library & shortcuts',
      items: [
        {
          id: 'activity',
          title: 'Review activity and archive history',
          description: 'Open the Activity dashboard for yearly saved, finished, and still-to-finish counts plus a daily feed. Archiving counts as finished; older undated archives stay separate.',
          action: { label: 'Open Activity', ui: 'activity' },
          keywords: 'activity dashboard yearly calendar daily feed saved finished archived still to finish counts'
        },
        {
          id: 'launch-at-login',
          title: 'Start Savenest at login',
          description: 'Optional. In Settings → General, turn on Launch at login to start Savenest when you sign in to your Mac.',
          action: { label: 'Open Settings', command: 'settings' },
          keywords: 'launch login startup sign in general settings'
        },
        {
          id: 'export',
          title: 'Export a JSON backup',
          description: 'Save a local JSON copy of your saved links, notes, tags, favorites, and archive state.',
          action: { label: 'Export library', command: 'export' },
          keywords: 'export backup json save library'
        },
        {
          id: 'import',
          title: 'Import a saved backup',
          description: 'Merge a Savenest JSON backup into this library. Keep a backup before testing changes.',
          action: { label: 'Import library', command: 'import' },
          keywords: 'import merge restore backup library'
        },
        {
          id: 'appearance',
          title: 'Choose an appearance',
          description: 'Switch between Midnight and Pearl in Settings → General. Your choice is remembered throughout Savenest.',
          action: { label: 'Open Settings', command: 'settings' },
          keywords: 'appearance theme midnight pearl settings general'
        },
        {
          id: 'keyboard-guide',
          title: 'Open the keyboard guide',
          description: 'See launcher keys and your configured capture shortcuts in one place.',
          action: { label: 'Open keyboard guide', ui: 'shortcuts' },
          keywords: 'keyboard shortcuts keys guide help launcher capture'
        },
        {
          id: 'custom-shortcuts',
          title: 'Customize capture shortcuts',
          description: 'Record your own keys for saving, notes, tab capture, the launcher, and duplicate cleanup.',
          action: { label: 'Customize shortcuts', command: 'settings' },
          keywords: 'custom shortcuts hotkeys keyboard record settings'
        }
      ]
    },
    {
      id: 'pro',
      title: 'Pro on this Mac',
      items: [
        {
          id: 'cloud-saving',
          title: 'Automatic saving and recovery',
          description: 'With a signed-in Pro account, library changes save automatically. Each Mac keeps its own library.',
          badges: ['Pro'],
          action: { label: 'Open Account & Pro', command: 'account' },
          keywords: 'pro cloud sync automatic saving recovery backup account'
        },
        {
          id: 'ai-connections',
          title: 'AI connections',
          description: 'In Settings → AI connections, connect Codex, Claude Desktop, or Claude Code. New connections start with read-only access to saved links and quick notes.',
          badges: ['Pro'],
          action: { label: 'Open Settings', command: 'settings' },
          keywords: 'pro ai mcp codex claude desktop code connection settings'
        },
        {
          id: 'invite-friend',
          title: 'Invite a friend',
          description: 'Share a Pro invitation from Account & Pro. Available offers and eligibility appear there.',
          badges: ['Pro'],
          action: { label: 'Open Account & Pro', command: 'account' },
          keywords: 'pro invite friend referral discount account monthly'
        }
      ]
    }
  ];

  function statusFor(social = {}, preview = false) {
    if (preview) return { label: 'Off', tone: 'off', detail: 'Preview demo. Settings explains capture; nothing is watched.' };
    if (social && social.available === false) return { label: 'Unavailable', tone: 'attention', detail: 'Save from other apps is unavailable in this build. Other capture tools still work.' };
    if (!social || !social.enabled) return { label: 'Off', tone: 'off', detail: 'Capture is off by default. Set it up in Settings → Capture.' };
    if (social.paused) return { label: 'Paused', tone: 'paused', detail: 'Capture is paused in Settings → Capture.' };
    if (!social.hasAccess) return { label: 'Needs access', tone: 'attention', detail: 'Active Pro access must be verified before capture starts.' };
    if (!social.permissionGranted) return { label: 'Needs access', tone: 'attention', detail: 'Accessibility permission is required before Savenest can read saves.' };
    const count = Number(social.enabledCount) || 0;
    return count ? { label: 'On', tone: 'on', detail: `${count} app ${count === 1 ? 'connection' : 'connections'} enabled.` }
      : { label: 'Choose apps', tone: 'attention', detail: 'Choose a source in Settings → Capture.' };
  }

  const api = { socialCapture, groups, statusFor };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.FeaturesCatalog = api;
})(globalThis);
