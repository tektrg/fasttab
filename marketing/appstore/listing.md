# FastTab Reader — App Store listing (iOS, first submission)

**ASC** (2026-10-30): app `6828689539` · version 1.0.0 `ef3b6053-b4be-417a-a78e-b85fa0908423` (release MANUAL) · TestFlight build **3** attached (Natural Voice subscription: group 22528006, subs 6828734343 monthly / 6828734519 yearly) · App Privacy draft = `app-privacy.json` (applied, not published). Check: `ASC_PROFILE=CraftAgentApstoreConnect asc validate --app 6828689539 --version 1.0.0 --platform IOS`.

App: `app.theindie.FastTabMobile` · team `56S46Y7CKN` (The Indie App) · version 1.0.0 (build 1) · **iPhone only**.
Media: `en/fasttab-reader-*.png` (1320x2868, 9 shots) · `creative/en/` (iOS 27 header + search) · no preview video.
Regenerate: `tools/capture.sh` → appstore-media `render.sh tools` + `creative.sh tools` (see `~/.claude/skills/appstore-media`).
Lead message (owner, 2026-10-30): **read later + sync with your Mac's browser tabs and bookmarks.**

## en-US

**Name** (14/30): `FastTab Reader`

**Subtitle** (27/30): `Read later, synced with Mac`

**Promotional text** (63/170, owner-approved):
> Read it later, sync with your Mac's browser tabs and bookmarks.

**Keywords** (99/100 bytes, `printf %s "$k" | wc -c`; name/subtitle words not repeated):
`article,highlight,reading,youtube,transcript,listen,audio,tabs,bookmarks,browser,safari,chrome,save`
(`later` dropped: already in the subtitle, `asc validate` warns on overlap. 2026-10-30: `list,sync,offline,icloud,news` swapped for `youtube,transcript,listen,audio`; `sync` is covered by the subtitle's "synced". `tts` skipped: users don't type it.)
(`safari`/`chrome` = supported browsers, not competitors; drop them if review objects.)

**Description** (≤4000):
```
FastTab Reader brings the tabs and bookmarks from your Mac's browsers to your iPhone, and gives you a calm place to read them.

YOUR MAC'S TABS ON YOUR IPHONE
With FastTab for Mac, the tabs open in Safari, Chrome, Brave and Edge show up on your iPhone, grouped by Mac and browser. Search them, open any one in Reader, or close it on your Mac from your phone.

YOUR BROWSER BOOKMARKS, SYNCED
Your Mac's bookmarks arrive with their folders, ready to browse and search. Bookmarks you haven't opened in a while come back on the Read tab.

SWIPE THROUGH WHAT YOU SAVED
Shuffle deals your bookmarks, open tabs, highlights and saved links as cards. Swipe left to skip one until tomorrow, swipe right to open it or file it in a bookmark folder.

SAVE IT NOW, READ IT LATER
Share any link to FastTab from Safari or any app. It lands in your FastTab List, on every device you use FastTab on.

READ WITHOUT THE CLUTTER
Open an article and FastTab strips away ads, pop-ups and sidebars, leaving one clean column of text. Pick your font, size and spacing. Close it halfway and it picks up where you stopped.

READ YOUTUBE AS AN ARTICLE
Open a YouTube link and read the video's captions as a clean, timestamped transcript. Tap any timestamp to play the video from that moment. Transcripts need a free Sign in with Apple account and a video that has captions.

LISTEN TO YOUR ARTICLES
Read Aloud reads any article or transcript to you with your iPhone's built-in voices, highlighting the sentence it's on. It keeps playing with the screen locked or in another app, with play and pause on the Lock Screen. Choose a speed from 0.75x to 2x and pick a voice; download Enhanced or Premium voices in iOS Settings for the most natural sound. Built-in voices are free, with no account.

NATURAL VOICE (OPTIONAL SUBSCRIPTION)
Want a more human-sounding voice? Natural Voice streams lifelike cloud voices for Read Aloud. $4.99 per month or $39.99 per year, each with a 7-day free trial, with a fair-use monthly listening allowance. Needs a free Sign in with Apple account. Payment is charged to your Apple Account; the subscription renews automatically unless cancelled at least 24 hours before the period ends. Manage or cancel in Settings › Apple Account › Subscriptions.

KEEP WHAT MATTERS
Long-press to highlight a passage in one of four colours, tag it, and add a comment. Every highlight is collected in one searchable place, linked back to its article.

SEE HOW YOU READ AND BROWSE
Weekly charts of words read, articles finished and highlights, plus how many tabs you keep open on your Macs.

PRIVATE BY DESIGN
Tabs, bookmarks, your list and highlights sync through your own iCloud account. No sign-up needed. An optional Sign in with Apple account is used only for YouTube transcripts.

NO MAC? NO PROBLEM
FastTab Reader works on its own as a read-later app. Add FastTab for Mac any time and your tabs and bookmarks appear.

Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy policy: https://fasttab.theindie.app/privacy
```

**Support URL**: https://theindie.app/support (200) · **Marketing URL**: https://fasttab.theindie.app/ (200) · **Privacy URL**: https://fasttab.theindie.app/privacy (200, but **Mac-only text, see Privacy below**).

**Screenshot captions** (`tools/captions.json`): 1 YOUR MAC'S TABS ON YOUR IPHONE · 2 READ YOUTUBE AS AN ARTICLE · 3 LISTEN TO YOUR ARTICLES · 4 SWIPE THROUGH WHAT YOU SAVED · 5 READ THEM WITHOUT THE CLUTTER · 6 YOUR BROWSER BOOKMARKS, SYNCED · 7 EVERY HIGHLIGHT IN ONE PLACE · 8 SAVE IT NOW. READ IT LATER. · 9 SEE HOW YOU READ AND BROWSE.

