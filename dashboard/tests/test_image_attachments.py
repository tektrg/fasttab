#!/usr/bin/env python3
"""Image attachments (server/lib/image_attachments.py) and their wiring:
POST /api/attachments/image (real HTTP on a throwaway port) and
`POST /api/session/message {attachments}` appending a path note per image
on every transport (pane, inbox, OpenCode/Codex), plus the session inbox's
non-string-content guard.

SAFETY: temp attachments dir (AGENTBAR_ATTACHMENTS_DIR), temp state/config,
no herdr/ssh/socket: every transport is replaced by a recorder. Hostile
input is the inert sentinel `$(echo INJECTED)` only.
"""
import importlib.util
import json
import os
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="image-attach-test-")
ATTACH_DIR = os.path.join(_tmp, "attachments")
os.environ["AGENTBAR_ATTACHMENTS_DIR"] = ATTACH_DIR
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = os.path.join(_tmp, "config")
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = os.path.join(_tmp, "state")
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"
os.environ["CHIEF_HERDR_BIN"] = os.path.join(_tmp, "no-such-herdr")
os.environ["AGENTBAR_PERSONAS_FILE"] = os.path.join(_tmp, "no-personas.json")
sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import image_attachments as ia  # noqa: E402
import session_inbox  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64
SENTINEL = "$(echo INJECTED)"

print("== store_image validation ==")
check("attachments dir is the temp override", ia.ATTACHMENTS_DIR, ATTACH_DIR)
payload, status = ia.store_image(PNG, "image/png")
check("png stored", (status, payload.get("ok")), (200, True))
png_id = payload.get("id")
check("dir mode 0700", oct(os.stat(ATTACH_DIR).st_mode & 0o777), "0o700")
check("file mode 0600", oct(os.stat(os.path.join(ATTACH_DIR, f"{png_id}.png")).st_mode & 0o777), "0o600")
check("wrong content type refused", ia.store_image(PNG, "text/plain")[1], 415)
check("svg refused", ia.store_image(b"<svg/>", "image/svg+xml")[1], 415)
check("bytes not an image refused", ia.store_image(b"hello " + SENTINEL.encode(), "image/png")[1], 415)
check("empty refused", ia.store_image(b"", "image/png")[1], 400)
check("over 5 MB refused", ia.store_image(PNG + b"\x00" * ia.MAX_IMAGE_BYTES, "image/png")[1], 413)
jpeg_payload, _ = ia.store_image(JPEG, "image/png")  # declared png, sniffed jpeg
check("extension follows the sniffed bytes",
      os.path.isfile(os.path.join(ATTACH_DIR, f"{jpeg_payload['id']}.jpg")), True)

print("\n== resolve_paths ==")
paths, why = ia.resolve_paths([png_id])
check("known id resolves to an absolute path", (paths, why), ([os.path.join(ATTACH_DIR, f"{png_id}.png")], None))
check("None -> no images", ia.resolve_paths(None), ([], None))
for bad in ("../../etc/passwd", SENTINEL, png_id + "/x", png_id.upper(), 5):
    got, why = ia.resolve_paths([bad])
    check(f"bad id {bad!r} refused", (got, (why or "").startswith("refused")), (None, True))
check("unknown id refused", ia.resolve_paths(["0" * 32])[0], None)
check("over 4 refused", ia.resolve_paths([png_id] * 5)[0], None)
check("not a list refused", ia.resolve_paths(png_id)[0], None)
print("\n== accepts_images (the row flag + send-path rule) ==")
check("local row", ia.accepts_images({"machine": "local"}, "local"), True)
check("row without machine = local", ia.accepts_images({}, "local"), True)
check("Air row", ia.accepts_images({"machine": "air-m1"}, "local"), False)
check("None row: no crash", ia.accepts_images(None, "local"), True)
check("note text", ia.with_attachment_notes("look", ["/a.png"]),
      "look [Image attached: /a.png — open it with the Read tool]")
check("image-only message gets a default text",
      ia.with_attachment_notes("  ", ["/a.png"]).startswith(ia.IMAGE_ONLY_TEXT), True)

print("\n== TTL sweep ==")
old_payload, _ = ia.store_image(PNG, "image/png")
old_path = os.path.join(ATTACH_DIR, f"{old_payload['id']}.png")
eight_days_ago = time.time() - 8 * 24 * 3600
os.utime(old_path, (eight_days_ago, eight_days_ago))
check("sweep removes only the expired file", ia.sweep_expired(), 1)
check("expired file gone", os.path.exists(old_path), False)
check("fresh file kept", os.path.isfile(paths[0]), True)
os.utime(paths[0], (eight_days_ago, eight_days_ago))
ia.store_image(PNG, "image/png")  # an upload sweeps too
check("upload sweeps expired files", os.path.exists(paths[0]), False)
png_id = ia.store_image(PNG, "image/png")[0]["id"]
png_path = os.path.join(ATTACH_DIR, f"{png_id}.png")

print("\n== session inbox refuses non-string content ==")
got = session_inbox.send_message("sid", [{"type": "image"}], sessions_dir=_tmp)
check("list content not sent", (got["delivered"], got["maybeDelivered"]), (False, False))
check("reason says why", "image blocks" in (got["error"] or ""), True)
try:
    session_inbox._wire_lines("t", [{"type": "image"}])
    check("_wire_lines raises on a list", False, True)
