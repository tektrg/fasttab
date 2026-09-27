#!/usr/bin/env python3
"""Generate or rotate the phase-1a remote-access token
(~/.config/agent-dashboard/remote-token, mode 600).

This is the one shared secret a phone (or anything else reaching the
dashboard through `tailscale serve`) exchanges at /remote/login for a
session cookie — see server/lib/remote_access.py. It has nothing to do
with loopback access, which stays unauthenticated exactly as before.

Usage:
    python3 scripts/remote-token.py            # generate if missing, else print the existing one
    python3 scripts/remote-token.py --rotate   # always generate a new one — this immediately revokes
                                                # every session already issued too, not just future
                                                # logins (each session is bound to a fingerprint of the
                                                # token live when it was issued; a rotated/removed token
                                                # fails that check on the session's very next request —
                                                # see server/lib/remote_access.py's `session_is_valid`)
    python3 scripts/remote-token.py --show     # print the current token without changing it
"""
import argparse
import os
import secrets
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import remote_access  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rotate", action="store_true",
                         help="always write a fresh token, even if one exists")
    parser.add_argument("--show", action="store_true",
                         help="print the current token without changing it")
    args = parser.parse_args()

    path = remote_access.TOKEN_PATH
    existing = remote_access.load_token()

    if args.show:
        if not existing:
            print("no token set yet", file=sys.stderr)
            return 1
        print(existing)
        return 0

    if existing and not args.rotate:
        print(f"token already set at {path} (use --rotate to replace it)", file=sys.stderr)
        print(existing)
        return 0

    token = secrets.token_urlsafe(32)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    os.chmod(path, 0o600)
    verb = "Rotated" if existing else "Generated"
    print(f"{verb} remote-access token at {path}:", file=sys.stderr)
    print(token)
    return 0


if __name__ == "__main__":
    sys.exit(main())
