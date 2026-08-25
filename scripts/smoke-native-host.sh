#!/usr/bin/env bash
#
# End-to-end smoke test for the FastTab native-messaging host relay.
#
# Simulates Chrome (a process speaking the 4-byte-length-prefixed framing over
# stdin/stdout) and FastTab.app (a Unix-socket listener) without either running.
# Verifies the host forwards a frame in both directions verbatim.
#
# Usage: scripts/smoke-native-host.sh
#
# By default this compiles a debug host binary and tests that. Set
# FASTTAB_HOST_BIN to an existing binary to test it as-is instead of building —
# use that to check the *signed* relay inside dist/FastTab.app, which is the one
# Chrome actually launches, e.g.
#   FASTTAB_HOST_BIN=dist/FastTab.app/Contents/MacOS/FastTabNativeHost \
#     scripts/smoke-native-host.sh
# Testing the signed copy is the only way this script can catch a signing
# mistake (wrong entitlements ⇒ the kernel SIGKILLs the relay on exec).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

if [[ -n "${FASTTAB_HOST_BIN:-}" ]]; then
  echo "==> Using prebuilt host binary: ${FASTTAB_HOST_BIN}"
  HOST_BIN="${FASTTAB_HOST_BIN}"
else
  echo "==> Building host binary"
  swift build 2>/dev/null
  HOST_BIN="$(swift build --show-bin-path)/FastTabNativeHost"
fi
[[ -f "${HOST_BIN}" ]] || { echo "smoke: host binary not found at ${HOST_BIN}" >&2; exit 1; }

echo "==> Running relay round-trip"
python3 - "${HOST_BIN}" <<'PYEOF'
import os, socket, struct, subprocess, sys, tempfile, threading

host_bin = sys.argv[1]
socket_path = os.path.join(tempfile.mkdtemp(), "host-test.sock")

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(1)

received = []
def read_frame(conn):
    length = b""
    while len(length) < 4:
        chunk = conn.recv(4 - len(length))
        if not chunk: return None
        length += chunk
    n = struct.unpack("<I", length)[0]
    payload = b""
    while len(payload) < n:
        chunk = conn.recv(n - len(payload))
        if not chunk: return None
        payload += chunk
    return payload

# The relay intentionally DROPS ping/pong frames on the socket->stdout leg:
# those are app<->bridge keepalives, and Chrome closes the native-messaging
# port the moment the host sends it an unsolicited frame. So the app side here
# sends a pong (must be swallowed) followed by a real frame (must arrive) —
# that checks the forwarding and the filter in one pass.
FILTERED = b'{"v":1,"type":"pong","seq":0,"payload":{}}'
EXPECTED = b'{"v":1,"type":"tabs","seq":0,"payload":{}}'

def relay_thread():
    conn, _ = server.accept()
    msg = read_frame(conn)
    if msg is not None:
        received.append(msg)
    for reply in (FILTERED, EXPECTED):
        conn.sendall(struct.pack("<I", len(reply)) + reply)
    conn.close()
    server.close()

t = threading.Thread(target=relay_thread)
t.start()

env = dict(os.environ, FASTTAB_HOST_SOCKET=socket_path)
proc = subprocess.Popen([host_bin], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)

outbound = b'{"v":1,"type":"hello","seq":1,"payload":{"app":"chrome"}}'
proc.stdin.write(struct.pack("<I", len(outbound)) + outbound)
proc.stdin.flush()

length = proc.stdout.read(4)
assert len(length) == 4, f"no reply length from host, got {length!r}"
n = struct.unpack("<I", length)[0]
reply = proc.stdout.read(n)

t.join(timeout=5)
proc.terminate()
proc.wait()

assert received and received[0] == outbound, f"relay to app mismatch: {received!r}"
assert reply == EXPECTED, f"reply mismatch: {reply!r}"
print("OK: host relayed a frame in both directions (stdin->socket, socket->stdout)")
print("OK: ping/pong keepalive was filtered out of the Chrome-facing stream")
PYEOF
