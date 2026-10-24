"""Apple Push Notification service (APNs) sender — direct from this Mac to the
native AgentBar iOS app (and its Apple Watch mirror), token-based auth.

OFF and silent unless `<CONFIG_HOME>/apns.json` exists (CONFIG_HOME =
`~/.config/agent-dashboard`, override CHIEF_DASHBOARD_CONFIG_HOME; override the
file itself with AGENTBAR_APNS_CONFIG). Keep it and the .p8 key mode 0600,
outside git:

    {"keyPath": "~/.config/agent-dashboard/AuthKey_ABC123.p8",
     "keyId": "ABC123", "teamId": "SELAV8N2B9",
     "bundleId": "<iOS app bundle id>", "sandbox": true}

`sandbox: true` -> api.sandbox.push.apple.com (Xcode/debug builds);
false -> api.push.apple.com (TestFlight / App Store).

Zero third-party deps, like the rest of the server: the ES256 JWT is signed by
`openssl` (DER signature converted to JOSE r||s here) and the HTTP/2 POST goes
through `/usr/bin/curl --http2` (macOS curl ships nghttp2). Both are system
binaries; Python has no stdlib HTTP/2.

Contract for the iOS side (UNNotificationCategory ids + action ids):

  AGENT_PERMISSION   a permission prompt is waiting.
     actions: ALLOW, DENY, REPLY (UNTextInputNotificationAction; text = deny
              message / guidance).
     userInfo: requestId, agent (persona/folder name), summary (<=60 chars),
               toolName.
     answer -> POST /api/hook/permission/<requestId>/answer (remote listener,
               Bearer token), body {"behavior": "allow"} or
               {"behavior": "deny", "message": "<REPLY text>"} — the same
               route AgentBar and the web remote use.
     apns-collapse-id = requestId. When the prompt is answered here, a
     silent push {"withdrawn": requestId} (content-available, same collapse
     id) tells the app to remove that delivered notification.

  AGENT_MESSAGE      an agent finished / wants input (Phase 2, not sent yet).
     actions: REPLY (text input), CONTINUE, STOP.
     userInfo: agent, summary, sessionId.

Device tokens: apns_devices.py (register/unregister routes + 0600 registry).
"""
import base64
import json
import os
import subprocess
import threading
import time

import dashboard_config

CONFIG_PATH = os.environ.get("AGENTBAR_APNS_CONFIG") or os.path.join(
    dashboard_config.CONFIG_HOME, "apns.json")
PRODUCTION_HOST = "https://api.push.apple.com"
SANDBOX_HOST = "https://api.sandbox.push.apple.com"
#: Apple rejects provider tokens older than 60 min and throttles refreshes
#: more often than every 20 min.
PROVIDER_TOKEN_TTL_SEC = 50 * 60
SEND_TIMEOUT_SEC = 10
#: Apple reasons meaning "this device token is dead, forget it".
DEAD_TOKEN_REASONS = frozenset({"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"})
_REQUIRED_KEYS = ("keyPath", "keyId", "teamId", "bundleId")


def load_config(path=None):
    """Validated config dict, or None (feature off). Never raises."""
    try:
        with open(path or CONFIG_PATH) as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict) or not all(isinstance(raw.get(k), str) and raw[k] for k in _REQUIRED_KEYS):
        return None
    key_path = os.path.expanduser(raw["keyPath"])
    if not os.path.isfile(key_path):
        return None
    return {"keyPath": key_path, "keyId": raw["keyId"], "teamId": raw["teamId"],
            "bundleId": raw["bundleId"], "sandbox": bool(raw.get("sandbox"))}


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_signature_to_jose(der):
    """ECDSA DER (SEQUENCE{INTEGER r, INTEGER s}) -> 64-byte r||s for ES256."""
    def read_int(offset):
        if der[offset] != 0x02:
            raise ValueError("bad DER integer")
        length = der[offset + 1]
        value = der[offset + 2: offset + 2 + length].lstrip(b"\x00")
        return value.rjust(32, b"\x00"), offset + 2 + length
    if der[0] != 0x30:
        raise ValueError("bad DER sequence")
    start = 3 if der[1] & 0x80 else 2
    r, offset = read_int(start)
    s, _ = read_int(offset)
    return r + s


def _openssl_sign(key_path, message):
    result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                            input=message, capture_output=True, timeout=SEND_TIMEOUT_SEC, check=True)
    return result.stdout


def make_provider_token(config, issued_at, sign=_openssl_sign):
    header = _b64url(json.dumps({"alg": "ES256", "kid": config["keyId"]}).encode())
    claims = _b64url(json.dumps({"iss": config["teamId"], "iat": int(issued_at)}).encode())
    signing_input = f"{header}.{claims}".encode()
    signature = der_signature_to_jose(sign(config["keyPath"], signing_input))
    return f"{header}.{claims}.{_b64url(signature)}"


def curl_http2_post(url, headers, body):
    """(status, reason) of one HTTP/2 POST via the system curl."""
    command = ["/usr/bin/curl", "--http2", "--silent", "--show-error",
               "--max-time", str(SEND_TIMEOUT_SEC), "--write-out", "\n%{http_code}",
               "--data-binary", "@-", url]
    for name, value in headers.items():
        command[1:1] = ["--header", f"{name}: {value}"]
    result = subprocess.run(command, input=body, capture_output=True, timeout=SEND_TIMEOUT_SEC + 5)
    text, _, status = result.stdout.decode(errors="replace").rpartition("\n")
    try:
        reason = (json.loads(text) or {}).get("reason") if text.strip() else None
    except ValueError:
        reason = text.strip()[:200] or None
    return int(status) if status.isdigit() else 0, reason or result.stderr.decode(errors="replace").strip()[:200] or None


class ApnsClient:
    """send(device_token, payload, ...) -> (status, reason). Thread-safe;
    the provider token is cached PROVIDER_TOKEN_TTL_SEC."""

    def __init__(self, config, post=curl_http2_post, sign=_openssl_sign, clock=time.time):
        self.config = config
        self._post, self._sign, self._clock = post, sign, clock
        self._lock = threading.Lock()
        self._token, self._token_at = None, 0.0

    def provider_token(self):
        with self._lock:
            now = self._clock()
            if not self._token or now - self._token_at >= PROVIDER_TOKEN_TTL_SEC:
                self._token, self._token_at = make_provider_token(self.config, now, self._sign), now
            return self._token

    def send(self, device_token, payload, collapse_id=None, background=False):
        host = SANDBOX_HOST if self.config["sandbox"] else PRODUCTION_HOST
        headers = {"authorization": f"bearer {self.provider_token()}",
                   "apns-topic": self.config["bundleId"],
                   "apns-push-type": "background" if background else "alert",
                   "apns-priority": "5" if background else "10"}
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id[:64]
        return self._post(f"{host}/3/device/{device_token}", headers, json.dumps(payload).encode())


def client_from_config(path=None):
    """An ApnsClient, or None when the feature is not configured."""
    config = load_config(path)
    return ApnsClient(config) if config else None
