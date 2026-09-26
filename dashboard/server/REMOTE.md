# Remote access (phase 1a — phone over Tailscale)

Lets a phone reach this dashboard through `tailscale serve`'s HTTPS proxy
instead of only `127.0.0.1:4711`. Off by default; loopback behaviour is
completely unchanged whether this is on or off. See
`docs/plans/2026-09-26-agentbar-mobile-web.md` for the full phased plan —
this covers phase 1a only (server-side access; phone UI and push are later
phases).

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
       "hosts": ["mymac.tailxxxx.ts.net"]
     }
   }
   ```
   `hosts` is the exact hostname(s) `tailscale serve` will front — find it
   with `tailscale status` (your machine's `<name>.<tailnet>.ts.net`).
   Restart the dashboard for the config change to take effect.

3. **Point Tailscale at the dashboard port**:
   ```
   tailscale serve --bg 4711
   ```
   This serves `https://<that ts.net name>/` → `http://127.0.0.1:4711`,
   reachable from any device on your tailnet (including your phone, once
   the Tailscale app is signed into the same tailnet).

   **Never run `tailscale serve --set-path` with `--bg` variants that
   imply Funnel, and never run `tailscale funnel`.** Funnel exposes the
   port to the *public internet*, not just your tailnet — this dashboard
   can start terminal sessions on your Mac; it must never be reachable by
   anyone outside your own tailnet.

4. **Log in from the phone**: open `https://<name>.ts.net/` in Safari →
   redirects to `/remote/login` → paste the token from step 1 → sets a
   30-day session cookie. Add to Home Screen for the fuller PWA experience
   once phase 1b ships the manifest.

## What changes when `remote.enabled` is true

- Loopback requests (`Host: 127.0.0.1`/`localhost`/`[::1]`) are **never**
  affected — same unauthenticated behaviour as today.
- A request whose `Host` matches one of `remote.hosts` now requires auth on
  **every** route, including `GET /api/state`, the `/api/events` SSE
  stream, and static UI assets — not just writes. Unauthenticated: `401`
  JSON for `/api/*`, a redirect to `/remote/login` for everything else.
- Writes (`POST`/`PATCH`/`DELETE`/`PUT`) from an authenticated remote Host
  still enforce CSRF: a browser `Origin` header, when sent, must equal
  `https://<that same remote host>` or the request is refused with `403`.
- Every remote write attempt (allowed or refused) is appended as one JSON
  line to `~/.config/agent-dashboard/remote-audit.jsonl`
  (`ts`, `host`, `route`, `method`, `rowId` when known, `status`).
- A request whose `Host` is neither loopback nor a configured remote host
  gets the pre-existing behaviour: writes are refused (`403`, unchanged),
  GETs are answered exactly as before (deliberately not tightened here, to
  avoid regressing anything that already relies on today's Host-blind GET
  behaviour).

## Auth mechanics (for anyone auditing this)

- **Token**: one shared secret in `~/.config/agent-dashboard/remote-token`
  (mode 600), generated/rotated by `scripts/remote-token.py`. Compared with
  `hmac.compare_digest` (constant-time).
- **Session**: `POST /remote/login` exchanges the token for a random
  32-byte session id, held in an in-memory map on the server process (not
  persisted, not HMAC-signed — a restart just costs the phone one
  re-login). Set as an `HttpOnly; Secure; SameSite=Strict` cookie, 30-day
  `Max-Age`.
- **Rate limiting**: 5 failed logins per source IP within 60s blocks
  further attempts from that IP until the window rolls off (in-memory,
  resets on restart).
- Also acceptable: `Authorization: Bearer <token>` directly, for scripts
  that don't want to carry a cookie jar (the token itself, not a session).

## Not done in phase 1a (later phases)

- Phone-friendly UI, PWA manifest/service worker (phase 2).
- Push notifications (phase 3).
- Revoking a single issued session without restarting the server (today:
  restart clears every session; rotating the token only blocks *future*
  logins, not sessions already granted).
