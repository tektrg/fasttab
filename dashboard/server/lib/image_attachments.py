"""Image attachments for Send message (AgentBar panel + phone PWA).

Why a file path and not an image block: the Claude peer socket
(session_inbox.py) silently DROPS non-string `content` (spike, 2026-09-29),
and pane/Codex delivery is typed text anyway. So every transport gets the
same thing: the image is stored on disk here and the message text gains
" [Image attached: <abs path> — open it with the Read tool]" per image.
The agent Reads the file itself.

Flow: POST /api/attachments/image (raw image bytes) -> {id}; then
POST /api/session/message {..., attachments: [id, ...]}. Ids only ever cross
the wire — a path is built here from a strict-regex id, so no client input
names a file.

Storage: ATTACHMENTS_DIR (dir 0700, files 0600), <uuid-hex>.<ext>, removed
after TTL_SECONDS (swept on startup and on every upload).
"""
import os
import re
import time
import uuid

#: Env override exists for tests (never write the real dir from a test).
ATTACHMENTS_DIR = os.environ.get("AGENTBAR_ATTACHMENTS_DIR") or os.path.expanduser(
    "~/.agentbar/attachments")
MAX_IMAGE_BYTES = 5 * 1024 * 1024
MAX_ATTACHMENTS = 4
TTL_SECONDS = 7 * 24 * 3600

#: content type -> file extension. Anything else is refused.
_EXT_BY_TYPE = {"image/png": "png", "image/jpeg": "jpg",
                "image/gif": "gif", "image/webp": "webp"}
_ID_RE = re.compile(r"^[0-9a-f]{32}$")


def _sniff(data):
    """The content type the bytes really are (magic bytes), or None."""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def _ensure_dir(directory):
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)


def sweep_expired(directory=None, now=None):
    """Delete attachments older than TTL_SECONDS. Returns how many."""
    directory = directory or ATTACHMENTS_DIR
    now = time.time() if now is None else now
    removed = 0
    try:
        names = os.listdir(directory)
    except OSError:
        return 0
    for name in names:
        path = os.path.join(directory, name)
        try:
            if os.path.isfile(path) and now - os.path.getmtime(path) > TTL_SECONDS:
                os.remove(path)
                removed += 1
        except OSError:
            pass
    return removed


def store_image(data, content_type, directory=None):
    """Validate + store one image. Returns ({"ok": True, "id"}, 200) or
    ({"ok": False, "error"}, 4xx)."""
    directory = directory or ATTACHMENTS_DIR
    declared = (content_type or "").split(";")[0].strip().lower()
    if declared not in _EXT_BY_TYPE:
        return {"ok": False, "error": "Content-Type must be image/png, image/jpeg, image/gif or image/webp"}, 415
    if not data:
        return {"ok": False, "error": "empty image"}, 400
    if len(data) > MAX_IMAGE_BYTES:
        return {"ok": False, "error": "image over 5 MB — downscale it first"}, 413
    sniffed = _sniff(data)
    if sniffed is None:
        return {"ok": False, "error": "not an image (file contents don't match any allowed type)"}, 415
    _ensure_dir(directory)
    sweep_expired(directory)
    attachment_id = uuid.uuid4().hex
    # Extension from the SNIFFED type: the file is what its bytes are.
    path = os.path.join(directory, f"{attachment_id}.{_EXT_BY_TYPE[sniffed]}")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    return {"ok": True, "id": attachment_id}, 200


def resolve_paths(ids, directory=None):
    """(paths, None) for a list of attachment ids, or (None, reason).
    None/[] -> ([], None)."""
    directory = directory or ATTACHMENTS_DIR
    if ids is None or ids == []:
        return [], None
    if not isinstance(ids, list):
        return None, "refused: attachments must be a list of ids"
    if len(ids) > MAX_ATTACHMENTS:
        return None, f"refused: at most {MAX_ATTACHMENTS} images per message"
    paths = []
    for attachment_id in ids:
        if not isinstance(attachment_id, str) or not _ID_RE.match(attachment_id):
            return None, "refused: invalid attachment id"
        found = next((os.path.join(directory, f"{attachment_id}.{ext}")
                      for ext in _EXT_BY_TYPE.values()
                      if os.path.isfile(os.path.join(directory, f"{attachment_id}.{ext}"))), None)
        if found is None:
            return None, "refused: attachment not found (expired or never uploaded) — attach it again"
        paths.append(os.path.abspath(found))
    return paths, None


def attachment_note(path):
    return f" [Image attached: {path} — open it with the Read tool]"


#: Text used when the PO sends images with no words.
IMAGE_ONLY_TEXT = "See the attached image."


def with_attachment_notes(text, paths):
    """`text` + one note per image path (empty text gets IMAGE_ONLY_TEXT)."""
    if not paths:
        return text
    base = (text or "").strip() or IMAGE_ONLY_TEXT
    return base + "".join(attachment_note(p) for p in paths)
