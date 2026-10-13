"""Voice-note audio uploads (phone web app -> dashboard).

Mirrors image_attachments.py and shares its folder, id format and 7-day
sweep: POST /api/attachments/audio (raw audio bytes) -> {id}. A path is only
ever built from a strict-regex id, never from client input. The file is
named by what its BYTES are (magic-byte sniff), not by the declared type.
Transcription lives in voice_transcription.py.
"""
import os
import uuid

import image_attachments

MAX_AUDIO_BYTES = 25 * 1024 * 1024

#: Declared content type -> True. Anything else is refused with 415.
ALLOWED_TYPES = frozenset({
    "audio/mp4", "audio/x-m4a", "audio/webm", "audio/ogg",
    "audio/mpeg", "audio/wav", "audio/aac",
})
#: Sniffed container -> file extension.
_EXT_BY_SNIFFED = {"mp4": "m4a", "webm": "webm", "ogg": "ogg",
                   "mp3": "mp3", "wav": "wav", "aac": "aac"}
AUDIO_EXTENSIONS = tuple(sorted(set(_EXT_BY_SNIFFED.values())))
OVER_CAP_MESSAGE = "Recording is over 25 MB. Record a shorter note."


def sniff_container(data):
    """The container the bytes really are ("mp4", "webm", ...) or None."""
    if len(data) < 12:
        return None
    if data[4:8] == b"ftyp":
        return "mp4"
    if data[:4] == b"\x1a\x45\xdf\xa3":
        return "webm"
    if data[:4] == b"OggS":
        return "ogg"
    if data[:4] == b"RIFF" and data[8:12] == b"WAVE":
        return "wav"
    if data[:3] == b"ID3":
        return "mp3"
    if data[0] == 0xFF and (data[1] & 0xE0) == 0xE0:
        # ADTS AAC has layer bits 00; MPEG audio (mp3) uses 01/10/11.
        return "aac" if (data[1] & 0x06) == 0 else "mp3"
    return None


def store_audio(data, content_type, directory=None):
    """Validate + store one recording. Returns (payload, http_status)."""
    directory = directory or image_attachments.ATTACHMENTS_DIR
    declared = (content_type or "").split(";")[0].strip().lower()
    if declared not in ALLOWED_TYPES:
        return {"ok": False, "error": "That audio format isn't supported."}, 415
    if not data:
        return {"ok": False, "error": "The recording is empty."}, 400
    if len(data) > MAX_AUDIO_BYTES:
        return {"ok": False, "error": OVER_CAP_MESSAGE}, 413
    container = sniff_container(data)
    if container is None:
        return {"ok": False, "error": "That file doesn't look like an audio recording."}, 415
    image_attachments.ensure_private_dir(directory)
    image_attachments.sweep_expired(directory)
    audio_id = uuid.uuid4().hex
    path = os.path.join(directory, f"{audio_id}.{_EXT_BY_SNIFFED[container]}")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    return {"ok": True, "id": audio_id}, 200


def find_audio(audio_id, directory=None):
    """Absolute path of the stored recording for a valid id, else None."""
    if not isinstance(audio_id, str) or not image_attachments.ID_RE.match(audio_id):
        return None
    directory = directory or image_attachments.ATTACHMENTS_DIR
    for ext in AUDIO_EXTENSIONS:
        path = os.path.join(directory, f"{audio_id}.{ext}")
        if os.path.isfile(path):
            return os.path.abspath(path)
    return None
