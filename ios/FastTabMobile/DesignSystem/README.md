# FastTab mobile design system

One warm, quiet "paper" look across every screen. Code: `DSTokens.swift` (values), `DSComponents.swift` (building blocks), `DSToast.swift` (toast).

## Principles
- **Content first.** Link thumbnails and titles carry the color. Chrome stays neutral and warm.
- **One meaning per hue.** A tint always means the same thing (see Tints). Never color something only for decoration.
- **Native where native is best.** Settings-like and long-list screens stay SwiftUI `List`, re-skinned onto the canvas. Feed/discovery screens use cards.
- **Dynamic Type everywhere.** Text uses `DS.Font` styles. A fixed `.system(size:)` is only allowed for SF Symbol sizing (`DS.IconSize`) and tiny overlay badges on images.

## Tokens
| Group | Tokens | Use |
|---|---|---|
| Surfaces | `Palette.canvas` · `surface` · `surfaceMuted` · `hairline` | page → card → chip/placeholder → 1pt outline |
| Special | `deckTop/deckBottom` · `readerPage` · `toastBackground` · `imageScrim` | Tab Switcher (always dark) · Reader · toast · text on photos |
| Space (4-pt grid) | `xxs 2` `xs 4` `sm 8` `md 12` `lg 16` `xl 24` `xxl 32` · `gutter 16` · `section 24` · `floatingBarClearance 72` | page margin is always `gutter` |
| Radius (continuous) | `xs 4` favicon · `sm 8` inner thumb · `md 12` banner/strip · `lg 16` card · `xl 24` hero card · `Capsule` pills | |
| Font | `display` · `sectionTitle` · `cardTitle` · `body` · `meta` · `tag` · `control` · `toast` | |
| Icon size | `row 16` · `inline 28` · `hero 44` | |
| Shadow | `.card` (resting) · `.floating` (toast, bars) | `.dsShadow(_)` |
| Motion | `quick` (selection) · `toast` · `toastDuration 2.5s` | |

## Tints
| Token | Hue | Means |
|---|---|---|
| `action` | accent (blue) | default interactive, primary buttons, tabs |
| `emerging` | purple | AI / Emerging / Intelligence |
| `recent` | teal | opened or read on this iPhone |
| `bookmark` | gold | saved bookmarks |
| `shared` | blue | sent via Share Sheet |
| `warning` | orange | stale, pending, needs confirmation |
| `destructive` | red | delete, errors |
| `success` | green | done, synced |
| `reddit` | Reddit orange | Reddit tiles only |

Tinted fill behind same-tint content: `tint.opacity(DS.tintFillOpacity)` (0.12).

## Components
| Need | Use |
|---|---|
| Page background (custom screen) | `.dsCanvas()` |
| Native list on canvas | `.dsListStyle()` on the List, `.dsListRow()` on each Section |
| Card container | `.dsCard()` |
| Section title + trailing control | `DSSectionHeader("Title", context:) { … }` |
| Count | `DSCountPill(n)` |
| Status / source label | `DSTag(text, tint:, systemImage:)` |
| Filter chip | `DSChip(title, systemImage:, isSelected:) { }` |
| Secondary capsule button | `.buttonStyle(.dsTinted(tint))` |
| Main action | `.buttonStyle(.dsPrimary)` |
| Nothing here | `DSEmptyState(title, systemImage:, message:, tint:, style: .inline / .fullScreen) { actions }` |
| Feedback message | `@State var toast: String?` + `.dsToast($toast)`; set `toast = "…"` |

## Screen patterns
- **Read tab**: section header → one-row carousel of vertical cards (16:10 thumbnail on top, 2-line title, meta line, tag). Card width = 5/9 of the visible width (≈1.8 cards on screen), snaps per card.
- **Lists** (Tabs list, Bookmarks, More, Search, History, Devices…): `insetGrouped` List + `.dsListStyle()` + `.dsListRow()`.
- **Hero cards** (Random deck, Tab Switcher): `Radius.xl`; Tab Switcher keeps its dark deck backdrop in both appearances.
