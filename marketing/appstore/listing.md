# FastTab Reader — App Store listing (iOS, first submission)

App: `app.theindie.FastTabMobile` · team `56S46Y7CKN` (The Indie App) · version 1.0.0 (build 1) · **iPhone only**.
Media: `en/fasttab-reader-*.png` (1320x2868, 6 shots) · `creative/en/` (iOS 27 header + search) · no preview video.
Regenerate: `tools/capture.sh` → appstore-media `render.sh tools` + `creative.sh tools` (see `~/.claude/skills/appstore-media`).
Lead message (owner, 2026-10-30): **read later + sync with your Mac's browser tabs and bookmarks.**

## en-US

**Name** (14/30): `FastTab Reader`

**Subtitle** (27/30): `Read later, synced with Mac`

**Promotional text** (63/170, owner-approved):
> Read it later, sync with your Mac's browser tabs and bookmarks.

**Keywords** (98/100 bytes, `printf %s "$k" | wc -c`; name/subtitle words not repeated):
`later,article,highlight,reading,list,sync,tabs,bookmarks,browser,safari,chrome,offline,save,icloud`
(`safari`/`chrome` = supported browsers, not competitors; drop them if review objects.)

**Description** (≤4000):
```
FastTab Reader brings the tabs and bookmarks from your Mac's browsers to your iPhone, and gives you a calm place to read them.

YOUR MAC'S TABS ON YOUR IPHONE
With FastTab for Mac, the tabs open in Safari, Chrome, Brave and Edge show up on your iPhone, grouped by Mac and browser. Search them, open any one in Reader, or close it on your Mac from your phone.

YOUR BROWSER BOOKMARKS, SYNCED
Your Mac's bookmarks arrive with their folders, ready to browse and search. Bookmarks you haven't opened in a while come back on the Read tab.

SAVE IT NOW, READ IT LATER
Share any link to FastTab from Safari or any app. It lands in your FastTab List, on every device you use FastTab on.

READ WITHOUT THE CLUTTER
Open an article and FastTab strips away ads, pop-ups and sidebars, leaving one clean column of text. Pick your font, size and spacing. Close it halfway and it picks up where you stopped. Read Aloud plays any article out loud.

KEEP WHAT MATTERS
Long-press to highlight a passage in one of four colours, tag it, and add a comment. Every highlight is collected in one searchable place, linked back to its article.

SEE HOW YOU READ AND BROWSE
Weekly charts of words read, articles finished and highlights, plus how many tabs you keep open on your Macs.

PRIVATE BY DESIGN
Tabs, bookmarks, your list and highlights sync through your own iCloud account. No sign-up needed. An optional Sign in with Apple account is used only for YouTube transcripts.

NO MAC? NO PROBLEM
FastTab Reader works on its own as a read-later app. Add FastTab for Mac any time and your tabs and bookmarks appear.

Privacy policy: https://fasttab.theindie.app/privacy
```

**Support URL**: https://theindie.app/support (200) · **Marketing URL**: https://fasttab.theindie.app/ (200) · **Privacy URL**: https://fasttab.theindie.app/privacy (200, but **Mac-only text, see Privacy below**).

**Screenshot captions** (`tools/captions.json`): 1 YOUR MAC'S TABS ON YOUR IPHONE · 2 YOUR BROWSER BOOKMARKS, SYNCED · 3 READ THEM WITHOUT THE CLUTTER · 4 EVERY HIGHLIGHT IN ONE PLACE · 5 SAVE IT NOW. READ IT LATER. · 6 SEE HOW YOU READ AND BROWSE.

## Verified claims
| Claim | Evidence (code) | Status |
| --- | --- | --- |
| **Mac browser tabs on iPhone** | Mac `SyncService` publishes `SyncedTab` (title, URL, browser, window) to CloudKit; iPhone `LocalCache.updateTab` → `TabListView` | ✅ **needs FastTab for Mac** running |
| Browsers: Safari, Chrome, Brave, Edge | Mac browser enum (`case safari/chrome/brave/edge`) | ✅ |
| **Bookmarks synced, with folders** | Mac `SyncService.updateBookmarks` → `SyncedBookmarkBlob` per browser/profile with `folderPath`; iPhone `BookmarkTreeView` | ✅ needs FastTab for Mac |
| Close a Mac tab from iPhone | P2 remote close (`closeTabWithResult`), `PendingTabCloseStrip` | ✅ |
| Old bookmarks resurface on Read | `RecentAddedProvider` / `EmergingContentProvider` | ✅ |
| FastTab List syncs across devices | `FastTabListSyncBridge`, CloudKit ReaderZone | ✅ |
| Highlights sync | `ReaderHighlightStore` ↔ ReaderZone (`syncedHighlights`) | ✅ |
| History sync | `SyncedHistorySlice` | ✅ (not claimed in copy) |
| "Sync with your browser" without a Mac | — | ❌ **not true**: iPhone never reads a browser directly; sync is Mac browsers → FastTab for Mac → iCloud. Copy says "with FastTab for Mac" / "synced with Mac". |
| Save from share sheet into FastTab List | `FastTabShare/ShareViewController.swift` | ✅ |
| Clean reader, font/size/spacing, resume | `ReaderExtractor`, `ReaderReadingSettings` (8 fonts, size, line height), `ReaderReadingProgress` | ✅ |
| Read Aloud | `Reader/ReadAloud/` | ✅ |
| 4 colours, tags, comments, searchable highlights | `HighlightColor`, `ReaderHighlight.tags`, `ReaderCommentThreads`, `HighlightsListView` | ✅ |
| Reading + tab stats | `ReadingStatsCard`, `TabStatsCard` | ✅ (shot 6 = demo data) |
| Sync via user's own iCloud | CloudKit private DB `iCloud.app.theindie.FastTab` | ✅ needs Production schema |
| Sign in with Apple only for YouTube transcripts | `project.yml` comment, `YouTubeTranscriptLoader` reads account token | ✅ |
| Dropped: "end-to-end encrypted" | only CloudKit `encryptedValues` fields | — |

