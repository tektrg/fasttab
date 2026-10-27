#!/usr/bin/env python3
"""Account rotation, dashboard side (slice 3 of
.claude/briefs/claude-account-rotation.md).

When a Claude pane shows an account wall (`limitWall`, classify_pane), the
session is resumed IN THE SAME herdr pane on the next `kind: login` account of
`accounts.json` (priority order): stop the stuck Claude, copy the transcript
into the target CLAUDE_CONFIG_DIR, type the resume command.

* Current account = the config dir whose `projects/*/<sessionId>.jsonl` was
  written most recently (default `~/.claude` = account id "default"). The
  process env is not read: `ps eww` only shows the env at exec time and
  misses Claude's own re-execs; the transcript is what the session writes.
* Next account = first `login` row (in order) that is not current and not
  remembered as limited, BEFORE any `needsApproval` row — DeepSeek is never
  reached here; it goes through the router's approval (`/api/accounts`).
* Guards: one auto resume per pane per limit episode, a per-pane cooldown,
  a per-account "limited until" memory, one JSONL log line per attempt.
* `autoResume` (accounts.json top level, default true) gates the automatic
  path; `POST /api/accounts/resume {paneId}` is the manual one.

The router (server/claude_router.py) owns proxy/apikey rows; this module only
reads its `/status` for `GET /api/accounts`.
"""
import json
import os
import shlex
import shutil
import threading
import time
import urllib.error
import urllib.request

import dashboard_config

DEFAULT_ACCOUNT_ID = "default"
DEFAULT_CONFIG_DIR = os.path.expanduser("~/.claude")
#: How long an account stays "limited" after a wall (Claude's 5-hour window).
LIMITED_FOR_SEC = 5 * 3600
#: Minimum gap between two resumes of the same pane (auto or manual).
PANE_COOLDOWN_SEC = 10 * 60
ROUTER_TIMEOUT_SEC = 2
ACCOUNT_CACHE_SEC = 30
#: `env -u` drops proxy settings a parent shell may export; `env` also
#: bypasses the PO's `claude` alias, which forces the Aptus proxy.
RESUME_TEMPLATE = ("env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL "
                   "CLAUDE_CONFIG_DIR={config_dir} claude --resume {session} "
                   "--dangerously-skip-permissions")
PUBLIC_FIELDS = ("id", "label", "kind", "tier", "needsApproval", "configDir",
                 "baseUrl", "model", "enabled")


def accounts_path():
    """Same file the router reads (claude_router.accounts_path)."""
    return os.environ.get("CLAUDE_ROUTER_ACCOUNTS") or os.path.join(
        dashboard_config.CONFIG_HOME, "accounts.json")


def state_dir():
    return os.path.join(dashboard_config.STATE_HOME, "account-rotation")


def router_url():
    return f"http://127.0.0.1:{os.environ.get('CLAUDE_ROUTER_PORT', '4720')}"


def load_accounts_file(path=None):
    """(rows, autoResume). Missing file = no accounts, auto on."""
    try:
        with open(path or accounts_path()) as f:
            data = json.load(f)
    except FileNotFoundError:
        return [], True
    rows = data.get("accounts", []) if isinstance(data, dict) else data
    auto = data.get("autoResume", True) if isinstance(data, dict) else True
    return [r for r in rows if isinstance(r, dict) and r.get("id")], bool(auto)


def config_dir_of(account):
    raw = account.get("configDir")
    return os.path.expanduser(raw) if raw else None


# ── which account a session runs on ──

def find_transcript(session_id, config_dir):
    """(path, mtime) of `<config_dir>/projects/*/<session_id>.jsonl`, or None."""
    if not session_id or "/" in session_id or session_id.startswith("."):
        return None
    base = os.path.join(config_dir, "projects")
    try:
        slugs = os.listdir(base)
    except OSError:
        return None
    best = None
    for slug in slugs:
        path = os.path.join(base, slug, session_id + ".jsonl")
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if best is None or mtime > best[1]:
            best = (path, mtime)
    return best


def candidate_dirs(accounts, default_dir=None):
    """[(account_id, config_dir)]: the default dir plus every login row."""
    out = [(DEFAULT_ACCOUNT_ID, default_dir or DEFAULT_CONFIG_DIR)]
    out += [(a["id"], config_dir_of(a)) for a in accounts
            if a.get("kind") == "login" and config_dir_of(a)]
    return out


def current_account(session_id, accounts, default_dir=None):
    """(account_id, config_dir, transcript_path) of the newest transcript."""
    best = None
    for account_id, config_dir in candidate_dirs(accounts, default_dir):
        hit = find_transcript(session_id, config_dir)
        if hit and (best is None or hit[1] > best[3]):
            best = (account_id, config_dir, hit[0], hit[1])
    return best[:3] if best else None


_account_cache = {}
_cache_lock = threading.Lock()


