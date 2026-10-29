# FastTab Reader — App Store listing (iOS, first submission)

App: `app.theindie.FastTabMobile` · team `56S46Y7CKN` (The Indie App) · version 1.0.0 (build 1) · **iPhone only**.
Media: `en/fasttab-reader-*.png` (1320x2868, 4 shots) · `creative/en/` (iOS 27 header + search) · no preview video.
Regenerate: `tools/capture.sh` → appstore-media `render.sh tools` + `creative.sh tools` (see `~/.claude/skills/appstore-media`).

## en-US

**Name** (14/30): `FastTab Reader`

**Subtitle** (≤30) — owner picks one:
| Option | Chars | Angle |
| --- | --- | --- |
| A `Read later, without clutter` | 27 | broad read-later search terms (recommended) |
| B `Clean reader & highlights` | 25 | highlights angle |
| C `Save articles, read them calm` | 29 | calm reading |

**Promotional text** (≤170):
> Save any article from the share sheet and read it later in one quiet column. Highlight the lines worth keeping and find them all in one place.

**Keywords** (≤100 bytes, no spaces after commas; name/subtitle words not repeated):
`later,article,highlight,reading,list,pocket,instapaper,offline,distraction,focus,save,web,clean,text`
(100 bytes, at the limit — `printf %s "$k" | wc -c`). Owner: competitor names (`pocket`, `instapaper`) are allowed as keywords but Apple sometimes rejects them; drop them if you want zero risk.

**Description** (≤4000):
```
FastTab Reader is a calm place for the articles you meant to read.

SAVE IT NOW
Share any link to FastTab from Safari or any app. It lands in your FastTab List, ready when you have a quiet moment.

READ WITHOUT THE CLUTTER
Open an article and FastTab strips away ads, pop-ups and sidebars, leaving one clean column of text. Pick your font, size and spacing. Close it halfway and it picks up where you stopped.

LISTEN WHEN YOUR EYES ARE BUSY
Read Aloud plays any article out loud.

KEEP WHAT MATTERS
Long-press to highlight a passage in one of four colours, tag it, and add a comment. Every highlight is collected in one searchable place, linked back to its article.

REDISCOVER
Shuffle deals out random cards from everything you saved. Home Screen widgets show what is up next and how close you are to your daily reading goal.

SEE HOW MUCH YOU READ
Weekly charts of words read, articles finished and highlights, by topic.

PRIVATE BY DESIGN
No sign-up needed to read. Your list and highlights sync between your devices through your own iCloud account.

HAVE A MAC?
FastTab for Mac is optional. Connect it and your open Mac tabs appear on your iPhone too.

Privacy policy: https://fasttab.theindie.app/privacy
```

**Support URL**: https://theindie.app/support (200) · **Marketing URL**: https://fasttab.theindie.app/ (200) · **Privacy URL**: https://fasttab.theindie.app/privacy (200 — content must be checked for iOS, see below).

**Screenshot captions** (`tools/captions.json`): 1 READ WITHOUT THE CLUTTER · 2 EVERY HIGHLIGHT IN ONE PLACE · 3 SAVE IT NOW. READ IT LATER. · 4 SEE HOW MUCH YOU READ.

## Verified claims
| Claim | Evidence (code) | Status |
| --- | --- | --- |
| Save from share sheet into FastTab List | `FastTabShare/ShareViewController.swift`, `SavedOnIPhoneStore` pending saves | ✅ |
| Clean reader, no ads/sidebars | `Reader/ReaderExtractor.swift` (Readability), `reader_template.html` | ✅ |
| Font / size / spacing choice | `Reader/ReaderReadingSettings.swift` (8 system fonts) | ✅ |
| Resumes where you stopped | `ReaderReadingProgress`, onboarding sample article states it | ✅ |
| Read Aloud | `Reader/ReadAloud/` | ✅ |
| 4 highlight colours, tags, comments | `HighlightColor` (yellow/green/blue/pink), `ReaderHighlight.tags`, `ReaderCommentThreads` | ✅ |
| All highlights searchable in one place | `Views/HighlightsListView.swift` (search field) | ✅ |
| Shuffle | `Views/RandomLinksView.swift` | ✅ |
| Widgets: Up Next, Reading Ring (daily goal), Shuffle | `FastTabWidgets/` | ✅ |
| Weekly reading stats by topic | `Stats/`, `Views/Stats/ReadingStatsCard.swift` | ✅ (shot 4 uses demo data) |
| No sign-up to read | reader-only mode works signed out; account only for YouTube transcripts (`FastTabMobile/Account/`) | ✅ |
| Sync via user's own iCloud | CloudKit private DB `iCloud.app.theindie.FastTab` (list via ReaderZone) | ✅ — needs Production CloudKit schema |
| Mac tabs on iPhone (optional) | `TabListView`, `AppMode` mac mode | ✅ |
| Dropped: "end-to-end encrypted" | true for CloudKit `encryptedValues` fields only; not claimed to avoid over-claiming | — |
| Dropped: YouTube transcripts / AI clean-up | needs account + server; AI reformat gated off (`PowerUpGate`) | — |

Demo data: fictional sites/authors/articles written for the shots (`ios/FastTabMobile/AppStoreDemo.swift`), no real user data, no employer/internal names.

## Pre-submit checklist (status 2026-10-29; nothing written to App Store Connect)
- [ ] **New icon committed** — new "fast tab reader" icon is only an uncommitted edit on the Pro (another session); Air + git still have the old swirl. Its art has a baked-in rounded square + border inside the 1024 canvas → iOS masks it again (double frame). Re-export full-bleed.
- [ ] **CloudKit**: deploy `iCloud.app.theindie.FastTab` schema to Production; entitlements say `Development` (`icloud-container-environment`, `aps-environment`) — confirm the archive/export flips both to Production.
- [ ] ASC app record exists for `app.theindie.FastTabMobile` with name "FastTab Reader" (name must be free)
- [ ] Archive + upload build 1.0.0 (1), iPhone only; Release build signed for distribution
- [ ] Privacy policy page covers the iPhone app (iCloud sync, Sign in with Apple account for transcripts, no tracking)
- [ ] App Privacy (web): likely "Data not collected" except account (email/user ID, linked, app functionality) if Sign in with Apple stays in v1
- [ ] Age rating · category (Primary: News or Productivity / Secondary: Books) · content rights · copyright "2026 The Indie App"
- [ ] Review contact incl. phone; review notes: "No login needed; share any link to FastTab, open it from Read"
- [ ] Pricing (Free per memory decision) · availability
- [ ] `UIBackgroundModes: audio` justified by Read Aloud (mention in review notes)
- [ ] Screenshots uploaded `--device-type IPHONE_67`; creative assets via web
- [ ] `asc review doctor` → 0 blockers · release = manual · owner submits
