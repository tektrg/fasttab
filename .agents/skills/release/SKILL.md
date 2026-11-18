---
name: "FastTab Release"
description: "Full release pipeline for FastTab: commit → tag → notarize → distribute → update landing page"
alwaysAllow: ["Bash", "Read", "Edit"]
---

# FastTab Release Skill

End-to-end release flow for FastTab. Two phases: **tag** (GitHub Release) and **distribute** (DMG → users).

---

## Phase 1 — Commit & Tag

```bash
# 1. Commit any pending changes
git add <files>
git commit -m "..."

# 2. Push (release.sh requires main == origin/main)
git push origin main

# 3. Tag and trigger GitHub Release
scripts/release.sh <VERSION>   # e.g. scripts/release.sh 1.6.0
```

`release.sh` runs the full test suite, creates an annotated tag, pushes it. GitHub Actions auto-creates the GitHub Release.

---

## Phase 2 — Switch .env to Production

**Critical step.** `.env` ships sandbox Polar config by default. Before distributing, switch it.

### If production values are already filled in `.env`
Comment out the sandbox block, uncomment the production block.

### If production values are placeholders / missing
Recover them from the last shipped DMG — they're baked into every release's `Info.plist`:

```bash
# Find the most recent DMG in the website repo
ls ../theindieapp_website/public/fasttab/*.dmg | sort -V | tail -1

# Mount it and read the injected Polar values
hdiutil attach <path-to-dmg> -nobrowse -quiet
plutil -p /Volumes/FastTab/FastTab.app/Contents/Info.plist | grep FastTabPolar
hdiutil detach /Volumes/FastTab -quiet
```

Copy the extracted values into `.env` under the `# ── Polar PRODUCTION ──` block.

---

## Phase 3 — Distribute

```bash
scripts/distribute.sh <VERSION> "<release notes shown in Sparkle update banner>"
# e.g.
scripts/distribute.sh 1.6.0 "Brave Browser support, deeper history search, and a reliable app relaunch fix"
```

Always run it with `--dry-run` first: it lists every step and any **release blockers**, then exits 3 if there are blockers (a real run stops before building on any blocker).

Steps:
1. Checks: Developer ID cert, notary credentials, `../IndieLibKit/scripts/indie-mac-release.sh`, and release blockers: bundle id must stay `com.trungluong.FastTab`, `SUFeedURL`, `fasttab://` URL scheme, `SUPublicEDKey` (Info.plist or `.env` `SPARKLE_PUBLIC_ED_KEY`), appcast valid XML and without this version, embedded `Sparkle.framework` = linked Sparkle (2.9.1)
2. Release copy of `dist/FastTab.app` (dist itself is never modified): version, Polar + support/pricing values from `.env`; release entitlements derived from `dist/FastTab.entitlements` (drops `get-task-allow` and dev-only keys; iCloud/push keys only with an embedded **Developer ID** profile; a Development profile is left out). No iCloud entitlement = blocker (the app opens CloudKit at launch)
3. `swift build -c release`, copy the 3 executables, reader resources, resource bundles, rpath
4. Shared `indie-mac-release.sh`: sign inside-out (helpers without entitlements) → notarize + staple app → DMG → sign, notarize, staple DMG → Gatekeeper check → Sparkle EdDSA signature (keychain account `ed25519`) → item inserted into `../theindieapp_website/public/fasttab/appcast.xml`
5. DMG copied to `../theindieapp_website/public/fasttab/`, `version.json` written
6. `npm run build` + `wrangler pages deploy` of the website

Output: `dist/release/FastTab.app` (signed), `dist/release/FastTab-<VERSION>.dmg`, `dist/release/appcast-item-<VERSION>.xml`.

Users receive the update automatically via Sparkle on next check.

---

## Phase 4 — Update Landing Page

File: `../theindieapp_website/src/pages/fasttab/index.astro`

Changes needed per release:
- `const VERSION` — bump to new version
- `title` / `description` / hero paragraph — reflect new capabilities
- `coreFeatures` array — update feature bullets
- `browserSources` array — add/update browser entries if browsers changed
- `searchIntents` array — keep in sync with browser list
- Header badge (`"Safari, Chrome & Edge"`) — update browser list
- "Search coverage" `<h2>` and paragraph — update if browsers changed
- **"Latest release" section** — new version, new date, new feature cards

Then commit + push the website repo separately.

---

## Version Numbering Convention

| Change type | Bump |
|-------------|------|
| New browser support or major feature | minor (1.5.x → 1.6.0) |
| Enhancements, limit increases, UX fixes | patch (1.6.0 → 1.6.1) |
| Breaking changes / major redesign | major |

---

## Prerequisites (already set up — no action needed)

- Developer ID Application cert in Keychain: `Developer ID Application: Trung Luong (56S46Y7CKN)`
- Notary auth: `.env` `FASTTAB_APPLE_ID` / `FASTTAB_APPLE_TEAM_ID` / `FASTTAB_APPLE_APP_PASSWORD`, or `NOTARY_KEYCHAIN_PROFILE` (a `xcrun notarytool store-credentials` profile, preferred)
- Sparkle EdDSA private key in Keychain (public key in `.env`)
- `wrangler` configured in `../theindieapp_website/`
- `../theindieapp_website/` and `../IndieLibKit/` cloned at those relative paths

---

## Quick Checklist

- [ ] All changes committed and pushed to `origin/main`
- [ ] `.env` has production Polar block active (not sandbox)
- [ ] `scripts/distribute.sh <VERSION> "<notes>" --dry-run` shows no release blockers
- [ ] `scripts/release.sh <VERSION>` succeeded (all tests green, tag pushed)
- [ ] `scripts/distribute.sh <VERSION> "<notes>"` succeeded (notarized, DMG in website)
- [ ] Landing page updated and deployed (version, copy, release notes)
