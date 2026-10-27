#!/usr/bin/env python3
"""Add / remove accounts.json rows from AgentBar Settings › Accounts.

* `POST /api/accounts/add-subscription {label}` -> new `kind: login` row with
  configDir `~/.claude-instances/<id>` (created), then the same login flow as
  `/api/accounts/login` (account_login.start_login).
* `POST /api/accounts/add-api {label, baseUrl, token, model?, tier, authHeader?}`
  -> token goes to the macOS Keychain (service `claude-router-<id>`, account
  $USER, the lookup claude_router.resolve_token does); the row keeps only the
  service name. The token is never logged, returned or written to a file.
* `POST /api/accounts/remove {id}` -> drops the row and the Keychain item this
  module created; a configDir folder is left on disk.

Writes are atomic (temp file + os.replace) and keep other rows, their order
and unknown keys. All three routes are localhost-only.
"""
import json
import os
import re
import subprocess
import tempfile
import threading
from urllib.parse import urlsplit

import account_login
import account_rotation

KEYCHAIN_PREFIX = "claude-router-"
INSTANCES_DIR = "~/.claude-instances"
TIERS = ("claude", "fallback")
AUTH_HEADERS = ("bearer", "x-api-key")
LOCAL_HOSTS = ("127.0.0.1", "localhost")
_write_lock = threading.Lock()


class KeychainOps:
    """The `security` calls. argv lists, no shell. Tests pass a fake."""

    def _user(self):
        return os.environ.get("USER", "")

    def store(self, service, token):
        proc = subprocess.run(
            ["security", "add-generic-password", "-U", "-a", self._user(), "-s", service,
             "-w", token],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        return proc.returncode == 0

    def delete(self, service):
        proc = subprocess.run(
            ["security", "delete-generic-password", "-a", self._user(), "-s", service],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        return proc.returncode == 0


# ── accounts.json ──

def _read_doc(path):
    """The whole file as a dict ({"accounts": [...], ...other keys})."""
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        return {"accounts": []}
    if isinstance(data, list):
        return {"accounts": data}
    data.setdefault("accounts", [])
    return data


def _write_doc(path, doc):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".accounts-", suffix=".json", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f, indent=2)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def slug_id(label, taken):
    base = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")[:40] or "account"
    candidate, n = base, 2
    while candidate in taken:
        candidate, n = f"{base}-{n}", n + 1
    return candidate


def _label(body):
    label = (body or {}).get("label")
    return label.strip() if isinstance(label, str) and label.strip() else None


def _append(row_for_id, label, path):
    """Under the lock: pick a unique id, build the row, write. A Claude-tier row
    goes before the first fallback row: rotation never passes a needsApproval
    row, so a subscription appended after DeepSeek would never be used."""
    with _write_lock:
        doc = _read_doc(path)
        rows = doc["accounts"]
        taken = {r.get("id") for r in rows if isinstance(r, dict)}
        row = row_for_id(slug_id(label, taken))
        first_fallback = next((i for i, r in enumerate(rows) if isinstance(r, dict)
                               and r.get("needsApproval")), len(rows))
        rows.insert(len(rows) if row.get("needsApproval") else first_fallback, row)
        _write_doc(path, doc)
    return row


# ── routes ──

def add_subscription(body, ops=None, accounts_file=None, instances_dir=None):
    label = _label(body)
    if not label:
        return {"ok": False, "error": "missing label"}
    path = accounts_file or account_rotation.accounts_path()
    base = os.path.expanduser(instances_dir or INSTANCES_DIR)

    def build(account_id):
        config_dir = os.path.join(base, account_id)
        os.makedirs(config_dir, exist_ok=True)
        return {"id": account_id, "label": label, "kind": "login", "tier": "claude",
                "configDir": config_dir}

    try:
        row = _append(build, label, path)
    except (OSError, ValueError) as e:
        return {"ok": False, "error": f"accounts.json: {e}"}
    login = account_login.start_login({"id": row["id"]}, ops=ops, accounts_file=path)
    reply = {"ok": login.get("ok", False), "account": row, "tab": login.get("tab")}
    if not login.get("ok"):
        reply["error"] = f"account added, login did not start: {login.get('error')}"
    return reply


def _valid_base_url(url):
    if not isinstance(url, str):
        return False
    parts = urlsplit(url.strip())
    if not parts.hostname:
        return False
    return parts.scheme == "https" or (parts.scheme == "http" and parts.hostname in LOCAL_HOSTS)


def add_api(body, keychain=None, accounts_file=None):
    body = body or {}
    label, token = _label(body), body.get("token")
    base_url, model = body.get("baseUrl"), body.get("model")
    tier, auth = body.get("tier", "claude"), body.get("authHeader")
    if not label:
        return {"ok": False, "error": "missing label"}
    if not _valid_base_url(base_url):
        return {"ok": False, "error": "baseUrl must be https (http only for localhost)"}
    if not isinstance(token, str) or not token.strip():
        return {"ok": False, "error": "missing token"}
    if tier not in TIERS:
        return {"ok": False, "error": f"tier must be one of {TIERS}"}
    if auth is not None and auth not in AUTH_HEADERS:
        return {"ok": False, "error": f"authHeader must be one of {AUTH_HEADERS}"}
    if model is not None and not isinstance(model, str):
        return {"ok": False, "error": "model must be a string"}
    keychain = keychain or KeychainOps()
    path = accounts_file or account_rotation.accounts_path()
    stored = {}

    def build(account_id):
        service = KEYCHAIN_PREFIX + account_id
        if not keychain.store(service, token.strip()):
            raise OSError("could not save the API key to the Keychain")
        stored["service"] = service
        row = {"id": account_id, "label": label, "kind": "apikey", "tier": tier,
               "needsApproval": tier == "fallback", "baseUrl": base_url.strip().rstrip("/")}
        if model and model.strip():
            row["model"] = model.strip()
        if auth:
            row["authHeader"] = auth
        row["tokenKeychain"] = service
        return row

    try:
        row = _append(build, label, path)
    except (OSError, ValueError) as e:
        if stored.get("service"):  # Keychain written but file not: undo
            keychain.delete(stored["service"])
        return {"ok": False, "error": str(e)}
    return {"ok": True, "account": row}


def remove(body, keychain=None, accounts_file=None):
    account_id = (body or {}).get("id")
    if not isinstance(account_id, str) or not account_id:
        return {"ok": False, "error": "missing id"}
    path = accounts_file or account_rotation.accounts_path()
    try:
        with _write_lock:
            doc = _read_doc(path)
            row = next((r for r in doc["accounts"]
                        if isinstance(r, dict) and r.get("id") == account_id), None)
            if row is None:
                return {"ok": False, "error": f"unknown account {account_id!r}"}
            doc["accounts"] = [r for r in doc["accounts"] if r is not row]
            _write_doc(path, doc)
    except (OSError, ValueError) as e:
        return {"ok": False, "error": f"accounts.json: {e}"}
    reply = {"ok": True, "removed": account_id}
    if row.get("tokenKeychain") == KEYCHAIN_PREFIX + account_id:
        reply["keychainDeleted"] = (keychain or KeychainOps()).delete(row["tokenKeychain"])
    if row.get("configDir"):
        reply["note"] = f"sign-in folder left on disk: {row['configDir']}"
    return reply
