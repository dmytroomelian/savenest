# Glass appearance

Savenest uses smoked navy glass for the launcher and reading workspace chrome. Reading and note panes use denser surfaces so long passages stay comfortable. The existing launcher interaction, shortcuts, and split reading workflow remain the organizing structure.

## References

- [Felix Haas's multi-agent interface](https://www.linkedin.com/posts/felixhhaas_i-built-my-own-multi-agent-interface-activity-7500972471785873409-Ut25): the supplied visual reference. Broad corners, dark translucent windows, quiet inset surfaces, and blue actions.
- [Apple: Design for spatial user interfaces](https://developer.apple.com/videos/play/wwdc2023/10076/): floating windows, depth, and legibility against changing surroundings.
- [Apple: Materials](https://developer.apple.com/design/human-interface-guidelines/materials): separate translucent navigation and controls from content surfaces.
- [Raycast's new design](https://www.raycast.com/blog/the-new-raycast): a relevant compact launcher with restrained glass chrome.
- [Apple: Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/): edge highlights and material hierarchy.

## Design decisions

| Role | Midnight | Pearl |
| --- | --- | --- |
| Base | `#111e30` | `#edf3fa` |
| Reading surface | `#132238` | `#f8fbff` |
| Text | `#f0f6ff` | `#1c304a` |
| Secondary text | `#adbed0` | `#526981` |
| Accent | `#6dc6ff` | `#0873c7` |

System typography remains in controls and notes; Georgia remains in articles. Search and result text stay left aligned. Rounded surfaces follow hierarchy: shell, inset reading panes, controls, and compact chips use different radii. Blue identifies selection and action; fine borders keep selection visible beyond color alone.

The launcher stays a single search column. The reading desk puts two calm content panes inside a glass frame. No decorative animation or background image is needed. A small stationary blue tint gives the shell character without competing with saved content.

## Implementation

`electron/renderer/glass.css` owns shared colors and materials. Native macOS `under-window` vibrancy supplies desktop blur; translucent renderer surfaces tint it. This is Electron vibrancy, not Apple's newer Liquid Glass API. CSS backdrop blur is used for floating menus inside the app.

The human-facing appearance names are Midnight and Pearl. Stored `black` and `cream` identifiers remain unchanged. Swift native settings and auxiliary dialogs use matching colors and material treatments.

Reduce Transparency and Increase Contrast disable native vibrancy and use an opaque base. CSS respects those settings and Reduce Motion. Existing preview mode provides sample content for checking appearance without changing a real library.