Demo data: fictional sites/authors/articles/tabs (`ios/FastTabMobile/AppStoreDemo.swift`), no real user data, no employer/internal names. Thumbnails stay grey placeholders: the card image loader only accepts http(s) images, so seeding them would mean a code change in `LinkCardImageLoader` (not cheap).

## Privacy
**Current page** (fasttab.theindie.app/privacy, May 2026) covers the **Mac app only** and says "No account data … does not require an account … or third-party login" — **wrong for the iPhone app once Sign in with Apple ships. Must be updated before submission.**

**App Privacy answers (ASC, draft):**
| Data type | Collected | Linked to user | Tracking | Purpose |
| --- | --- | --- | --- | --- |
| Contact Info → Email address (Apple relay or real, only if user shares) | Yes | Yes | No | App Functionality (account) |
| Contact Info → Name (if user shares in Sign in with Apple) | Yes | Yes | No | App Functionality |
| Identifiers → User ID (Apple user id / theindie account id) | Yes | Yes | No | App Functionality |
| Other: device name (sent with account sign-in, `AccountSession.live(deviceName:)`) | Yes (Other Data) | Yes | No | App Functionality |
| Tabs, bookmarks, history, list, highlights | **Not collected** (user's own iCloud private DB; developer has no access) | — | — | — |
Owner/engineer to confirm: what theindie-api stores for a YouTube transcript request (video ID? logged?) — if stored with the account, add "Usage Data / Other" for App Functionality.

**Draft text to add to the privacy page (not published):**
```
FastTab Reader for iPhone

Synced through your iCloud. Tabs, bookmarks and history from FastTab for Mac, your FastTab List,
reading progress and highlights sync between your devices through your own private iCloud
database. We cannot read this data; Apple stores it under your Apple Account.

Optional account. You can sign in with Apple to use YouTube transcripts. If you do, our account
server (api.theindie.app) stores your Apple user identifier, the email address Apple shares with
us (which may be a private relay address), your name if you choose to share it, and the name of
your device. We use this only to run your account and the features that need it. We do not sell
it, use it for advertising, or track you across apps. You can delete your account in
More → theindie account, which removes this data from our server.

On-device. Reading statistics and Read Aloud run on your iPhone and are not sent to us.
```
(In-app account deletion verified: `AccountSettingsView` "Delete your account?".)

## Pre-submit checklist (status 2026-10-29; nothing written to App Store Connect)
- [x] New icon committed full-bleed (`8effec4`), owner approval of the exact PNG pending
- [ ] **CloudKit**: deploy `iCloud.app.theindie.FastTab` schema to Production; entitlements say `Development` (`icloud-container-environment`, `aps-environment`) — confirm the archive/export flips both to Production.
- [ ] ASC app record exists for `app.theindie.FastTabMobile` with name "FastTab Reader" (name must be free)
- [ ] Archive + upload build 1.0.0 (1), iPhone only; Release build signed for distribution
- [ ] **Privacy page updated** with the iPhone section (draft above) and published
- [ ] App Privacy (web): answers per the table above (Sign in with Apple stays in v1), then Publish
- [ ] Age rating · category (Primary: News or Productivity / Secondary: Books) · content rights · copyright "2026 The Indie App"
- [ ] Review contact incl. phone; review notes: "No login needed; share any link to FastTab, open it from Read"
- [ ] Pricing (Free per memory decision) · availability
- [ ] `UIBackgroundModes: audio` justified by Read Aloud (mention in review notes)
- [ ] Screenshots uploaded `--device-type IPHONE_67`; creative assets via web
- [ ] `asc review doctor` → 0 blockers · release = manual · owner submits
