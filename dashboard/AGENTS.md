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
  (`POST /api/persona/start`, same section), and `dashboard_config.py`
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

Names are unique among OFFERED personas (hidden/undescribed entries are
filtered first, then a duplicate name keeps the first in registry order).
Each row also carries `idleStart`: `"resume"` | `"fresh"` — what a start
would do right now (see below). Only a local `start: in-place` persona can
be `"resume"`; the folder scan is cached 30s.

### `POST /api/persona/start` — P3 (`server/lib/persona_start.py`)
Starts or resumes an idle persona's Claude session in a new herdr tab in
its registry folder. **Localhost only**: 403 on the remote (tailscale)
listener even when authenticated. Requires `Content-Type: application/json`
(400 otherwise). These early refusals (and the foreign-Origin 403 on every
write) answer before reading the body, so `Handler.end_headers` closes the
connection whenever a body was left unread — otherwise keep-alive would
parse that body as a second, attacker-written request (live-proven
2026-09-26; `tests/test_remote_listener_integration.py`). An interim 1xx
reply (`Expect: 100-continue`'s `100 Continue`, sent before the body
exists) is exempt; the final reply is still checked.

- Request: `{"persona": "<name>", "text": "<first message>", "fresh": true?}`
  — a name, never a path. `text` follows the Send message rules
  (`validate_message_text`: one line, <= 2000 chars, tabs become spaces
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
  `openUrl`. Stop/close/relaunch are refused (`assess_row`); message/answer/
  focus already refuse a row with no pane. A `waiting` one is a `blocked`
  needsYou row with `paneId: null`, `identity`/`agentSession` = session id,
  `source`, `openUrl`.
- `openUrl` (desktop rows only): `claude://code/continue?session=<hostSessionId>`
  — Claude.app's own handler accepts `local_<id>` there and opens that
  EXISTING session (falls back to Code home, never creates one). Read from
  app.asar's `claudeURLHandler`, not exercised live.
- P5: for a non-Claude herdr agent (`agent` != `claude`, e.g. OpenCode) whose
  screen reads `UNKNOWN`/nothing, herdr's `agent_status` (`working`/`blocked`/
  `idle`/`done`; `unknown` ignored) stands in as `screenState`
  (`pane_screen_signals.screen_state_with_herdr_fallback`); new field
  `screenStateSource` = `screen` | `herdr` | null. Local rows only.

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
scripts/restart.sh --dry-run                # print the plan, touch nothing
```

## Testing
No pytest, no `pip install` into system Python (use `dashboard/.venv/`,
gitignored, if a test ever needs a real dependency — none do today; stdlib
only). Run all tests:
```
for f in tests/test_*.py; do python3 "$f" || echo "FAILED: $f"; done
```
As of this writing: 46 test files, 1539 `PASS` assertions, 0 `FAIL`.

**`agent_tree.py` is a verbatim copy of AptusFit's `scripts/lib/agent_tree.py`**
— both write the same `~/.claude/agent-tree.json`, so their prune rules must
match. `tests/test_agent_tree_upstream_parity.py` fails on any drift; sync by
copying AptusFit's file over, never by editing this copy alone.
`tests/test_agent_tree.py` is AptusFit's test file with two edits (lib path,
the retired `agent_tree_routing` test); nothing guards it, so port new
upstream tests by hand on each sync.

**Never POST to port 4711** (AptusFit's live instance) or restart/kill it.
All P0-move testing runs on **4712**: GET requests against the real 4711
data are fine (read-only, harmless), but every write path (`answer`,
`permission`, `focus`, session actions) is exercised only through the
`test_*.py` fakes, never live against real panes. `4712`'s server process
still opens the same board sqlite db as `4711` unless told otherwise (it
runs `_init_db()` on startup, a write) — export
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
