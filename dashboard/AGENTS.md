# dashboard/

The agent-supervision dashboard: a stdlib-only Python HTTP server that polls
herdr panes (local + configured remote machines), classifies each pane's
screen state, and serves a JSON/SSE API + a React/Vite SPA the PO watches
plus AgentBar (`Sources/AgentBar`, this repo) and any project's own MCP
tools consume. Moved here from AptusFit in the P0 dashboard move — see
`.claude/briefs/dashboard-move/` in this repo's main worktree for the full
move plan; this file is the day-to-day reference for running/testing it.

## Layout
- `server/chief-dashboard-server.py` — the HTTP server (stdlib `http.server`,
  no framework, no third-party deps).
- `server/lib/` — everything the server imports: herdr/ssh transport
  (`chief_dashboard_herdr.py`), screen classification (`classify_pane.py`,
  `pane_screen_signals.py`), the agent hierarchy store (`agent_tree.py`), the
  generic board store (`chief_dashboard_store.py` — properties/views/links/
  session rows; the work-item board itself was retired, not moved), feeds/
  views/actions/memory modules, `chief_dashboard_pass.py` (`GET
  /api/deliver/pass` — see "chief_pass" below), `personas.py` (`GET
  /api/personas` — see "Jev persona routing" below), `persona_start.py`
  (`POST /api/persona/start`, same section), `jev_route.py` (`POST
  /api/jev/route`, same section), `message_gate.py` (non-Claude panes are
  never messaged — see "Claude sessions outside herdr"), and
  `dashboard_config.py` (below).
- `scripts/restart.sh` — kill-and-relaunch by port ownership, with a
  liveness wait; `scripts/chief-dashboard-watchdog.py` — a 60s probe/
  restart-cap script meant for a LaunchAgent (none is installed by this
  move — see "Not done in P0" below); `scripts/parity-check.py` — compares
  this server's agent rows against another instance's (used to verify this
  move; see "Testing" below).
- `tests/` — one `test_*.py` per concern, **not** pytest/unittest: each
  prints `PASS`/`FAIL` lines and calls `sys.exit(1)` on any failure. Run
  each file directly: `python3 tests/test_chief_dashboard_views.py`.
- `ui/` — the React/Vite frontend (separate scope from this move; see its
  own history).
- `hooks/agentbar-permission-hook.py` — the PermissionRequest hook of the
  hook answer bridge (see its section below).
- `chief-question-hook.sh` — a Claude Code hook script (AskUserQuestion
  PreToolUse/PostToolUse) that writes a display-only sidecar file the
  `hookCache` feed reads; install it as a hook in a project's own
  `.claude/settings.json` the same way AptusFit does, this file is just the
  payload.
- `config.example.json` — copy to `~/.config/agent-dashboard/config.json`
  and edit (see "Config and state" below). Not loaded automatically.

## Config and state (design call: `REPO_ROOT` split three ways)
The old AptusFit-only server had one hardcoded `REPO_ROOT`. This copy splits
that into three things (`server/lib/dashboard_config.py`):

