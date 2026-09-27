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
  /api/personas` — see "Jev persona routing" below), and `dashboard_config.py`
  (below).
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
dashboard endpoints (P4 — not built yet, hand-edit for now). Missing file
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
  `openUrl`. Stop/close/relaunch are refused (`assess_row`); message/answer/
  focus already refuse a row with no pane. A `waiting` one is a `blocked`
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
  app.asar's `claudeURLHandler`, not exercised live.
- P5: for a non-Claude herdr agent (`agent` != `claude`, e.g. OpenCode) whose
  screen reads `UNKNOWN`/nothing, herdr's `agent_status` (`working`/`blocked`/
  `idle`/`done`; `unknown` ignored) stands in as `screenState`
  (`pane_screen_signals.screen_state_with_herdr_fallback`); new field
  `screenStateSource` = `screen` | `herdr` | null. Local rows only.

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

## Hook answer bridge (`/api/hook/permission*`) — answer non-herdr prompts from AgentBar
Contract: `hooks/agentbar-permission-hook.py` (Claude Code `PermissionRequest`
hook, stdlib) + `server/lib/hook_permissions.py` (in-memory pending store),
`hook_permission_summary.py` (hookRequest view + decision building/validation),
`hook_permission_routes.py` (routing; the server file only dispatches).
- `POST /api/hook/permission` (hook) -> `{requestId}` | `{state:"ignored", reason}`
  (herdr-pane session, bad payload, a background-subagent prompt — payload has
  `agent_id` — or a session whose file is missing / not `entrypoint` `cli` |
  `claude-desktop`, e.g. `claude -p` = `sdk-cli`). **Why** (measured 2.1.283):
  Claude shows those prompts only AFTER every hook returns, so holding them
  here left the agent stuck on AgentBar alone for up to the hook's 24h. `GET …/<id>/wait?timeout=N` (N ≤ 25,
  long-poll) -> `{state: pending|answered+decision|resolved|expired}`, 404
  unknown. `POST …/<id>/answer` (AgentBar) `{behavior:"allow"|"deny",
  answers?, suggestionIndex?, message?}` -> 200 / 400 (bad answer) / 409 (not
  pending). All three 404 on the remote listener; writes go through
  `_reject_foreign_write` as usual.
- Exposure: a status-only row + its needsYou entry get `hookRequest` (oldest
  pending per session); the row then reads `blocked`, detail `Question` /
  `Permission: <tool>`, even before the session file says `waiting`.
- **Held only while AgentBar is connected** (`server/lib/agentbar_presence.py`):
  AgentBar sends `X-AgentBar: 1` on every request; "seen" = such a request
  on the LOCAL listener, or each delivered push of its `/api/events` stream
  (every ~2s). Not seen in 10s -> register answers `ignored` ("AgentBar not
  connected"); not seen for 15s -> every pending request resolves
  `agentbar gone` and its hook exits. Browser tabs / curl without the header
  never count; a dashboard restart starts "not connected" until AgentBar
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
  store), the Claude pid lives, and 23h have not passed. Re-sends carry
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
As of this writing: 51 test files, ~1610 `PASS` lines, 0 failures
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