## Verified claims
| Claim | Evidence (code) | Status |
| --- | --- | --- |
| **Mac browser tabs on iPhone** | Mac `SyncService` publishes `SyncedTab` (title, URL, browser, window) to CloudKit; iPhone `LocalCache.updateTab` → `TabListView` | ✅ **needs FastTab for Mac** running |
| Browsers: Safari, Chrome, Brave, Edge | Mac browser enum (`case safari/chrome/brave/edge`) | ✅ |
| **Bookmarks synced, with folders** | Mac `SyncService.updateBookmarks` → `SyncedBookmarkBlob` per browser/profile with `folderPath`; iPhone `BookmarkTreeView` | ✅ needs FastTab for Mac |
| Close a Mac tab from iPhone | P2 remote close (`closeTabWithResult`), `PendingTabCloseStrip` | ✅ |
| Shuffle: cards from bookmarks, tabs, highlights, saved links; left = skip until tomorrow, right = open (highlight/saved link) or Move to/Save to folder | `RandomLinksView` (`RandomCardSource`, `RandomFeedSkipStore`, stamps OPEN / MOVE TO / SKIP) | ✅ (reader-only phone: saved links only) |
| Old bookmarks resurface on Read | `RecentAddedProvider` / `EmergingContentProvider` | ✅ |
| FastTab List syncs across devices | `FastTabListSyncBridge`, CloudKit ReaderZone | ✅ |
| Highlights sync | `ReaderHighlightStore` ↔ ReaderZone (`syncedHighlights`) | ✅ |
| History sync | `SyncedHistorySlice` | ✅ (not claimed in copy) |
| "Sync with your browser" without a Mac | — | ❌ **not true**: iPhone never reads a browser directly; sync is Mac browsers → FastTab for Mac → iCloud. Copy says "with FastTab for Mac" / "synced with Mac". |
| Save from share sheet into FastTab List | `FastTabShare/ShareViewController.swift` | ✅ |
| Clean reader, font/size/spacing, resume | `ReaderExtractor`, `ReaderReadingSettings` (8 fonts, size, line height), `ReaderReadingProgress` | ✅ |
| Read Aloud (any article or transcript), sentence highlight | `ReadAloudController`, `ReadAloudPageSync` | ✅ |
| Voices = iPhone's built-in voices; Enhanced/Premium if downloaded | `AppleSpeechEngine` (`AVSpeechSynthesizer`), `ReadAloudVoiceSelector` quality ranking; settings text "Download Enhanced or Premium voices…" | ✅ |
| "Natural (cloud) voice" | `GoogleSpeechEngine` via theindie-api `/v1/tts` — **gated `AppDistribution.isDebugOrTestFlight`** | ❌ **not in App Store build**: copy must not promise it |
| Plays in background / screen locked | `UIBackgroundModes: audio`, `AVAudioSession .playback/.spokenAudio` | ✅ |
| Lock Screen play/pause | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` play/pause/toggle (no skip/scrub) | ✅ play/pause only |
| Speed 0.75x–2x, voice picker | `ReaderReadingSettings.speechRateOptions [0.75,1,1.25,1.5,2]`, `ReadAloudViews` Speed/Voice pickers | ✅ |
| **YouTube → readable transcript** | `YouTubeTranscriptLoader` (theindie-api `/v1/youtube/transcript`, on-device fallback on bot check/502), `TranscriptArticleBuilder` | ✅ |
| Transcript needs sign-in | no token → `TranscriptError.notSignedIn` → "needs account" screen | ✅ **free Sign in with Apple required** |
| Only videos with captions | `TranscriptError.noCaptions` | ✅ (copy says "has captions"; "any video" dropped) |
| Tap timestamp → video plays there | `reader_template.html` transcript player, `data-start-ms` | ✅ |
| 4 colours, tags, comments, searchable highlights | `HighlightColor`, `ReaderHighlight.tags`, `ReaderCommentThreads`, `HighlightsListView` | ✅ |
| Reading + tab stats | `ReadingStatsCard`, `TabStatsCard` | ✅ (shot 6 = demo data) |
| Natural Voice subscription $4.99/mo or $39.99/yr, 7-day trial, fair-use cap | `Config/FastTab.storekit`, ASC subs 6828734343 / 6828734519 (intro FREE_TRIAL ONE_WEEK ×175); server `TTS_SUBSCRIBER_CHARS_PER_MONTH` 80,000 (theindie-api, not deployed) | ✅ once server deployed |
| Built-in voices free, no account | `NaturalVoiceGate` (only the cloud engine is gated) | ✅ |
| Sync via user's own iCloud | CloudKit private DB `iCloud.app.theindie.FastTab` | ✅ needs Production schema |
| Sign in with Apple only for YouTube transcripts | `project.yml` comment, `YouTubeTranscriptLoader` reads account token | ✅ |
| Dropped: "end-to-end encrypted" | only CloudKit `encryptedValues` fields | — |

Demo data: fictional sites/authors/articles/tabs (`ios/FastTabMobile/AppStoreDemo.swift`), no real user data, no employer/internal names. Card thumbnails are generated illustrations bundled in Debug only (`ios/FastTabMobile/AppStoreDemo/demo-thumb-*.png`, excluded from Release).

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