def account_id_for_session(session_id, now=None):
    """Cached account id for an agent row (None when unknown). Never raises."""
    if not session_id:
        return None
    now = now or time.time()
    with _cache_lock:
        hit = _account_cache.get(session_id)
        if hit and hit[1] > now:
            return hit[0]
    try:
        accounts, _auto = load_accounts_file()
        found = current_account(session_id, accounts)
    except Exception:
        found = None
    account_id = found[0] if found else None
    with _cache_lock:
        _account_cache[session_id] = (account_id, now + ACCOUNT_CACHE_SEC)
    return account_id


# ── choosing the next account ──

def next_login_account(accounts, current_id, limited_until, now):
    """First usable login row after skipping current/limited ones, or
    (None, why). Stops at the first needsApproval row: that tier asks first."""
    for account in accounts:
        if not account.get("enabled", True):
            continue
        if account.get("needsApproval"):
            return None, (f"next account is '{account.get('label', account['id'])}', "
                          "which needs approval — approve it in AgentBar")
        if account.get("kind") != "login" or not config_dir_of(account):
            continue
        if account["id"] == current_id or limited_until.get(account["id"], 0) > now:
            continue
        return account, None
    return None, "no login account left that is not at its limit"


def copy_transcript(transcript_path, target_config_dir):
    """Copy (never move) the transcript and its sibling `<sid>/` dir into the
    same project slug under the target config dir. Returns the new path."""
    slug_dir = os.path.dirname(transcript_path)
    session_file = os.path.basename(transcript_path)
    target_slug_dir = os.path.join(target_config_dir, "projects", os.path.basename(slug_dir))
    os.makedirs(target_slug_dir, exist_ok=True)
    target = os.path.join(target_slug_dir, session_file)
    shutil.copy2(transcript_path, target)
    sibling = transcript_path[:-len(".jsonl")]
    if os.path.isdir(sibling):
        shutil.copytree(sibling, os.path.join(target_slug_dir, os.path.basename(sibling)),
                        dirs_exist_ok=True)
    return target


def resume_command(config_dir, session_id):
    return RESUME_TEMPLATE.format(config_dir=shlex.quote(config_dir),
                                  session=shlex.quote(session_id))


# ── the rotator: guards, memory, log ──

class Rotator:
    """Holds the guard memory. `pane_ops` = {stop, busy, type} callables so
    tests never touch a real pane (defaults: chief_dashboard_actions)."""

    def __init__(self, pane_ops=None, default_dir=None, accounts_file=None,
                 state_path=None, clock=time.time):
        self.pane_ops = pane_ops
        self.default_dir = default_dir
        self.accounts_file = accounts_file
        self.state_path = state_path or state_dir()
        self.clock = clock
        self.lock = threading.Lock()
        self.limited_until = {}
        self.last_resume_at = {}      # paneId -> ts
        self.open_episodes = set()    # paneIds already handled this wall
        self.recent = []              # last few log entries, newest last
        self._load()

    # persistence: the limited-until memory survives a dashboard restart
    def _memory_file(self):
        return os.path.join(self.state_path, "limited-until.json")

    def _load(self):
        try:
            with open(self._memory_file()) as f:
                self.limited_until = {k: float(v) for k, v in json.load(f).items()}
        except (OSError, ValueError, AttributeError):
            self.limited_until = {}

    def _save(self):
        os.makedirs(self.state_path, exist_ok=True)
        with open(self._memory_file(), "w") as f:
            json.dump(self.limited_until, f)

    def log(self, **entry):
        entry = {"ts": round(self.clock(), 3), **entry}
        self.recent = (self.recent + [entry])[-20:]
        print(f"[account-rotation] {json.dumps(entry)}", flush=True)
        try:
            os.makedirs(self.state_path, exist_ok=True)
            with open(os.path.join(self.state_path, "log.jsonl"), "a") as f:
                f.write(json.dumps(entry) + "\n")
        except OSError:
            pass

    def _ops(self):
        if self.pane_ops is not None:
            return self.pane_ops
        import chief_dashboard_actions as actions
        return {"stop": actions.do_stop, "busy": actions.agent_pids_in_pane,
                "type": actions.type_command_in_pane}

    def resume(self, agent_row, trigger="manual"):
        """Move the row's session to the next login account. Raises
        RuntimeError with a human reason on any refusal."""
        with self.lock:
            return self._resume_locked(agent_row or {}, trigger)

    def _resume_locked(self, row, trigger):
        pane_id, session_id = row.get("paneId"), row.get("agentSession")
        now = self.clock()
        try:
            refusal = self._refusal(row, pane_id, session_id, now)
            if refusal:
                raise RuntimeError(refusal)
            accounts, _auto = load_accounts_file(self.accounts_file)
            current = current_account(session_id, accounts, self.default_dir)
            if not current:
                raise RuntimeError(f"no transcript on disk for session {session_id}")
            current_id, _current_dir, transcript = current
            if row.get("limitWall"):
                self.limited_until[current_id] = now + LIMITED_FOR_SEC
                self._save()
            target, why = next_login_account(accounts, current_id, self.limited_until, now)
            if not target:
                raise RuntimeError(why)
            target_dir = config_dir_of(target)
            copied = copy_transcript(transcript, target_dir)
            ops = self._ops()
            if ops["busy"](pane_id):
                ops["stop"](pane_id)
            if ops["busy"](pane_id):
                raise RuntimeError("Claude did not exit in that pane — resume not typed")
            command = resume_command(target_dir, session_id)
            ops["type"](pane_id, command)
        except RuntimeError as e:
            self.log(event="refused", trigger=trigger, paneId=pane_id,
                     session=session_id, reason=str(e))
            raise
        self.last_resume_at[pane_id] = now
        self.open_episodes.add(pane_id)
        _account_cache.pop(session_id, None)
        self.log(event="resumed", trigger=trigger, paneId=pane_id, session=session_id,
                 fromAccount=current_id, toAccount=target["id"], transcript=copied)
        return {"paneId": pane_id, "session": session_id, "fromAccount": current_id,
                "toAccount": target["id"], "command": command}

    def _refusal(self, row, pane_id, session_id, now):
        if not pane_id or row.get("source") != "herdr":
            return "only herdr pane rows can be resumed"
        if row.get("agentKind") != "claude":
            return "only Claude panes can be resumed on another account"
        if row.get("machine", "local") != "local":
            return "resume runs on this Mac only (remote pane)"
        if not session_id:
            return "no session id on this row — cannot resume"
        wait = self.last_resume_at.get(pane_id, 0) + PANE_COOLDOWN_SEC - now
        if wait > 0:
            return f"pane was just resumed — try again in {round(wait / 60) or 1} min"
        return None

    def on_screens(self, agent_rows):
        """Auto path: called with built agent rows after a screen sweep."""
        _accounts, auto = load_accounts_file(self.accounts_file)
        walled = {r.get("paneId") for r in agent_rows if r.get("limitWall")}
        self.open_episodes &= walled  # a cleared wall ends its episode
        if not auto:
            return []
        done = []
        for row in agent_rows:
            pane_id = row.get("paneId")
            if not row.get("limitWall") or pane_id in self.open_episodes:
                continue
            self.open_episodes.add(pane_id)  # once per episode, even on refusal
            try:
                done.append(self.resume(row, trigger="auto"))
            except RuntimeError:
                pass  # already logged
        return done

    def limits_view(self, now=None):
        now = now or self.clock()
        return {k: v for k, v in self.limited_until.items() if v > now}