| | Location | Holds | Override |
|---|---|---|---|
| Code | `dashboard/` (this folder, wherever it's checked out) | server, tests, scripts, UI build | — |
| Config | `~/.config/agent-dashboard/config.json` | `machines` (Air/remote SSH+herdr config), `projectRoots` (list, v1 default `["~/01_Project/AptusFit"]`), `port` | `CHIEF_DASHBOARD_CONFIG_HOME` (directory) |
| State | `~/Library/Application Support/agent-dashboard/` | the board db + its schema export, the watchdog's failure ledger + fallback log | `CHIEF_DASHBOARD_STATE_HOME` (directory) |

A missing `config.json` is not an error — it boots on defaults (AptusFit,
port 4711), same as before this move. Machines resolve in priority order:
`CHIEF_DASHBOARD_MACHINES` env var (tests) > `config.json`'s own `machines`
key > the legacy `<projectRoots[0]>/.claude/dashboard-machines.json` file
(today's exact historical lookup, kept as the no-config-yet fallback).

**P0 scope note**: `projectRoots` is accepted as a list, but only
`projectRoots[0]` is actually consulted anywhere (herdr cwd, the machines
fallback file, the pane-tick-cache read) — true multi-project support
(looping/merging across roots) is deferred past P0.

## `chief_pass` (`GET /api/deliver/pass`)
Restored 2026-09-25, generic (`server/lib/chief_dashboard_pass.py`) — it was
dropped in the P0 move's first pass (no MOVE-set caller needed it), but the
PO ruled it should be KEPT: AptusFit's chief calls the `chief_pass` MCP tool
(`AptusFit/scripts/chief-board-mcp.py` -> this endpoint) at the start of
every supervision round, and cutover would otherwise break every one of
them. Response shape is byte-compatible with AptusFit's own (`feedHealth`,
`tick`, `panes`, `paneDisagreementCount`, `toolboxMap` — verified against a
live :4711 response; no `mode` key, that field was removed upstream
2026-09-22 and never actually returned by AptusFit's build_chief_pass
despite its MCP tool description text still mentioning one).

Two parts resolve **per `projectRoots` entry**, never hard-coded to
`projectRoots[0]`/AptusFit:
- **`tick`**: AptusFit's `deliver-tick.py --json`, run only when some
  configured project root actually has `scripts/deliver-tick.py`. None do
  -> `tick: null` (not an error — most projects won't have a delivery tick).
- **`toolboxMap`**: the first configured project root's own
  `scripts/chief-board-mcp.py` TOOLS catalogue (name+description only).
  None found, or it fails to import -> `[]`, never a broken chief_pass.

AptusFit's own review-mode plugin loader (`_load_plugin_module`/
`_delivery_ops_shim`) was deliberately not ported — confirmed dead code
even upstream (see `chief_dashboard_pass.py`'s module docstring).

## Jev persona routing (`GET /api/personas`) — P1
`server/lib/personas.py`. Registry: `~/.config/agentbar/personas.json`
(override `AGENTBAR_PERSONAS_FILE` — tests, or a second local instance),
NOT under `~/.config/agent-dashboard/`; AgentBar only edits it through
dashboard endpoints (P4, below — `persona_registry_edit.py` is the one writer). Missing file
-> empty registry; a malformed file or a single bad persona entry is
skipped with a stderr log line, never a crash. A persona with an empty
`description` is a valid registry entry but is never offered (Jev must
never read an unreviewed draft).

Session -> persona mapping: the persona whose folder contains the
session's `cwd`, longest folder match wins, same `machine` only (`local`
for every local session — this dashboard has no separate "pro"/"air" id
for the machine it runs on, only for configured remote machines). Main
session: the persona folder's own live agent-tree chief, else the most
recently active session whose `cwd` is exactly the folder, else none.

Pilots (hand-written, see the file): `chief-aptus` (~/01_Project/AptusFit),
`fasttab-dev` (~/01_Project/command-bar-macos — this repo, FastTab +
AgentBar + this dashboard), `bi` (~/01_Project/ssv-bi-platform),
`portfolio` (~/01_Project — cross-project questions and anything with no
persona of its own yet).

Names are unique among OFFERED personas (hidden/undescribed entries are
filtered first, then a duplicate name keeps the first in registry order).
Each row also carries `idleStart`: `"resume"` | `"fresh"` — what a start
would do right now (see below). Only a local `start: in-place` persona can
be `"resume"`; the folder scan is cached 30s.

**Remote listener** (`server/lib/persona_remote.py`): `GET /api/personas`
returns every offered persona as `[{name, description, idleStart, offline,
mainRowId}]` — no address/folder/instructions/routing hints.
The phone messages a running persona's `mainRowId` through the normal
`POST /api/session/message` rules, and may START any of them (below). PWA: the "Message a persona" sheet
(`ui/src/components/phone/PersonaMessageSheet.tsx`, the `+` in the phone
search bar; effect wording = AgentBar's `PersonaDeliveryEffect`, copied in
`ui/src/personaDelivery.ts`).

### `POST /api/jev/route` (`server/lib/jev_route.py`, 2026-09-28)
Jev (OpenRouter Decisions API) picks the persona for a message ON THE
SERVER, so the phone never holds the key. `{text}` -> `{ok, persona,
confidence}` | `{ok:false, error}`. Candidates: offered, not-offline
personas only (no live sessions). Nothing is sent: the client shows the
pick and the user confirms (AgentBar never auto-sends a persona pick
either). Both listeners (remote: auth + same-origin + audit like every
write); JSON Content-Type required; text follows `validate_message_text`;
only the `text` key. One request in flight, <= 20/min, 8s hard total timeout, never
retried.
- **Key**: `~/.config/agent-dashboard/openrouter-key` (`<CONFIG_HOME>/
  openrouter-key`; tests: `AGENT_DASHBOARD_OPENROUTER_KEY_FILE`), a regular
  file (no symlink), mode 0600, read per request, never logged/returned.
  Missing -> `{ok:false}` saying where to put it. AgentBar's own copy is in
  its Keychain (`KeychainRoutingAPIKeyStore`) — the dashboard can't read it.
- **Duplication** with `Sources/AgentBar/Routing/OpenRouterJevClient.swift`
  (instructions, endpoint, default model, persona summary format):
  `tests/test_jev_route.py` reads the Swift source and fails on drift.
  AgentBar's Settings > Routing guidance and model override are NOT applied
  server-side (UserDefaults, unreadable here).

### Settings > Personas endpoints — P4
All three are **localhost only** (403 on the remote listener); the POST also
needs `Content-Type: application/json` (same gate as `/api/persona/start`).
- `GET /api/personas/suggestions` (`persona_suggestions.py`): `[{address,
  lastActive (epoch s), sessionCount, draftDescription}]`. Recent (30d)
  transcript cwds -> git root (worktree -> main repo); excludes temp dirs
  outside home, `scratchpad` paths, home itself, missing folders, existing
  personas, `hidden`. Draft = AGENTS.md (else CLAUDE.md) opening heading +
  first paragraph, read-only.
- `GET /api/personas/registry`: every persona (hidden/undescribed too) with
  `hidden`/`offered` flags, `globalInstructions`, `defaultGlobalInstructions`,
  `hiddenSuggestions`.
- `POST /api/personas` (`persona_registry_edit.py`): `{action: adopt|edit|
  hide|unhide|remove|setGlobalInstructions, …}` -> `{ok, registry}` or
  `{ok:false, error}`. `adopt` accepts only a current suggestion's address;
  `edit`/`remove` take a persona name or address already in the registry;
  `start`/`startScript` are never editable here; unknown fields in the file
  are kept. Atomic write (temp + rename, 0600) under one lock; a malformed
  file is never overwritten. Tests: `tests/test_persona_registry_edit.py`.

### `POST /api/persona/start` — P3 (`server/lib/persona_start.py`)
Starts or resumes an idle persona's Claude session in a new herdr tab in
its registry folder. **Remote listener: any offered persona** (user
decision 2026-09-28 — the earlier per-persona `"remoteStart": true` opt-in
is gone; a leftover key in personas.json is ignored and no longer editable)
via `persona_remote.start_persona_remote`, after the remote listener's
auth and foreign-Origin checks; a hidden/undescribed/unregistered name gets
`{ok:false, error: "unknown persona …"}` (same wording, so the phone can't
probe names; refusals are path-scrubbed). Security rationale: `server/REMOTE.md`.
The PWA's "Message a persona" sheet
(`ui/src/components/phone/PersonaMessageSheet.tsx`, the `+` in the phone
search bar) uses it. Localhost: every offered persona.
The Settings endpoints below stay localhost-only. Requires `Content-Type: application/json`
(400 otherwise). These early refusals (and the foreign-Origin 403 on every
write) answer before reading the body, so `Handler.end_headers` closes the
connection whenever a body was left unread — otherwise keep-alive would
parse that body as a second, attacker-written request (live-proven
2026-09-26; `tests/test_remote_listener_integration.py`). An interim 1xx
reply (`Expect: 100-continue`'s `100 Continue`, sent before the body
exists) is exempt; the final reply is still checked.

- Request: `{"persona": "<name>", "text": "<first message>", "fresh": true?}`
  — a name, never a path. **Remote listener, stricter**: only the keys
  `persona`/`text`/`fresh`/`confirm`, and `confirm` must be JSON `true`
  (the phone's second press) — folder/command/args always come from the
  registry. The remote audit line's `rowId` is the persona name.
  `text` follows the Send message rules
  (`validate_message_text`: one line, <= 8000 chars, tabs become spaces
  like AgentBar's `TerminalSafeText`, no other terminal control
  characters, no slash command beyond `/clear`/`/compact`). `fresh` must
  be a JSON bool if sent.
- Response (always HTTP 200 past the gates above): `{"ok": true, "paneId":
  "<new pane>", "mode": "started"|"resumed"}` or `{"ok": false, "error":
  "<reason>"}`. Refused: unknown/hidden/undescribed name, `start: script`
  or a remote machine (not built yet), a missing folder, a second start of
  the same persona while one is in flight or within 10s of the last one.
  If herdr fails after the tab opened, the tab is closed again.
- The tab is created with `--env PERSONA_MESSAGE=<text>`; once its shell
  shows output, `herdr pane run` types `claude [--resume <uuid>]
  --append-system-prompt-file=<file> -- "${PERSONA_MESSAGE:?}"`. No user
  text is ever typed (no keystroke/quoting/`=word` risk, no shell history,
  the line stays short); `:?` refuses to run claude if the variable is
  missing. `PERSONA_MESSAGE` stays in that tab's environment (claude and
  its tools inherit it). Shell readiness is a heuristic (any visible
  output, e.g. a MOTD or instant prompt, counts): an rc file that reads
  the keyboard can swallow the line while the endpoint still says ok. The instructions (global block + known persona names
  + the persona's `extraInstructions`) go in
  `<STATE_HOME>/persona-prompts/<name>-<hash>.md` (0600). `--resume <uuid>`
  only when `idle: resume`, not `fresh`, the folder's newest UUID-named
  transcript (`~/.claude/projects/<encoded folder>/`, override
  `CLAUDE_PROJECTS_DIR`) is within `resumeWithinDays`, and that
  conversation isn't already live (any `computed.agents` row: herdr panes
  AND the `claudeSessions` feed's non-herdr sessions). Blind spot: a
  session started seconds ago that no feed has picked up yet — the 10s
  cooldown covers the dashboard's own starts, not someone else's.
- Testing a second instance: `AGENTBAR_PERSONAS_FILE=<throwaway
  personas.json>` + `CHIEF_DASHBOARD_STATE_HOME=<throwaway dir>` +
  `CHIEF_DASHBOARD_CONFIG_HOME=<throwaway dir>` (keeps the remote listener,
  default :4712, off) + `scripts/restart.sh --port <free port, not 4711/
  4712> --detached`; POST only to that port, with a throwaway persona
  folder.

## Claude sessions outside herdr (P4) + OpenCode status fallback (P5)
- `server/lib/claude_sessions.py`, feed `claudeSessions` (3s): reads
  `~/.claude/sessions/<pid>.json` (override `CLAUDE_SESSIONS_DIR`) — every
  running Claude Code process writes one. Dead pid, or a pid whose `procStart`
  (written in UTC) doesn't match `ps`'s start time, is ignored; a bad file is
  skipped. Local machine only (the Air's folder is not read).
- A session whose `sessionId` is already a herdr row's `agentSession` is
  skipped; every other one becomes a paneless **status-only row** in
  `computed.agents`: `source` `claude-desktop` | `claude-cli` (herdr rows carry
  `source: "herdr"`), status in hook words (`busy`→`working`,
  `waiting`→`blocked` + `hookReason` "Input needed", `idle`→`idle`), plus
  `sessionStatus`, `secondsInStatus`, `pid`, `hostSessionId`, `tmuxTarget`,
  `openUrl`, `messageVia`. Stop/close/relaunch are refused (`assess_row`);
  answer/focus refuse a row with no pane; message goes via the inbox (below)
  or is refused ("has no pane"). A `waiting` one is a `blocked`
  needsYou row with `paneId: null`, `identity`/`agentSession` = session id,
  `source`, `openUrl`.
- `transcriptQuestion` `{header, question, questionCount}` | null (row + its
  needsYou entry): a `waiting` session's pending AskUserQuestion read from its
  transcript tail — **display only**, set only when no `hookRequest` holds the
  prompt (hook not installed, dashboard restarted before the re-send, AgentBar
  away). `transcript_pending_question.py`, run by the `claudeSessions` feed on
  `waiting` sessions only: one 256KB tail window, lstat regular files only (no
  symlinks), cached by (path, mtime, size). Permission boxes have no fallback.
- `openUrl` (desktop rows only): `claude://code/continue?session=<hostSessionId>`
  — Claude.app's own handler accepts `local_<id>` there and opens that
  EXISTING session (falls back to Code home, never creates one). Read from
  app.asar's `claudeURLHandler`, not exercised live. The web UI's "Open in
  Claude" (`ui/src/openInClaude.ts`) uses it on a Mac browser; a phone gets
  the generic `https://claude.ai/code` (no per-session web link is recorded
  locally — the Remote Control URL isn't in any file).
- **Message via inbox** (`server/lib/session_inbox.py`, 2026-09-28): every
  row carries `messageVia` — `"pane"` (herdr, typed in), `"inbox"` (a
  status-only session whose file has `entrypoint` cli|claude-desktop,
  `peerProtocol: 1` and a `messagingSocketPath`), else null. `POST
  /api/session/message` on an inbox row (`_handle_inbox_message`) sends
  over Claude Code's own peer socket: line 1 `{"type":"auth","token":
  <peerToken>}`, line 2 `{"type":"user","message":{"role":"user","content":
  <text>}}`. Token from `<pid>.<hash>.key` (0600), read per send, never
  logged/returned/stored. Rules: resolved by `sessionId` on EVERY send (a
  Desktop resume starts a new pid — never cache one); session file, key and
  socket must be owned by this uid, no symlinks, key mode 0600 and not older
  than the process (`procStart`, else `startedAt` − 60s: Claude writes the
  key BEFORE `startedAt`, measured up to 12s on Desktop), exactly one key;
  4s timeout. Accepted =
  0.4s of silence on the open connection; the session hanging up (its
  answer to a bad token — no error line) or an error line = refused,
  nothing sent. Same text rules as the pane path (one line,
  `validate_message_text`) plus: **no slash command at all** (it would
  arrive as text), refused while a prompt is pending (`hookRequest`,
  `transcriptQuestion`, `waiting`/`blocked`), `needsConfirm` while `busy`
  (then state `queued`). Audited like a pane send (`sent`/`queued`; a
  may-have-arrived failure logs `failed`). The session shows it as
  "Another Claude session sent a message: …" — a PEER, not the user: it
  can't approve permissions or answer questions. **Undocumented protocol**
  (measured Claude Code 2.1.283): any other `peerProtocol` is refused
  (`UNSUPPORTED`) rather than guessed. Tests: `tests/test_session_inbox.py`
  (temp sessions dir + fake Unix socket; never a real session),
  `tests/test_remote_inbox_message.py` (real HTTP, both listeners).
- **Non-Claude message gate** (`server/lib/message_gate.py`, 2026-09-28):
  every herdr row carries `agentKind` (herdr's `agent`: `claude`,
  `opencode`, `codex`, …) and `messageRefusal` (text | null). `POST
  /api/session/message` (so Compact/Clear too) refuses a herdr pane whose
  `agentKind` isn't `claude` (or is missing) and that has no hook data,
  before any pane read or keystroke — its prompts are invisible, a message
  could answer one. **Phase 4 (2026-09-29)**: an OpenCode / Codex row with
  fresh exact status (`message_gate.is_tui_row`: `statusSource` matching its
  `agentKind` + `tuiSessionId`) is NOT refused — see "OpenCode / Codex
  messages" below; a best-guess row still is. The PWA shows a caption instead
  of the Composer on refused rows. Tests: `tests/test_message_gate.py`,
  `tests/test_tui_message.py`.
- Every `computed.needsYou` agent row carries `machine` (its agent row's;
  status-only rows `local`) — the phone showed air-m1 prompts as "local".
- P5: for a non-Claude herdr agent (`agent` != `claude`, e.g. OpenCode) whose
  screen reads `UNKNOWN`/nothing, herdr's `agent_status` (`working`/`blocked`/
  `idle`/`done`; `unknown` ignored) stands in as `screenState`
  (`pane_screen_signals.screen_state_with_herdr_fallback`); new field
  `screenStateSource` = `screen` | `herdr` | null. Local rows only.
- OpenCode + Codex screen reads: `server/lib/other_tui_screens.py`
  (`opencode_state`, `codex_state`, `prompt_open`), wired into `classify()` via
  `pane_screen_signals.other_tui_state`. An open question picker / permission
  box / Codex trust picker reads `NEEDS_HUMAN` (same as Claude's);
  `prompt_open(tail)` → `permission` | `question` | None is the gate for
  answering/messaging. Gotchas (live 2026-09-28): OpenCode's question picker
  REPLACES its `╹▀` prompt box (so the old check read it `UNKNOWN`); Codex
  detects by banner / `› Ask Codex…` placeholder / `• Working (… esc to
  interrupt)`; Codex footer shows no context % (use its rollout
  `token_count`); a narrow OpenCode footer cuts `15.3K (1%)` to `15.3K (1%`.
  Permission-box wording for both tools is GUESS (both auto-allowed in-workspace
  writes). Fixtures: `tests/fixtures/panes/*.txt`; test
  `tests/test_other_tui_screens.py`.

## Sleeping Claude Desktop sessions (`computed.sleepingSessions`)
Term: **sleeping session** = a Claude Desktop code session with no running
Claude process (Desktop stops unused ones), so it has no
`~/.claude/sessions/<pid>.json` and no status-only row. `server/lib/desktop_sessions.py`,
feed `desktopSessions` (10s).
- **Stores**: Desktop's own list, `<profile>/claude-code-sessions/<account>/<org>/local_<uuid>.json`
  (org folders also hold `scheduled-tasks.json`, `archived-sessions.idx`,
  `deleted_*`, `backlog/` — not sessions, never read). Profiles globbed:
  `~/Library/Application Support/Claude*/` and `~/.claude-instances/*/`
  (override `CLAUDE_DESKTOP_SESSION_STORES`, pathsep list). Measured
  2026-09-27: the RUNNING Desktop is `--user-data-dir=~/.claude-instances/ssv`
  (~900 files); the default `~/Library/Application Support/Claude` profile is
  another account, last active ~10 days ago (its data is why `lastActivityAt`
  first looked stale) — still read, the window filters it. `Claude-3p`, and
  `~/.claude-instances/ssv-code` (a CLI config dir) have no Desktop list.
- **Last activity = `lastActivityAt`** (ms; else `createdAt`) — equals the
  transcript's newest user/assistant message. NOT the transcript's mtime
  (loading a session appends cost-state/last-prompt lines: month-old sessions
  read "2 days ago") and NOT the file's mtime (focus/metadata writes). The file
  is rewritten when `lastActivityAt` changes, so mtime >= it: files older than
  the window are skipped by `stat` alone; parsed files are cached by (path, mtime).
  ~0.14s cold, ~0.01s warm on this Mac.
- **Window**: fixed 14 days (`CLAUDE_DESKTOP_SLEEPING_DAYS`), archived excluded;
  AgentBar narrows it to its own list/search days. Newest first.
- **Dedup** (`build_sleeping_sessions`, live wins): dropped when its Desktop id
  is a live file's `hostSessionId`, or its `cliSessionId` is a live file's
  `sessionId` or any row's `agentSession` (two live processes can share one
  `hostSessionId`). Empty until the `claudeSessions` feed has read once
  (startup), else every running Desktop session would briefly show as sleeping.
- **Shape**: `{desktopSessionId, cliSessionId, label (title, else folder),
  cwd, lastActiveTs (s), openUrl}` — `openUrl` is the same
  `claude://code/continue?session=local_…` a live Desktop row gets. Kept OUT
  of `computed.agents` (every consumer there assumes a live agent);
  `feeds.desktopSessions.data` is replaced per response by `{sleepingCount}` so
  the rows aren't sent twice (~35KB for 14 days). The PWA/remote listener get
  the same key and ignore it.

## Hook answer bridge (`/api/hook/permission*`) — answer Claude prompts from AgentBar
Contract: `hooks/agentbar-permission-hook.py` (Claude Code `PermissionRequest`
hook, stdlib) + `server/lib/hook_permissions.py` (in-memory pending store),
`hook_permission_summary.py` (hookRequest view + decision building/validation),
`hook_permission_routes.py` (routing; the server file only dispatches).
- `POST /api/hook/permission` (hook) -> `{requestId}` | `{state:"ignored", reason}`
  (bad payload, a background-subagent prompt — payload has
  `agent_id` — or a session whose file is missing / not `entrypoint` `cli` |
  `claude-desktop`, e.g. `claude -p` = `sdk-cli`). **Why** (measured 2.1.283):
  Claude shows those prompts only AFTER every hook returns, so holding them
  here left the agent stuck on AgentBar alone for up to the hook's 24h. `GET …/<id>/wait?timeout=N` (N ≤ 25,
  long-poll) -> `{state: pending|answered+decision|resolved|expired}`, 404
  unknown. `POST …/<id>/answer` (AgentBar) `{behavior:"allow"|"deny",
  answers?, suggestionIndex?, message?}` -> 200 / 400 (bad answer) / 409 (not
  pending). Register and wait 404 on the remote listener; `answer` is
  served there too (the phone's web remote answers; auth + CSRF + audit
  like every remote write, audit `rowId` = request id).
- **Herdr panes too** (2026-09-28): a herdr pane's Claude writes a `cli`
  session file, so its prompts are held like any CLI. A local herdr row gets
  `hookRequest`, and `build_needs_you` then emits ONE `blocked` row carrying
  it, ahead of any screen reading — the screen misses a picker in a pane
  scrolled up. No hook request = the old screen path, unchanged.
- Exposure: a status-only row + its needsYou entry get `hookRequest` (oldest
  pending per session); the row then reads `blocked`, detail `Question` /
  `Permission: <tool>`, even before the session file says `waiting`.
- **Web remote / web UI = an answer surface too** (2026-09-27): the SPA opens
  `/api/events?answerSurface=web` and renders a pane-less row's `hookRequest`
  as an answer card (`ui/src/components/HookRequestCard.tsx`, same body as
  AgentBar) or its `transcriptQuestion` as display-only text, on the phone
  inbox and the desktop Needs You table. That stream counts as "seen" exactly
  like AgentBar's (on either listener; the remote one only after auth), so a
  prompt is held with ONLY the phone open. Gotchas: a stream without the
  param (an old cached PWA build, curl) never counts — keep the param in
  `api.ts`; an iOS PWA in the background drops its stream, so its prompts are
  released after 15s and come back ≤ ~10s after it is reopened (hook re-send
  backoff); a browser tab of the SPA left open on the Mac also keeps prompts
  held — harmless, Claude shows its own prompt for every held session. No
  real push exists yet (plan phase 3); the in-page alert (`alerts.ts`
  `alertFor`) keys a pane-less row by session + question TEXT, so a re-send
  after a restart (new request id) or fallback -> hook flip never re-alerts.
- **Held only while AgentBar is connected** (`server/lib/agentbar_presence.py`):
  AgentBar sends `X-AgentBar: 1` on every request; "seen" = such a request
  on the LOCAL listener, or each delivered push of its `/api/events` stream
  (every ~2s). Not seen in 10s -> register answers `ignored` ("AgentBar not
  connected"); not seen for 15s -> every pending request resolves
  `agentbar gone` and its hook exits. Browser tabs / curl without the header
  never count (the web UI's `answerSurface=web` stream does, above); a
  dashboard restart starts "not connected" until AgentBar or the web UI
  reconnects. An answer is also refused (409) once the hook process is dead
  or silent >5s — a /wait whose hook was killed keeps looping server-side,
  so the store checks `hookPid`. All ages use `time.monotonic()` (wall
  clock only vs the session file's `statusUpdatedAt`).
- Hook ignores `HTTP_PROXY` (urllib would otherwise send prompts to a proxy
  even for 127.0.0.1). A `tool_input` whose AgentBar view can't be built is
  `ignored` at register (it would have broken `/api/state`). File prompts
  (Edit/MultiEdit/Write/NotebookEdit) show `- old` / `+ new` lines after
  the path; a hook row's timer counts from the prompt, not the file status.
- Hook fails open: any error -> exit 0, no stdout (~0.25s); dashboard down -> re-send (below) or, when not eligible, the same fast exit.
  Env `AGENTBAR_DASHBOARD_URL` (default :4711). NOT installed anywhere yet;
  install = `PermissionRequest` matcher `*`, timeout 86400.
- Gotchas: **first decision wins** — Claude runs hooks in parallel with its
  own prompt, and whoever answers first wins (a later AgentBar answer is
  moot). **No signal when answered elsewhere** — the hook is never told; the
  store infers `resolved` from the session file (`statusUpdatedAt` after the
  request and status not `waiting` — or `waiting` again from a write >1s after
  it, i.e. the NEXT prompt; seen ≤3s live), a dead Claude pid, 90s with no
  `/wait` (10s if the hook never polled once), or 24h age. Parallel subagents
  can hold several prompts in one session; only main-thread ones register.
- **Re-send** (2026-09-27 fix: a Desktop question vanished from AgentBar after
  a dashboard restart — the store is in memory, the hook used to exit on 404).
  The hook sends its prompt again, with backoff 1→10s, on a `/wait` 404,
  60s unreachable, dashboard down, or a `retryable` reply ("AgentBar not
  connected" at register, `agentbar gone` later) — but ONLY while its own
  session file (`CLAUDE_SESSIONS_DIR`) is an interactive `cli`/`claude-desktop`
  one still showing THIS prompt (`session_prompt_state.py`, shared by hook and
  store; a file with no `statusUpdatedAt` counts only while `waiting`), the
  Claude pid lives, and 23h have not passed. Re-sends carry
  `reregister: true` + the original `promptStartedAt`; the store holds one
  only while the (freshly read) session file says `waiting` and not moved on
  (`prompt no longer waiting` otherwise). A re-send whose request is still
  pending (hook lost contact >60s) gets that request id back — only when it is
  the SAME hook (`hookPid`) and prompt (`tool_use_id`, else sha256(tool,
  input)): another hook with identical input is a new prompt (retried
  command), and merging it would let the old prompt's answer resolve it.
  Restart gap: a prompt is back ≤ ~15s after AgentBar reconnects.
- e2e recipe (never against :4711): run the server with
  `CHIEF_DASHBOARD_PORT=4713` + scratch `CHIEF_DASHBOARD_STATE_HOME` and
  `CHIEF_DASHBOARD_CONFIG_HOME` (**:4712 is the live instance's remote
  listener** when remote access is on — and `restart.sh --port 4712` would
  kill it), then `claude --setting-sources project --permission-mode default`
  in a scratch dir whose `.claude/settings.json` registers the hook with
  `AGENTBAR_DASHBOARD_URL=http://127.0.0.1:4713`. Under
  `--setting-sources project` an "always allow" answer IS written to
  `settings.local.json` but not re-read (local settings excluded), so the
  next run prompts again — a test-setup artifact, not a bug. Nothing is held
  without an AgentBar client on :4713: simulate one with
  `curl -sN -H 'X-AgentBar: 1' localhost:4713/api/events > /dev/null`.
  Wrapping the hook in a shell script for tracing: pass stdin on with
  `printf '%s'`, never `echo` (sh's echo expands `\n` and corrupts the JSON).

## OpenCode / Codex support — overview (read first; details in the three sections below)

### Turn it on (user checklist)
1. `python3 dashboard/integrations/install.py install` (both tools; `--tool opencode|codex`; `status` / `uninstall` also exist; merges next to other vendors' hooks, backs up, uninstall removes only ours).
2. Codex: on next start, in the Codex TUI choose **"Trust all"** on the new-hooks review prompt (once).
3. Restart: the dashboard (`scripts/restart.sh`), every running OpenCode, every running Codex (they load plugin/hooks at start).
4. Rebuild AgentBar: `scripts/build-agentbar-app.sh --open` (Swift side of message button / tool cards).
5. Check: `install.py status --json` shows both `installed: true`. An OpenCode row saying the plugin is "out of date" = repeat step 1 + restart OpenCode.

### Support matrix (herdr panes on the local machine only)
| Capability | OpenCode | Codex | Gemini |
|---|---|---|---|
| Exact status (working/idle/blocked) | yes (plugin events) | yes (hook + rollout) | no |
| Context % | yes if model limit known, else null | yes (rollout `token_count`) | no |
| Answer permission | yes (job relay) | yes (held hook; keystroke fallback) | no |
| Answer question | yes if it has options; option-less = no card | prose question (`?` heuristic) shows blocked, no answer card | no |
| Message | yes (job relay, `prompt_async`) | yes (typed into pane, screen-checked) | no |
| Row outside herdr | NOT supported (P5 skipped/deferred) | NOT supported | no |

Without fresh plugin/hook data a row is a "best guess" from its screen (OpenCode/Codex screens are read; Gemini is UNKNOWN) and is never messaged (`message_gate`).

### Vocabulary
- **tui_jobs relay**: `server/lib/tui_jobs.py`; OpenCode has no TCP listener, so its plugin long-polls the dashboard for jobs (answer/message) and runs them in-process.
- **held Codex hook**: second PermissionRequest hook that keeps Codex waiting while AgentBar answers (`codex_hold_store.py`).
- **opencode plugin**: `integrations/opencode/agentbar-status.js` (status + relay client). **Codex hook**: `integrations/codex/agentbar-codex-hook.py` (status) + `agentbar-codex-permission.py` (hold).
- **install.py**: `integrations/install.py`, the only supported installer.
- **tui-event**: status POST from either tool; store `tui_status_events.py`.
- Not to confuse: the earlier "P5" in the herdr `agent_status` fallback note (Claude-outside-herdr section) is unrelated to OpenCode/Codex phase 5.

### Env knobs
`AGENTBAR_CODEX_HOLD_SEC` (default 300, 0 = never hold), `AGENTBAR_DASHBOARD_URL` (where plugin/hooks post), `TUI_STATUS_STALE_SEC` (600, freshness), `OPENCODE_CONFIG_DIR` / `CODEX_HOME` (installer targets).

### Accepted risks
- Any local process can spoof a status event (same trust as every hook).
- Codex Enter follows a screen re-read; a permission box opening in that split second could take the Enter (busy Codex best effort).
- "Asked in prose" blocked state is a `?`-at-end-of-reply heuristic (false positives/negatives).
- Relay result post is not bound to the claiming pid.

### Deferred / untested
- P5: rows for OpenCode/Codex outside herdr (user skipped).
- OpenCode option-less question answer; OpenCode keystroke fallback.
- `codex queue` unused (see Phase 4); Codex is alpha (ChatGPT.app 0.154) so formats may drift, parsers are tolerant.
- Air / other machines untested (Swift not built on the Air; remote machines' OpenCode/Codex rows are 404 for tui events).
- Gemini: unsupported.

## OpenCode / Codex exact status (`POST /api/hook/tui-event`) — Phase 2, status only
- Senders (`integrations/`): OpenCode plugin `opencode/agentbar-status.js` (session.status/idle/error/deleted, permission.*, question.*, message.updated tokens, 30s heartbeat; reports pid, cwd, `HERDR_PANE_ID`, its local `serverUrl`); Codex hook `codex/agentbar-codex-hook.py` (all 11 hooks.json events incl. PermissionRequest). Both NEVER decide: no stdout, exit 0, 0.8s post timeout, fire-and-forget (plugin handler never awaits the network). Env `AGENTBAR_DASHBOARD_URL`.
- Store `server/lib/tui_status_events.py` (in memory, per tool+session; local listener only, remote 404). `attach_to_rows` lays a FRESH entry over a local herdr row without Claude hook data: match by pane id, else a unique cwd (one row of that tool + one entry there; twins stay unmatched). Sets `hookState`/`hookSinceSec`/`hasHookData: true` (not "best guess" any more)/`hookReason`, plus `statusSource` (`opencode-plugin` | `codex-hook` | `codex-rollout`), `tuiPrompt` (permission | question | null), `tuiContextPercent` (-> `contextPct`). A `blocked` entry yields the usual screen-checked Needs-You row.
- Fresh = pid alive AND last event/heartbeat/rollout write < `TUI_STATUS_STALE_SEC` (600s). Otherwise dropped -> row decays to its screen reading. Codex idle >10 min decays too (no heartbeat) — harmless, the screen reads idle.
- Codex rollout (`server/lib/codex_rollout.py`, tolerant of format drift, 256KB tail, cached by mtime/size): context % = last `token_count` last_token_usage.total_tokens / model_context_window; a rollout newer than the last hook event sets turn state, except while a permission is open. A reply (Stop `last_assistant_message` / `task_complete.last_agent_message`) whose last line ends in `?` = `blocked` question ("asked in prose").
- OpenCode context % = assistant tokens (input+output+reasoning+cache) / model limit from `{serverUrl}/config/providers` (shape GUESS; no limit -> null, never guessed).
- Message gate: Phase 4 lets such a row be messaged (below).
- Install (merge, idempotent, `<file>.bak-agentbar-<ts>` backup, uninstall removes only ours; `$OPENCODE_CONFIG_DIR`, `$CODEX_HOME` overrides): `python3 dashboard/integrations/install.py install|uninstall|status [--tool opencode|codex|all] [--json]`. Refuses an unreadable hooks.json or a same-named foreign plugin file.
- Tests: `tests/test_tui_status_events.py`, `tests/test_tui_integrations.py` (temp dirs, fake listener, node driver for the plugin).

## OpenCode / Codex answers (`POST /api/hook/permission/<id>/answer`) — Phase 3
Same card, same endpoint, same audit line as the Claude bridge (`hookRequest` gains `tool: opencode|codex`; the web card names the product). Request-id prefix picks the path (`server/lib/tui_answers.py` attaches the cards; `hook_permission_routes.py` routes):
- `tuioc-<opencode id>` — OpenCode. The plugin reports the pending request (`request`: id, what is asked, options) in its events. Answer = `opencode_answer.py` builds + validates the reply (permission: `once|always|reject`; question: `answers` labels; deny = reject), then **the plugin runs it**: a default OpenCode TUI has NO TCP listener (`lsof`; `serverUrl` is a placeholder :4096), so the plugin long-polls `GET /api/hook/tui-job/wait?pid=` (only while a prompt of its process is pending) and runs the job through its in-process `client._client` (`tui_jobs.py` relay; result back on `POST /api/hook/tui-job/<id>/result`; local listener only). Plugin allowlists 4 route shapes and only replies to ids it saw asked. Entries with no `relay` flag (older plugin) use loopback HTTP instead (http only, host 127.0.0.1/localhost/::1, port, no userinfo/path; pid alive + same uid; id must be in the server's own pending list `GET /permission|/question` or `/api/session/<sid>/...`; unknown shape refuses, never guessed). Verified against 1.18.30 `GET /doc`. Both v1 and v2 event/route families handled.
- `tuicx<n>-<hex>` — Codex hold (`codex_hold_store.py`, a `HookPermissionStore` subclass). Second PermissionRequest hook `integrations/codex/agentbar-codex-permission.py` registers and long-polls; prints `hookSpecificOutput.decision {behavior, message?}`; fails open (silent exit 0) on every other outcome. Holds ONLY while AgentBar / a web answer surface is connected, at most `AGENTBAR_CODEX_HOLD_SEC` (default 300, 0 = never hold; hooks.json timeout 3600). **Measured on codex 0.154: while the hook runs the TUI draws NO prompt ("Running hook")**, so a held prompt cannot be answered in the terminal until the hold ends (no race, unlike Claude). Codex fails closed on `updatedInput`/`updatedPermissions`, so there is no "always allow". First-time hooks need the one-time "Trust all" review in the Codex TUI.
- `tuikx-<sha8 of command>-<codex session>` — Codex keystroke fallback (prompt came up while AgentBar was not connected). `codex_pane_answer.py` sends `y` (allow) / `esc` (deny) ONLY after a fresh `pane read` shows `other_tui_screens.prompt_open == permission` AND the reported command AND the pane id from Codex's own hook matches the row and herdr still lists it; re-reads afterwards. A newer screen reading with no prompt drops a stale card (Codex sends no event on dismiss).
- First answer wins everywhere: a second/late answer gets 409 "already answered in <tool>". Not supported: OpenCode text-only question (no options) shows no card; OpenCode keystroke fallback (question-picker layouts unverified).
- Tests (direct-run): `test_opencode_answer.py` (fake OpenCode server), `test_codex_hold.py` (real hook script as subprocess), `test_tui_answers.py` (fake pane), `test_tui_jobs.py` (relay + the real plugin under node with a fake client, harness `opencode_plugin_harness.mjs`). Live e2e recipe: scratch dashboard on a free port + `AGENTBAR_DASHBOARD_URL` for a scratch `opencode`/`codex` (own `XDG_CONFIG_HOME`/`CODEX_HOME`, plugin/hooks copied in); POST the answer with `X-AgentBar: 1`; deny anything outside the scratch dir. Proven live 2026-09-29: OpenCode permission deny + question pick via the relay; Codex hold allow/deny via the hook.

## OpenCode / Codex messages (`POST /api/session/message`) — Phase 4
Same route, same request/response shapes, same audit rows, same clients as a Claude pane send. `_handle_reach_action` runs its usual checks (`validate_message_text`: one line, <= 8000, no control chars; live row; own-pane/dev-server guards; FRESH pane read), then for `message_gate.is_tui_row` rows `tui_message.check` adds: **no leading `/` and no leading `!`** (a command in both tools; `/compact` / `/clear` are Claude-only and refused too), refused while `other_tui_screens.prompt_open` sees a permission/question box, a fresh status entry for THIS row's session must exist (`tui_status_events.STORE.fresh_entries()`, so a feed that went stale since the state was built refuses), the entry's `paneId` must equal the row's pane, and an entry with `status: blocked` / a `prompt` refuses ("waiting on you"). Then the generic busy rule: `needsConfirm` while busy, then state `queued`. Local machine only. All refusals answer `typed: false`.
- **OpenCode** (`tui_message.send_opencode`): the plugin (marker v2) inside that process runs `POST /session/<id>/prompt_async` body `{parts:[{type:"text",text}]}` through the Phase 3 job relay (`tui_jobs`), so no keystroke is involved and nothing typed can land in a prompt that appeared meanwhile. Needs `relay` + `canMessage` (the plugin reports `messages: true`); an older plugin file is refused with "out of date" (re-run `integrations/install.py install --tool opencode`, restart OpenCode). Outcomes: 2xx = sent (`queued` when busy — measured: OpenCode shows the message with a QUEUED tag until the turn ends); 4xx from OpenCode or the plugin's allowlist = refused, `typed: false`; job never picked up (`tui_jobs.JobNotPickedUp`) = refused, `typed: false`; picked up but no answer / 5xx = "may or may not have arrived" (uncertain, never retried). One send per session at a time (in-flight set). Plugin allowlist for a message: POST `/session/ses_…/prompt_async`, a session id the plugin saw events for, body exactly one text part, 1..8000 chars, no other keys (no model/agent/system override).
- **Double-send guard**: `tui_message._guarded` allows one send per session at a time, and refuses the same text to the same session again within 10s (double click / client retry); a `typed:false` refusal forgets it so a corrected retry works at once. Codex re-reads the pane inside that slot before typing. An unclaimed OpenCode job is withdrawn on timeout (`JobNotPickedUp`, nothing sent); a claimed one that never answers is "may have arrived".
- **Relay hardening (QA pass 2)**: job ids carry a random suffix; `/api/hook/tui-job/wait` needs the `X-AgentBar-Relay` header (a web page cannot add it without a CORS preflight), no `Origin`, loopback `Host`; request bodies over 1 MB are ignored; an uncertain send blocks the same text for 90s. Known, accepted: Codex Enter follows a re-read, so a permission box that opens in that split second could take the Enter (busy Codex is best effort); any local process can post a spoofed status event (same trust as every hook); a result post is not bound to the claiming pid.
- **Plugin poll** (Phase 4 change): the long-poll now runs for the life of the OpenCode process once it has seen a session (an idle session must be reachable). It backs off 3s -> 10s (cap) while the dashboard is unreachable; a request id it saw asked but never answered is forgotten after 6h (max 100), so it can no longer grow without bound.
- **Codex** (`tui_message.send_codex`): typed into the herdr pane, in steps with a fresh read between: (1) the pane must show the Codex composer and the composer must be EMPTY (a draft the user left there would be submitted with ours); the entry must carry Codex's own hook-reported `paneId`; (2) `herdr pane send-text` (literal, no Enter); (3) read: the text must be in the composer and no prompt open, else Enter is NOT pressed ("NOT SUBMITTED"); (4) `send-keys enter`; (5) read: composer no longer holds the text, else "NOT SUBMITTED — stuck". A herdr failure after typing began = "mid-sequence". Both wordings are what AgentBar/the PWA already treat as uncertain (never a second send). Measured 2026-09-29 (codex 0.154): mid-turn Enter queues the text under "Messages to be submitted after next tool call", composer empties -> state `queued`.
- **`codex queue --thread <id> --message`** DOES reach a running terminal session (measured: the text appeared as a user turn and started one) but is NOT used: the CLI is not on PATH (only inside ChatGPT.app, alpha 0.154), it talks to the app-server daemon of one `CODEX_HOME` (version/home skew with the session's TUI is unknowable from here), and it offers no prompt-open check. Pane typing has the screen checks above. Revisit if Codex gets an official messaging API.
- **Authority**: the text reaches the tool as an ordinary user prompt; nothing here elevates it (contrast the Claude inbox path, where the session sees a peer). Tests inject only the inert sentinel `$(echo INJECTED)` and assert it arrives literally.
- Tests: `test_tui_message.py` (gate, checks, OpenCode job outcomes, Codex fake-pane state machine incl. stuck/prompt-appeared/herdr failure, end-to-end through `handle_session_action` with fake I/O), `test_tui_jobs.py` (real plugin under node: message allowlist), `test_tui_status_events.py`. Live 2026-09-29 (scratch dashboard :4731, scratch OpenCode 1.18.30 + Codex 0.154 panes, "reply with the word pong"): OpenCode sent + busy needsConfirm -> queued + refused while a question picker was open + refused `/` `!`; Codex sent, busy queued, `@file` text sent.

## Running it
```
cd dashboard
python3 server/chief-dashboard-server.py            # port 4711 (or $CHIEF_DASHBOARD_PORT)
```
Or via the restart helper, which kills whatever already holds the port
(by **port ownership**, via `lsof` + an argv check — never `pkill -f
<name>`, so a same-named instance on a different port can't kill or be
killed by another) and waits for every feed to warm before reporting:
```
scripts/restart.sh                      # production: relaunches inside the
                                         # herdr pane tab-labelled
                                         # chief-dashboard-server (--pane / $CHIEF_DASHBOARD_PANE to override)
scripts/restart.sh --port 4712 --detached   # testing: no herdr pane needed
                                         # WARNING: with remote access enabled the LIVE
                                         # server owns :4712 — this would kill it; use 4713
scripts/restart.sh --dry-run                # print the plan, touch nothing
```

## Testing
No pytest, no `pip install` into system Python (use `dashboard/.venv/`,
gitignored, if a test ever needs a real dependency — none do today; stdlib
only). Run all tests:
```
for f in tests/test_*.py; do python3 "$f" || echo "FAILED: $f"; done
```
As of this writing: 51 test files, ~1810 `PASS` lines, 0 failures
(`test_chief_dashboard_views.py` prints a heading containing "FAIL-OPEN" —
not a failure; judge by each file's exit code).

**`agent_tree.py` is a verbatim copy of AptusFit's `scripts/lib/agent_tree.py`**
— both write the same `~/.claude/agent-tree.json`, so their prune rules must
match. `tests/test_agent_tree_upstream_parity.py` fails on any drift; sync by
copying AptusFit's file over, never by editing this copy alone.
`tests/test_agent_tree.py` is AptusFit's test file with two edits (lib path,
the retired `agent_tree_routing` test); nothing guards it, so port new
upstream tests by hand on each sync.

**4711 and 4712 are this repo's own live production instance** (4711 the
main loopback listener, 4712 its remote-access listener when enabled — see
"Rules" below) **, not AptusFit's** — the dashboard moved into this repo in
the P0 move, so AptusFit no longer runs its own copy. **Never POST to
either port, and never restart/kill by process name** — a same-machine
write there types real keystrokes into a real pane. Restart only through
`scripts/restart.sh` (kill-and-relaunch by port ownership, never
`pkill -f`). All testing runs on other ports (e.g. 4713+ — see the e2e
recipe above; 4712 is live when remote access is enabled, so a test
server must not bind it): GET requests against the real 4711 data are
fine (read-only, harmless), but every write path (`answer`,
`permission`, `focus`, session actions) is exercised only through the
`test_*.py` fakes, never live against real panes. A throwaway test
server's process still opens the same board sqlite db as the live one
unless told otherwise (it runs `_init_db()` on startup, a write) — export
`CHIEF_DASHBOARD_STATE_HOME=<some throwaway dir>` before launching it with
`--detached` so it never touches the live db file.

**Parity check** — confirms the moved server (4712) produces the same
agent rows as the original (4711):
```
python3 scripts/parity-check.py                       # defaults: old=4711, new=4712
python3 scripts/parity-check.py --retries 3 --retry-wait 2   # tolerate timing blips
```
It's GET-only against both servers and compares `computed.agents` rows by
pane id (same set of panes, same `machine`, same coarse status bucket —
raw `screenState` text can tick between the two curl calls and that alone
isn't a mismatch).

## Rules (unauthenticated, localhost-only — by design, not an oversight)
- The server binds `127.0.0.1` only; there is no auth on any endpoint.
  `GET` routes (`/api/state`, `/api/board`, `/api/agent-tree`, `/api/views`,
  `/api/session/history`, `/api/pane/screen`, …) are read-only and always
  answered. Every write method (`POST`/`PATCH`/`DELETE`) first calls
  `_reject_foreign_write()`, which 403s a request carrying a cross-origin
  `Origin` header — a same-machine curl call or a same-page fetch (no
  `Origin` sent) is not "foreign" and is allowed. This is a same-machine
  trust boundary, not a network-facing auth system: never expose this port
  beyond localhost.
- **Exception, opt-in only**: (`server/lib/remote_access.py`,
  `server/REMOTE.md`) lets a phone reach this server through
  `tailscale serve`'s HTTPS proxy, gated by `remote.enabled` in
  config.json + a token, off by default. This is a SEPARATE listener
  (127.0.0.1:`remote.port`, default 4712) bound only when enabled —
  `tailscale serve` targets that port, never 4711, so the main loopback
  port above is unreachable from the tailnet and everything in the
  paragraph above stays byte-identical whether remote access is on or off.
  Read `server/REMOTE.md` before enabling it.
- Kill/restart by **port ownership** only (`lsof` + confirm the owning
  pid's argv looks like `chief-dashboard-server.py`), never by process
  name (`pkill -f <name>` kills every same-named process regardless of
  which port it holds).

## Not done in P0 (left for later)
- No LaunchAgent/plist is installed for this copy's watchdog — production
  keep-alive (AptusFit's `com.aptusfit.chief-dashboard-watchdog`) is
  untouched and stays pointed at AptusFit's own server.
  `scripts/chief-dashboard-watchdog.py` here is copied, repointed at this
  checkout's own paths, and manually verified to import and resolve its
  config correctly, but still has no installed schedule.
  AptusFit's `test_chief_dashboard_watchdog.py` (~1390 lines) IS now ported,
  split by concern into three files under 340 lines each:
  `tests/test_chief_dashboard_watchdog_state.py` (probe classification +
  the pure failure-file state logic — streaks, episode residue, restart
  cap, cooldown), `tests/test_chief_dashboard_watchdog_main.py` (`main()`'s
  own orchestration — the two-consecutive-dead-probes trap, the anti-flap
  blip case, the confirmation-read-on-a-longer-budget before any kill),
  and `tests/test_chief_dashboard_watchdog_restart.py` (the restart-
  execution layer — `kill_stale_server`, `restart_in_pane`,
  `wait_for_dashboard`, the state store surviving a moved plugin path).
  Dropped: the ~470-line `chief-tick-gate.py`-dependent section (alarm
  reasons, `gate.main()`, the end-to-end `_FakeClock` flap simulation) —
  not a retired *behaviour*, but `chief-tick-gate.py` itself was never
  moved into this checkout (confirmed absent by search), so there is
  nothing here to import or test against. Every watchdog-side fact those
  end-to-end sims proved is still pinned by the pure unit checks above.
- Multi-project `projectRoots` (see the P0 scope note above) — `chief_pass`'s
  per-projectRoot script resolution is the one exception that already loops
  every entry; every other call site still only reads `projectRoots[0]`.