except TypeError:
    check("_wire_lines raises on a list", True, True)

print("\n== server: load ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_image_test", os.path.join(DASHBOARD_ROOT, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

print("\n== POST /api/attachments/image over HTTP ==")
server = _srv.QuietThreadingHTTPServer(("127.0.0.1", 0), _srv.Handler)
server.remote_listener = False
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"


def upload(data, ctype):
    req = urllib.request.Request(base + "/api/attachments/image", data=data, method="POST",
                                 headers={"Content-Type": ctype})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


big = PNG + os.urandom(3 * 1024 * 1024)  # > the 1 MB JSON cap, < 5 MB
status, body = upload(big, "image/png")
check(">1 MB image accepted (own cap)", (status, body.get("ok")), (200, True))
big_path = os.path.join(ATTACH_DIR, f"{body.get('id')}.png")
check(">1 MB image stored intact", os.path.getsize(big_path) if os.path.exists(big_path) else 0, len(big))
check("text/plain refused over HTTP", upload(PNG, "text/plain")[0], 415)
try:
    status = upload(PNG + b"\x00" * ia.MAX_IMAGE_BYTES, "image/png")[0]
except (ConnectionError, urllib.error.URLError):
    status = 413  # refused unread; the server closed the socket mid-send
check("over 5 MB refused over HTTP", status, 413)
server.shutdown()

print("\n== /api/session/message appends a note per image, every transport ==")
typed = []
_srv._enrich_agents_for_actions = lambda state, agents: None
_srv._own_pane_cached = lambda ids: None
_srv.time.sleep = lambda s: None
_srv._read_pane_now = lambda *a, **k: ([], None)
_srv._type_text = lambda pane, text, **k: typed.append(("pane", text))
_srv._send_keys = lambda *a, **k: None
_srv.session_inbox.deliver_row_message = (
    lambda agent, text, confirm, send=None: typed.append(("inbox", text)) or {"ok": True, "state": "message sent"})
_srv.tui_message.check = lambda agent, pane, text, lines, entries: ({"tool": "codex"}, None)
_srv.tui_message.deliver = (
    lambda pane, text, lines, busy, entry, io: typed.append(("tui", text)) or {"ok": True, "state": "message sent"})
_srv.message_gate.blind_agent_refusal = lambda agent: None
_srv.message_gate.is_tui_row = lambda agent: agent.get("agentKind") == "codex"
AGENTS = [
    {"rowId": "pane-row", "agentSession": "pane-row", "paneId": "w1:p1", "machine": "local",
     "agentKind": "claude", "hasHookData": True, "source": "herdr", "label": "a"},
    {"rowId": "inbox-row", "agentSession": "inbox-row", "paneId": None, "machine": "local",
     "source": "claude-desktop", "messageVia": "inbox", "hasHookData": True},
    {"rowId": "tui-row", "agentSession": "tui-row", "paneId": "w1:p2", "machine": "local",
     "agentKind": "codex", "hasHookData": True, "source": "herdr", "label": "b"},
    {"rowId": "air-row", "agentSession": "air-row", "paneId": "air-m1:w1:p1", "machine": "air-m1",
     "agentKind": "claude", "hasHookData": True, "source": "herdr", "label": "c"},
]
_srv.resolve_agent_row_id = lambda a: a.get("rowId")
_srv.session_inbox.message_via = lambda a: a.get("messageVia")
_srv.get_full_state = lambda: {"computed": {"agents": AGENTS}}
want_note = ia.attachment_note(png_path)
for row, kind in (("pane-row", "pane"), ("inbox-row", "inbox"), ("tui-row", "tui")):
    typed.clear()
    _srv.handle_session_action("message", {"rowId": row, "actor": "po", "text": "see this",
                                           "attachments": [png_id], "confirm": True})
    check(f"{kind}: text + note delivered", typed, [(kind, "see this" + want_note)])
typed.clear()
res = _srv.handle_session_action("message", {"rowId": "pane-row", "actor": "po", "text": "",
                                             "attachments": [png_id, png_id], "confirm": True})
check("image-only: two notes", typed, [("pane", ia.IMAGE_ONLY_TEXT + want_note * 2)])
typed.clear()
res = _srv.handle_session_action("message", {"rowId": "pane-row", "actor": "po", "text": "x",
                                             "attachments": [SENTINEL]})
check("sentinel id refused before typing", (res.get("ok"), res.get("typed"), typed), (False, False, []))
check("sentinel never echoed", SENTINEL in json.dumps(res) or "INJECTED" in json.dumps(res), False)
res = _srv.handle_session_action("message", {"rowId": "air-row", "actor": "po", "text": "x",
                                             "attachments": [png_id]})
check("other-Mac row refused (file not on its disk)", (res.get("ok"), typed), (False, []))
res = _srv.handle_session_action("message", {"rowId": "pane-row", "actor": "po",
                                             "text": "y" * 7990, "attachments": [png_id]})
check("note counted in the 8000-char limit", (res.get("ok"), typed), (False, []))
_srv.handle_session_action("message", {"rowId": "pane-row", "actor": "po", "text": "plain", "confirm": True})
check("no attachments: text unchanged", typed, [("pane", "plain")])

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All image attachment checks passed.")
