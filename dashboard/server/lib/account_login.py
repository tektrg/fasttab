#!/usr/bin/env python3
"""Log a `kind: login` account (accounts.json) into Claude, from AgentBar.

`POST /api/accounts/login {id}` opens (or reuses) the herdr tab
`claude-login-<id>` and runs `claude /login` there with that row's
CLAUDE_CONFIG_DIR. The PO finishes the browser OAuth in that tab.

`logged_in(config_dir)` feeds `loggedIn` on `GET /api/accounts`. How Claude
Code stores credentials on macOS (checked 2026-10-27, attribute lookups only):
* Keychain generic password, service `Claude Code-credentials` for the
  default `~/.claude`, else `Claude Code-credentials-<first 8 hex of
  sha256(expanded config dir)>`.
* `<config dir>/.credentials.json` (plaintext fallback, Linux style).
Either present = True; neither = False; `security` unusable = None. Presence
only: an expired/revoked token still reads True. Secrets are never read
(`security` runs without -w/-g, output discarded).
"""
import hashlib
import os
import shlex
import shutil
import subprocess

import account_rotation

LOGIN_TAB_PREFIX = "claude-login-"
DEFAULT_KEYCHAIN_SERVICE = "Claude Code-credentials"
KEYCHAIN_ITEM_NOT_FOUND = 44  # `security` exit code
SHELL_READY_TIMEOUT_MS = 16000
#: `env -u` drops proxy settings a parent shell may export; `env` + an
#: absolute binary path bypasses the PO's `claude` alias (forces a proxy).
LOGIN_TEMPLATE = ("env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL "
                  "CLAUDE_CONFIG_DIR={config_dir} {claude} /login")


def claude_binary():
    return (os.environ.get("ACCOUNT_LOGIN_CLAUDE_BIN") or shutil.which("claude")
            or os.path.expanduser("~/.local/bin/claude"))


def login_command(config_dir, claude_bin=None):
    return LOGIN_TEMPLATE.format(config_dir=shlex.quote(config_dir),
                                 claude=shlex.quote(claude_bin or claude_binary()))


def keychain_service(config_dir):
    path = os.path.normpath(os.path.expanduser(config_dir))
    if path == account_rotation.DEFAULT_CONFIG_DIR:
        return DEFAULT_KEYCHAIN_SERVICE
    return f"{DEFAULT_KEYCHAIN_SERVICE}-{hashlib.sha256(path.encode()).hexdigest()[:8]}"


def logged_in(config_dir, run=subprocess.run):
    """True / False / None (unknown). See module docstring."""
    if os.path.isfile(os.path.join(config_dir, ".credentials.json")):
        return True
    try:
        proc = run(["security", "find-generic-password", "-s", keychain_service(config_dir)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode == 0:
        return True
    return False if proc.returncode == KEYCHAIN_ITEM_NOT_FOUND else None


class HerdrLoginOps:
    """The herdr calls a login makes (local machine). Tests pass a fake."""

    def _call(self, argv, timeout=15, parse=True):
        import chief_dashboard_herdr as herdr
        from chief_dashboard_feeds import REPO_ROOT, MACHINES
        fn = herdr.herdr_cmd_json if parse else herdr.herdr_cmd_text
        return fn(herdr.LOCAL_MACHINE, argv, repo_root=REPO_ROOT, machines=MACHINES,
                  timeout=timeout)

    def _json(self, argv):
        return self._call(argv)

    def find_tab(self, label):
        """(tab_id, pane_id) of the first tab labelled `label`, or None."""
        from herdr_pane_lookup import pane_rows_for_label
        panes = pane_rows_for_label(self._json(["tab", "list"]), self._json(["pane", "list"]), label)
        return (panes[0].get("tab_id"), panes[0].get("pane_id")) if panes else None

    def create_tab(self, label):
        data = self._json(["tab", "create", "--cwd", os.path.expanduser("~"),
                           "--label", label, "--no-focus"])
        result = (data.get("result") if isinstance(data, dict) else None) or {}
        pane = result.get("root_pane") or {}
        if not pane.get("pane_id"):
            raise RuntimeError(f"herdr tab create returned no pane id: {data!r}")
        return (result.get("tab") or {}).get("tab_id") or pane.get("tab_id"), pane["pane_id"]

    def wait_ready(self, pane_id):
        self._call(["pane", "wait-output", pane_id, "--regex", r"\S", "--source", "visible",
                    "--timeout", str(SHELL_READY_TIMEOUT_MS)],
                   timeout=SHELL_READY_TIMEOUT_MS // 1000 + 2, parse=False)

    def busy(self, pane_id):
        import chief_dashboard_actions
        return bool(chief_dashboard_actions.agent_pids_in_pane(pane_id))

    def run(self, pane_id, command):
        self._call(["pane", "run", pane_id, command], parse=False)


def start_login(body, ops=None, accounts_file=None):
    """POST /api/accounts/login {id} -> {ok, tab, pane, reused} | {ok:false, error}."""
    account_id = (body or {}).get("id")
    if not isinstance(account_id, str) or not account_id:
        return {"ok": False, "error": "missing id"}
    try:
        accounts, _auto = account_rotation.load_accounts_file(accounts_file)
    except (OSError, ValueError) as e:
        return {"ok": False, "error": f"accounts.json unreadable: {e}"}
    account = next((a for a in accounts if a["id"] == account_id), None)
    if account is None:
        return {"ok": False, "error": f"unknown account {account_id!r}"}
    config_dir = account_rotation.config_dir_of(account)
    if account.get("kind") != "login" or not config_dir:
        return {"ok": False, "error": f"'{account_id}' is not a login account with a configDir"}
    ops = ops or HerdrLoginOps()
    label = LOGIN_TAB_PREFIX + account_id
    try:
        found = ops.find_tab(label)
        tab_id, pane_id = found or ops.create_tab(label)
        if found and ops.busy(pane_id):
            return {"ok": True, "tab": tab_id, "pane": pane_id, "reused": True,
                    "note": "login already running in that tab"}
        if not found:
            ops.wait_ready(pane_id)
        ops.run(pane_id, login_command(config_dir))
    except (RuntimeError, OSError) as e:  # HerdrError is a RuntimeError
        return {"ok": False, "error": f"herdr: {e}"}
    return {"ok": True, "tab": tab_id, "pane": pane_id, "reused": bool(found)}
