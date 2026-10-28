#!/usr/bin/env python3
"""Start a NEW `claude` session on the top available account of accounts.json.

Order = the order in AgentBar Settings › Accounts (drag to change). Walking
rows top-down, skip: `enabled: false`; login rows remembered as limited
(account-rotation `limited-until.json`) or not logged in; proxy/apikey rows
claude-router reports cooling down (router unreachable = all healthy).
At a `needsApproval` row it stops and goes through the router, so the
router's approval prompt applies (DeepSeek never starts unasked).

* login pick  -> exec claude, CLAUDE_CONFIG_DIR=<dir>, ANTHROPIC_BASE_URL /
  _AUTH_TOKEN / _MODEL removed.
* proxy/apikey pick or approval stop -> exec claude with ANTHROPIC_BASE_URL =
  the router, ANTHROPIC_AUTH_TOKEN=router.
* nothing usable -> plain claude on the default ~/.claude.
* `--account <name>` -> pin this session to one account of the CLIProxyAPI
  pool (its `prefix`: trung, 7lab, aptus). Goes through the router with
  model `<name>/<model>` (`--model` if given, else PINNED_DEFAULT_MODEL); the
  pool only uses that account, so a pinned session stops at its limit
  instead of moving on.
All other argv pass through. Stdlib only; one localhost GET.
Usage: `claude-launch.py [claude args...]` (alias `ccproxy` to it;
CLAUDE_BIN overrides the real binary).
"""
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server", "lib"))
import account_login  # noqa: E402  (logged_in: Keychain/credentials presence)
import account_rotation  # noqa: E402  (accounts path, limited-until store)

PROXY_KINDS = ("proxy", "apikey")
ROUTER_TIMEOUT_SEC = 0.3
ANTHROPIC_VARS = ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL",
                  "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL")
PINNED_DEFAULT_MODEL = "claude-opus-5-5"
PINNED_SMALL_MODEL = "claude-haiku-5-5"


def take_option(argv, name):
    """(value, argv without it) for `name X` / `name=X`; (None, argv) if absent."""
    rest, value, i = [], None, 0
    while i < len(argv):
        arg = argv[i]
        if arg == name and i + 1 < len(argv):
            value, i = argv[i + 1], i + 2
            continue
        if arg.startswith(name + "="):
            value = arg.split("=", 1)[1]
        else:
            rest.append(arg)
        i += 1
    return value, rest


def pinned_env(account, model, env, router_port):
    """Env for `--account`: router + `<account>/<model>` (pool prefix)."""
    env = launch_env("router", None, env, router_port)
    env["ANTHROPIC_MODEL"] = f"{account}/{model or PINNED_DEFAULT_MODEL}"
    env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = env["ANTHROPIC_SMALL_FAST_MODEL"] = \
        f"{account}/{PINNED_SMALL_MODEL}"
    return env


def choose(accounts, now, status, logged_in, limited_until=None):
    """Pure pick. -> ("login", row) | ("router", row) | ("default", None).

    status: router /status dict or None (down). logged_in: callable(dir) ->
    True/False/None (None = unknown, treated as usable)."""
    limited_until = limited_until or {}
    cooling = {a.get("id") for a in (status or {}).get("accounts", [])
               if (a.get("cooldownUntil") or 0) > now}
    for row in accounts:
        if not row.get("enabled", True):
            continue
        if row.get("needsApproval"):
            return "router", row
        kind = row.get("kind")
        if kind == "login":
            config_dir = account_rotation.config_dir_of(row)
            if (not config_dir or limited_until.get(row["id"], 0) > now
                    or logged_in(config_dir) is False):
                continue
            return "login", row
        if kind in PROXY_KINDS and row.get("baseUrl") and row["id"] not in cooling:
            return "router", row
    return "default", None


def launch_env(pick, row, env, router_port):
    env = {k: v for k, v in env.items() if k not in ANTHROPIC_VARS}
    if pick == "login":
        env["CLAUDE_CONFIG_DIR"] = account_rotation.config_dir_of(row)
    elif pick == "router":
        env.pop("CLAUDE_CONFIG_DIR", None)
        env["ANTHROPIC_BASE_URL"] = f"http://127.0.0.1:{router_port}"
        env["ANTHROPIC_AUTH_TOKEN"] = "router"
    return env


def label_of(pick, row):
    if row is None:
        return "default (~/.claude)"
    name = row.get("label") or row["id"]
    return f"{name} (via router, asks first)" if row.get("needsApproval") else name


def claude_binary(env):
    if env.get("CLAUDE_BIN"):
        return env["CLAUDE_BIN"]
    me = os.path.realpath(__file__)
    for d in env.get("PATH", "").split(os.pathsep):
        cand = os.path.join(d, "claude")
        if os.access(cand, os.X_OK) and os.path.realpath(cand) != me:
            return cand
    return os.path.expanduser("~/.local/bin/claude")


def router_status(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/status",
                                    timeout=ROUTER_TIMEOUT_SEC) as resp:
            return json.load(resp)
    except (OSError, ValueError):
        return None


def limited_until_store():
    try:
        with open(os.path.join(account_rotation.state_dir(), "limited-until.json")) as f:
            return {k: float(v) for k, v in json.load(f).items()}
    except (OSError, ValueError, AttributeError):
        return {}


def main(argv):
    account, argv = take_option(argv, "--account")
    port = os.environ.get("CLAUDE_ROUTER_PORT", "4720")
    if account:
        model, argv = take_option(argv, "--model")
        env = pinned_env(account, model, dict(os.environ), port)
        binary = claude_binary(env)
        print(f"claude → pool account '{account}' (pinned, {env['ANTHROPIC_MODEL']})", file=sys.stderr)
        os.execvpe(binary, [binary] + argv, env)
    try:
        accounts, _auto = account_rotation.load_accounts_file()
    except (OSError, ValueError):
        accounts = []
    needs_router = any(a.get("kind") in PROXY_KINDS for a in accounts)
    status = router_status(port) if needs_router else None
    pick, row = choose(accounts, time.time(), status, account_login.logged_in,
                       limited_until_store())
    env = launch_env(pick, row, dict(os.environ), port)
    binary = claude_binary(env)
    print(f"claude → {label_of(pick, row)}", file=sys.stderr)
    os.execvpe(binary, [binary] + argv, env)


if __name__ == "__main__":
    main(sys.argv[1:])
