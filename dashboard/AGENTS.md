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
  views/actions/memory modules, and `dashboard_config.py` (below).
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
As of this move: 31 test files, 873 `PASS` assertions, 0 `FAIL`.

**Never POST to port 4711** (AptusFit's live instance) or restart/kill it.
All P0-move testing runs on **4712**: GET requests against the real 4711
data are fine (read-only, harmless), but every write path (`answer`,
`permission`, `focus`, session actions) is exercised only through the
`test_*.py` fakes, never live against real panes.

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
  config correctly, but has no installed schedule and no test coverage
  yet in this checkout (`test_chief_dashboard_watchdog.py`, ~1390 lines in
  AptusFit, was not ported — flagged as a gap, not silently dropped).
- Multi-project `projectRoots` (see the P0 scope note above).
- `chief_pass` (`GET /api/deliver/pass`) was fully retired rather than
  generalized (a documented deviation from the brief's literal "move
  generically" instruction) — no MOVE-set caller needed it.
