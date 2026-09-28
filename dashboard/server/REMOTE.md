# Remote access (phone over Tailscale)

Lets a phone reach this dashboard through `tailscale serve`'s HTTPS proxy
instead of only `127.0.0.1:4711`. Off by default; loopback behaviour on the
main dashboard port is completely unchanged whether this is on or off — see
"Why a separate listener" below for why that's now a hard architectural
guarantee, not just a header check. See
`docs/plans/2026-09-26-agentbar-mobile-web.md` for the full phased plan —
this covers remote access only; phone UI and push are later phases.

## Why a separate listener

The first version of this (QA pass 1) gated remote requests by inspecting
the `Host` header on the SAME port (4711) loopback callers use, and treated
a Tailscale identity header as proof a request had actually transited the
proxy. That header is Tailscale's own defense against Host spoofing for
*tagged* devices, but a personal, untagged phone reaching `tailscale serve`
does not get it set — which would have made its requests indistinguishable
from genuine loopback calls again, defeating the whole scheme.

QA pass 2 removes Host-header trust entirely. Remote access now binds a
**second, separate socket**, `127.0.0.1:<remote.port>` (default 4712), only
when `remote.enabled` is true. `tailscale serve` is pointed at THAT port —
never at 4711. Nothing on the tailnet can reach 4711 at all, so there is no
Host header to spoof against it in the first place, and the main listener
runs no remote-access code whatsoever: it is byte-identical to the
pre-remote-access server. Every request that arrives on the remote listener
is remote by construction, so auth is required on **every** route,
unconditionally, regardless of whatever `Host` or other headers it carries.

## Enable, step by step

1. **Generate the token** (the one shared secret the phone logs in with):
   ```
   python3 dashboard/scripts/remote-token.py
   ```
   Keep the printed value — it is only ever shown again with `--show`.

