#!/usr/bin/env python3
"""Tests for Antigravity hook script, hooks.json installer, and dashboard feed."""
import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO_ROOT, "dashboard", "server", "lib"))

import antigravity_hold_store  # noqa: E402
import antigravity_sessions  # noqa: E402


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hook_mod = _load_module(
    "antigravity_status_hook",
    os.path.join(REPO_ROOT, "dashboard", "integrations", "antigravity", "antigravity-status-hook.py"),
)
install_mod = _load_module(
    "antigravity_install_hooks",
    os.path.join(REPO_ROOT, "dashboard", "integrations", "antigravity", "install-hooks.py"),
)


class AntigravityIntegrationTests(unittest.TestCase):
    def test_hook_lifecycle_and_dashboard_row_mapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = os.path.join(tmp, "transcript.jsonl")
            with open(transcript, "w", encoding="utf-8") as f:
                f.write(json.dumps({"type": "PLANNER_RESPONSE", "content": "All tests pass!"}) + "\n")

            base_payload = {
                "conversationId": "conv-1",
                "workspacePaths": ["/Users/me/01_Project/demo-repo"],
                "transcriptPath": transcript,
                "modelName": "gemini-4",
                "lastUserInput": "Fix the login bug",
            }
            now_ms = int(time.time() * 1000)

            # 1. SessionStart -> working
            resp = hook_mod.handle_hook("SessionStart", base_payload, state_dir=tmp, now_ms=now_ms)
            self.assertEqual(resp, {})
            sessions = antigravity_sessions.read_live_sessions(sessions_dir=tmp, now=now_ms / 1000.0 + 5)
            self.assertEqual(len(sessions), 1)
            rows = antigravity_sessions.build_status_only_rows(sessions, set(), now_ms / 1000.0 + 5, "local")
            self.assertEqual(rows[0]["source"], "antigravity")
            self.assertEqual(rows[0]["hookState"], "working")
            self.assertEqual(rows[0]["label"], "Fix the login bug")

            # 2. PreToolUse ask_question (JSON-encoded string, as Antigravity emits) -> blocked with transcriptQuestion
            q_payload = dict(base_payload, toolCall={
                "name": "ask_question",
                "args": {"questions": json.dumps([{"question": "Use SQLite or Postgres?"}])},
            })
            resp = hook_mod.handle_hook("PreToolUse", q_payload, state_dir=tmp, now_ms=now_ms + 10000, enable_bridge=False)
            self.assertEqual(resp, {"decision": "allow"})
            sessions = antigravity_sessions.read_live_sessions(sessions_dir=tmp, now=now_ms / 1000.0 + 12)
            rows = antigravity_sessions.build_status_only_rows(sessions, set(), now_ms / 1000.0 + 12, "local")
            self.assertEqual(rows[0]["hookState"], "blocked")
            self.assertEqual(rows[0]["transcriptQuestion"]["question"], "Use SQLite or Postgres?")

            # 3. Stop (fullyIdle: false) -> stays working
            resp = hook_mod.handle_hook("Stop", dict(base_payload, fullyIdle=False), state_dir=tmp, now_ms=now_ms + 20000)
            self.assertEqual(resp, {"decision": ""})
            sessions = antigravity_sessions.read_live_sessions(sessions_dir=tmp, now=now_ms / 1000.0 + 21)
            self.assertEqual(sessions[0]["status"], "busy")

            # 4. Stop (fullyIdle: true) -> idle with transcript recap
            hook_mod.handle_hook("Stop", dict(base_payload, fullyIdle=True), state_dir=tmp, now_ms=now_ms + 30000)
            sessions = antigravity_sessions.read_live_sessions(sessions_dir=tmp, now=now_ms / 1000.0 + 35)
            rows = antigravity_sessions.build_status_only_rows(sessions, set(), now_ms / 1000.0 + 35, "local")
            self.assertEqual(rows[0]["hookState"], "idle")
            self.assertEqual(rows[0]["screenSignal"], "All tests pass!")

    def test_install_hooks_preserves_existing_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            hooks_path = os.path.join(tmp, "hooks.json")
            with open(hooks_path, "w", encoding="utf-8") as f:
                json.dump({"my-custom-hook": {"enabled": True}}, f)

            install_mod.install(hooks_path=hooks_path, script_path="/tmp/hook.py")
            with open(hooks_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            self.assertIn("my-custom-hook", data)
            self.assertIn("agentbar-status", data)
            self.assertEqual(data["agentbar-status"]["enabled"], True)
            self.assertEqual(data["agentbar-status"]["PreToolUse"][0]["hooks"][0]["timeout"], 360)
            self.assertIn("--event Stop", data["agentbar-status"]["Stop"][0]["command"])

    def test_antigravity_hold_store_and_bridge_decision_mapping(self):
        class AlwaysConnected:
            def is_connected(self): return True
            def is_gone(self): return False

        store = antigravity_hold_store.AntigravityHoldStore(presence=AlwaysConnected())
        q_payload = {
            "conversationId": "conv-bridge",
            "toolCall": {
                "name": "ask_question",
                "args": {
                    "questions": json.dumps([
                        {
                            "question": "Pick database",
                            "options": ["SQLite", "Postgres"],
                            "is_multi_select": False,
                        }
                    ])
                },
            },
        }
        bridge_body = hook_mod._build_bridge_payload(q_payload)
        self.assertEqual(bridge_body["agentTool"], "antigravity")
        self.assertEqual(bridge_body["tool_name"], "AskUserQuestion")
        self.assertEqual(bridge_body["tool_input"]["questions"][0]["options"][0]["label"], "SQLite")

        reg = store.register(bridge_body)
        req_id = reg.get("requestId")
        self.assertTrue(req_id and req_id.startswith("ag"))

        exposed = store.exposed_by_session()
        self.assertIn("conv-bridge", exposed)
        self.assertEqual(exposed["conv-bridge"]["kind"], "question")

        # Answer from AgentBar
        ans_reply, status = store.answer(req_id, {
            "behavior": "allow",
            "answers": {"Pick database": "Postgres"},
        })
        self.assertEqual(status, 200)
        self.assertEqual(ans_reply["state"], "answered")

        wait_reply, wait_status = store.wait(req_id, 1, lambda: [])
        self.assertEqual(wait_status, 200)
        self.assertEqual(wait_reply["state"], "answered")

        ag_resp = hook_mod.decision_to_antigravity_response("ask_question", wait_reply["decision"])
        self.assertEqual(ag_resp["decision"], "deny")
        self.assertIn('"Pick database" = "Postgres"', ag_resp["reason"])

        # Permission approve -> auto_approve
        perm_resp = hook_mod.decision_to_antigravity_response("ask_permission", {"behavior": "allow"})
        self.assertEqual(perm_resp, {"decision": "auto_approve"})
        deny_resp = hook_mod.decision_to_antigravity_response(
            "ask_permission", {"behavior": "deny", "message": "No thanks"}
        )
        self.assertEqual(deny_resp, {"decision": "deny", "reason": "No thanks"})


if __name__ == "__main__":
    unittest.main()
