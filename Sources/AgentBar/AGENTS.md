# AgentBar — agent notes

Native Mac agent switcher (⌥Tab panel) over the AptusFit **chief dashboard** (`127.0.0.1:4711`). Separate app/target from FastTab; shares only `CommandBarKit`. Rules: edits stay in `Sources/AgentBar` + `Tests/AgentBarTests`; `FastTab` / `CommandBarKit` diffs must be empty unless the task says otherwise.

## Build / test / run
- App: `scripts/build-agentbar-app.sh --open` (→ `dist/AgentBar.app`). Do this after every change.
- Tests: `swift test --filter AgentBarTests` (~655). Full-suite runs flake under machine load; re-run the failing test alone before believing it.
- Own defaults domain `com.trungluong.AgentBar`. Unsandboxed.

## What it does (user vocabulary → code)
| User says | Code / concept |
|---|---|
| "Needs you" | generic: agent live and not working, until Done or Park |
| "Blocked" row | dashboard `needsYou` kind `question` (picker) / `blocked` (permission box) |
| **Answer** button | red; opens answer card for a parsed picker (`Answer/`) |
| **Review** button | red; opens permission card: Allow / Allow always (2nd press) / Deny (`Permission/`) |
| **Open terminal** | fallback when the box can't be parsed / non-Claude agents |
| Done / Park | triage (`Triage/`); Done = dashboard stop then close (two steps); Park persisted |
| "peek at bottom-right" | **corner tab** (`Corner/`, setting `showsCornerTab`); NOT Space-to-peek (`Peek/`, `PanePeek`) |

## Data source
- `/api/events` (SSE) → `/api/state`; actions: `POST /api/focus`, `/api/session/{stop,close}` (actor "po"), `/api/answer`, `/api/permission`; `GET /api/pane/screen?paneId=` (read-only, ~2.5s).
- Never herdr `agent_status`. **Never POST to the real dashboard in tests** — use a fake dashboard on another port.
- Detection lag ≤15s (screen sweep). Dashboard row flaps between parsed picker / hook preview / plain blocked → `BlockerMemory` (45s) keeps Answer/Review steady.

## Gotchas (each cost a live-check round)
1. **Wrapped screen vs exact match.** Feed shows the screen as drawn (wrapped/cut); `/api/answer` and `/api/permission` match the *unwrapped* text exactly. AgentBar does a **pre-send read** (GET pane, re-parse, echo the pane's version). Parsers are Swift ports of the dashboard's Python (`parse_question_block`, `parse_permission_block` in AptusFit `scripts/lib/classify_pane.py`), differential-tested against real Python via fixtures (`Tests/AgentBarTests/Fixtures/*-screens.json`). If the dashboard parser changes, regenerate fixtures and re-port.
2. Card error "unknown command: herdr" = the *dashboard* pane read is broken/stale, not AgentBar. Restart the dashboard after pulling AptusFit changes (old process keeps old code).
3. Dashboard collapses newlines to spaces (500-char cap): Shift+Enter in the custom answer is a visual newline only.
4. Feed decoding is per entry (`unreadableFeedNames`); one odd key (e.g. `machinesConfigError: null`) must not fail the whole state → false "status feed down".
5. Latest message: tail of `~/.claude/projects/*/<agentSession>.jsonl` (last assistant text block; transcripts reach 130MB, tail-read only). Plan link = best-effort last existing `.md` `file_path`, skipping SKILL/CLAUDE/AGENTS/README/MEMORY.md and /tmp.
6. Send closes the card at once; the row shows a spinner (20s safety timeout); failures show verbatim in the footer for 8s.
7. Alt-tab release = 20ms poll of `NSEvent.modifierFlags` (non-activating panel, no Accessibility permission).

## Known deferred
Footer notice doesn't pause on hover; dashboard classifier reads non-Claude prompts (opencode/codex/gemini) as UNKNOWN; optional `transcript_path` in the hook sidecar; `aSwitchFailureShowsAFooterNoticeThatClearsItself` needs an injectable clock; kit-dedupe candidates (ShortcutRecorderField, LaunchAtLoginService, MenuBarItemController, Settings shell, PaneScreenText); stale `Package.swift` comment "Read-only agent switcher".

## Live-check protocol (what worked)
Test against a real agent pane in a scratch herdr tab (e.g. `test-perm`); prefer **Deny**/no-op choices on real boxes; verify dashboard behaviour with GET only.