2. **Turn it on in config** — edit `~/.config/agent-dashboard/config.json`
   (create it from `dashboard/config.example.json` if it doesn't exist):
   ```json
   {
     "remote": {
       "enabled": true,
       "port": 4712,
       "hosts": ["mymac.tailxxxx.ts.net"]
     }
   }
   ```
   `port` is where the separate remote listener binds (127.0.0.1 only —
   still not reachable from the tailnet directly; `tailscale serve` is what
   fronts it with HTTPS). `hosts` is used only as the Origin allow-list for
   CSRF checks on writes (see below) — find your machine's name with
   `tailscale status` (`<name>.<tailnet>.ts.net`). Restart the dashboard for
   the config change to take effect.

3. **Point Tailscale at the remote listener's port** (4712, not 4711):
   ```
   tailscale serve --bg 4712
   ```
   This serves `https://<that ts.net name>/` → `http://127.0.0.1:4712`,
   reachable from any device on your tailnet (including your phone, once
   the Tailscale app is signed into the same tailnet). The main dashboard
   port (4711) is never targeted by `tailscale serve` and stays loopback-only.

   **Never run `tailscale serve` (or any `--bg` variant) against the main
   dashboard port, and never run `tailscale funnel` against either port.**
   Funnel exposes the port to the *public internet*, not just your tailnet
   — this dashboard can start terminal sessions on your Mac; it must never
   be reachable by anyone outside your own tailnet.

4. **Log in from the phone**: open `https://<name>.ts.net/` in Safari →
   redirects to `/remote/login` → paste the token from step 1 → sets a
   30-day session cookie. Add to Home Screen for the fuller PWA experience.

   **iOS installed (standalone) PWA has its own, separate cookie jar** from
   Safari's own tabs — a login done in a Safari tab does NOT carry over to
   the icon added to the Home Screen, and vice versa. After adding to Home
   Screen, open the installed app once and log in again there with the same
   token; it then keeps its own 30-day session independent of Safari's.

## What changes when `remote.enabled` is true

- The **main dashboard port** (4711 by default) runs no remote-access code
  at all — no auth, no Host inspection, nothing. It is exactly the server
  that existed before remote access shipped.
- A **separate listener** binds `127.0.0.1:<remote.port>` (default 4712).
  Every request on it requires auth on **every** route, including
  `GET /api/state`, the `/api/events` SSE stream, and static UI assets —
  not just writes. Unauthenticated: `401` JSON for `/api/*`, a redirect to
  `/remote/login` for everything else.
- Writes (`POST`/`PATCH`/`DELETE`/`PUT`) on the remote listener enforce
  auth first, then CSRF: a browser `Origin` header, when sent, must name
  one of `remote.hosts` over `https://` or the request is refused with
  `403`.
- Every remote write attempt (allowed or refused) is appended as one JSON
  line to `~/.config/agent-dashboard/remote-audit.jsonl`
  (`ts`, `route`, `method`, `rowId` when known, `status`). For
  `/api/session/<action>` the `rowId` is the body's row (session id), not
  the verb (2026-09-28; before that it logged the action name).
- `POST /api/session/message` from the phone also reaches Claude Desktop /
  plain-CLI rows (no pane) through the session's own peer inbox
  (`server/lib/session_inbox.py`, dashboard `AGENTS.md` "Message via
  inbox") — same login, same-origin rule and audit line as a pane send; the
  session's peer token never appears in a response or the audit log.
- **Personas from the phone** (2026-09-28): `GET /api/personas` lists every
  offered persona WITHOUT folder paths (name, description, idleStart,
  offline, mainRowId, remoteStart); messaging one goes to its running main
  session through `POST /api/session/message` (same rules as any row).
  `POST /api/persona/start` is served here ONLY for a persona whose
  registry entry has `"remoteStart": true` (off by default; no Settings
  toggle yet — add it to the entry in `~/.config/agentbar/personas.json`
  on the Mac), and only with the keys
  `persona`/`text`/`fresh` plus `confirm: true`: the registry decides the
  folder and command, so a stolen session can at most start an
  already-trusted persona in its own folder with a message (same text
  rules as a Send). Listing offered personas' names and descriptions is
  intended (the phone needs them to message one); a name that isn't
  opted in — hidden, undescribed, or `remoteStart` off — gets the same
  "unknown persona" refusal as a made-up one.
  `POST /api/personas` and `GET /api/personas/{registry,suggestions}`
  stay 403 here — editing who may be started is a desk action.
- **`POST /api/jev/route`** (2026-09-28): Jev picks the persona for a
  message server-side; the OpenRouter key stays in
  `~/.config/agent-dashboard/openrouter-key` (0600) on the Mac and is never
  sent to the phone. Rate-limited (1 in flight, 20/min), 8s hard total timeout. It
  sends nothing to any agent — the phone confirms the pick first.
- **Non-Claude panes are never messaged** (`message_gate.py`): an
  OpenCode/Codex pane's prompts are invisible to the dashboard, so the
  server refuses messages to them from every client.
- If the remote listener's port is already in use (another instance, a
  stale process), the dashboard logs a warning and continues running the
  main listener normally — a busy remote port never takes down the board.

## Auth mechanics (for anyone auditing this)

- **Token**: one shared secret in `~/.config/agent-dashboard/remote-token`
  (mode 600), generated/rotated by `scripts/remote-token.py`. Compared with
  `hmac.compare_digest` (constant-time). A token file that is missing,
  empty, or looser than mode 600 (group/other read or write bits set) reads
  as "no token configured" — it is never trusted, even if the bytes inside
  are correct, since a leaked-permission file has already leaked the secret.
- **Session**: `POST /remote/login` exchanges the token for a random
  32-byte session id, held in a server-side map that is also saved to
  `~/.config/agent-dashboard/remote-sessions.json` (mode 600, sha256 of
  each id only — the file is not a cookie jar; a file with looser mode is
  ignored) so a dashboard restart does NOT log the phone out (it used to,
  ~10x a day). Not HMAC-signed. Set as an `HttpOnly; Secure; SameSite=Strict` cookie, 30-day
  `Max-Age`. Each session also remembers a fingerprint of the token that was
  live when it was issued; **rotating the token (`--rotate`) immediately
  invalidates every session already issued**, not just future logins — the
  very next request on an old session gets `401` and has to re-login with
  the new token. An already-open `/api/events` stream re-checks auth on
  every push and closes too (it would otherwise keep streaming and keep
  holding hook prompts as an answer surface).
- **Rate limiting**: 5 failed logins within 60s blocks further wrong-token
  attempts until the window rolls off (in-memory, resets on restart). This
  is keyed on the caller's IP, but every remote request arrives from
  `client_address` `127.0.0.1` (tailscale serve always proxies over
  loopback) — so in practice the window is shared by every remote caller,
  not per-attacker. To keep that from letting an attacker lock the real
  owner out of their own phone, **a request carrying the correct token
  always succeeds regardless of the window** — only a wrong guess is
  subject to the limiter.
- Also acceptable: `Authorization: Bearer <token>` directly, for scripts
  that don't want to carry a cookie jar (the token itself, not a session).

## Not done here (later phases)

- Phone-friendly UI, PWA manifest/service worker (phase 2).
- Push notifications (phase 3).
- Answering Claude Desktop / CLI prompts works from the phone since
  2026-09-27 (`POST /api/hook/permission/<id>/answer` is the one hook route
  on this listener; see dashboard/AGENTS.md "Hook answer bridge").
- Revoking one single issued session without rotating the shared token
  (rotation revokes every session at once — see above;
  since 2026-09-27 a restart no longer does, sessions persist; deleting
  `remote-sessions.json` while the server is stopped also revokes all).