# ── GET /api/accounts, POST /api/accounts/approve-fallback ──

def _router_request(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(router_url() + path, data=data, method="POST" if data else "GET",
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=ROUTER_TIMEOUT_SEC) as resp:
        return json.loads(resp.read() or b"{}")


def accounts_view(rotator):
    """accounts.json rows (no token fields) + router status + pane memory."""
    try:
        accounts, auto = load_accounts_file(rotator.accounts_file)
        error = None
    except (OSError, ValueError) as e:
        accounts, auto, error = [], True, f"accounts.json unreadable: {e}"
    try:
        router = _router_request("/status")
    except (OSError, ValueError, urllib.error.URLError):
        router = None
    router_rows = {r.get("id"): r for r in (router or {}).get("accounts", [])}
    limits = rotator.limits_view()
    rows = []
    for account in accounts:
        row = {k: account[k] for k in PUBLIC_FIELDS if k in account}
        row.setdefault("needsApproval", False)
        live = router_rows.get(account["id"]) or {}
        row["cooldownUntil"] = live.get("cooldownUntil")
        row["cooldownSecondsLeft"] = live.get("cooldownSecondsLeft", 0)
        row["limitedUntil"] = limits.get(account["id"])
        if account.get("kind") == "login" and config_dir_of(account):
            import account_login  # imports this module; lazy to avoid a cycle
            row["loggedIn"] = account_login.logged_in(config_dir_of(account))
        rows.append(row)
    return {
        "ok": error is None, "error": error, "accounts": rows, "autoResume": auto,
        "routerReachable": router is not None,
        "routerActive": (router or {}).get("active"),
        "lastSwitch": (router or {}).get("lastSwitch"),
        "approvedFallback": (router or {}).get("approvedFallback"),
        "pendingApproval": (router or {}).get("pendingApproval"),
        "recentResumes": rotator.recent[-5:],
    }


def approve_fallback(body):
    account_id = (body or {}).get("id")
    if not isinstance(account_id, str) or not account_id:
        return {"ok": False, "error": "missing id"}
    try:
        return {"ok": True, **_router_request("/approve", {"id": account_id})}
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read() or b"{}").get("error")
        except ValueError:
            detail = None
        return {"ok": False, "error": detail or f"router refused ({e.code})"}
    except (OSError, urllib.error.URLError):
        return {"ok": False, "error": "claude-router is not running"}
