"""Registry of the iOS app's APNs device tokens + its routes.

  POST   /api/apns/devices   {deviceToken, label?} -> {ok}
  DELETE /api/apns/devices   {deviceToken}         -> {ok, removed}

Served on both listeners; on the remote (tailscale) one the server's
`_reject_foreign_write` has already authenticated it (Bearer token / session
cookie, Origin-checked, audited) like every remote write.

Persisted to `<CONFIG_HOME>/apns-devices.json` (mode 0600, atomic replace;
override AGENTBAR_APNS_DEVICES_FILE). A token Apple reports dead is dropped
by apns_permission_push via `remove`.
"""
import json
import os
import re
import threading
import time

import dashboard_config

DEVICES_PATH = os.environ.get("AGENTBAR_APNS_DEVICES_FILE") or os.path.join(
    dashboard_config.CONFIG_HOME, "apns-devices.json")
ROUTE = "/api/apns/devices"
MAX_LABEL_CHARS = 80
_DEVICE_TOKEN_RE = re.compile(r"^[0-9a-fA-F]{32,200}$")


class DeviceRegistry:
    def __init__(self, path=DEVICES_PATH, clock=time.time):
        self.path, self._clock = path, clock
        self._lock = threading.Lock()

    def _read(self):
        try:
            with open(self.path) as f:
                devices = json.load(f)
            return devices if isinstance(devices, dict) else {}
        except (OSError, ValueError):
            return {}

    def _write(self, devices):
        tmp_path = f"{self.path}.{os.getpid()}.tmp"
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(devices, f, indent=1)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, self.path)

    def tokens(self):
        with self._lock:
            return list(self._read())

    def add(self, device_token, label=None):
        with self._lock:
            devices = self._read()
            devices[device_token] = {"label": label or "", "registeredAt": self._clock()}
            self._write(devices)

    def remove(self, device_token):
        with self._lock:
            devices = self._read()
            if device_token not in devices:
                return False
            del devices[device_token]
            self._write(devices)
            return True


REGISTRY = DeviceRegistry()


def _device_token(body):
    token = body.get("deviceToken") if isinstance(body, dict) else None
    if not isinstance(token, str) or not _DEVICE_TOKEN_RE.match(token):
        raise ValueError("deviceToken must be the hex APNs device token")
    return token.lower()


def handle(method, path, read_body, registry=None):
    """(payload, status) for the devices route, else None."""
    if path != ROUTE or method not in ("POST", "DELETE"):
        return None
    registry = registry or REGISTRY
    try:
        body = read_body()
        token = _device_token(body)
    except ValueError as e:
        return {"ok": False, "error": str(e)}, 400
    if method == "DELETE":
        return {"ok": True, "removed": registry.remove(token)}, 200
    label = body.get("label")
    registry.add(token, label.strip()[:MAX_LABEL_CHARS] if isinstance(label, str) else None)
    return {"ok": True}, 200
