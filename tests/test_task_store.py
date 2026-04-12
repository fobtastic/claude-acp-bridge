from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BIN_DIR = REPO_ROOT / "plugins" / "acp-bridge" / "bin"

import sys

sys.path.insert(0, str(BIN_DIR))

import acp_task_store as tasks


def load_client_module():
    loader = SourceFileLoader("acp_client_for_tests", str(BIN_DIR / "acp-client"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class TaskStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.old_xdg = os.environ.get("XDG_CACHE_HOME")
        os.environ["XDG_CACHE_HOME"] = self.tmp.name

    def tearDown(self) -> None:
        if self.old_xdg is None:
            os.environ.pop("XDG_CACHE_HOME", None)
        else:
            os.environ["XDG_CACHE_HOME"] = self.old_xdg
        self.tmp.cleanup()

    def test_state_predicates(self) -> None:
        self.assertTrue(tasks.is_terminal_state("completed"))
        self.assertTrue(tasks.is_terminal_state("failed"))
        self.assertTrue(tasks.is_interrupted_state("input_required"))
        self.assertTrue(tasks.is_interrupted_state("auth_required"))
        self.assertTrue(tasks.is_active_state("submitted"))
        self.assertTrue(tasks.is_active_state("working"))
        self.assertFalse(tasks.is_active_state("completed"))

    def test_serialization_and_event_ordering(self) -> None:
        task = tasks.new_task(
            task_id="job_abc",
            backend="qwen",
            prompt="do work",
            workspace_root="/repo",
            context_id="ctx",
        )
        with tasks.task_lock("qwen"):
            tasks.append_task_event(task, "task.submitted", {"prompt": "do work"}, timestamp=1)
            tasks.update_task_status(task, "working", "started", timestamp=2, event_type="task.started")
            tasks.save_task(task)

        loaded = tasks.load_task("qwen", "job_abc")
        self.assertIsNotNone(loaded)
        assert loaded is not None
        self.assertEqual(loaded["schemaVersion"], 1)
        self.assertEqual(loaded["status"]["state"], "working")

        events = tasks.load_task_events("qwen", "job_abc")
        self.assertEqual([event["sequence"] for event in events], [1, 2])
        self.assertEqual([event["type"] for event in events], ["task.submitted", "task.started"])

    def test_list_filters_and_sorting(self) -> None:
        older = tasks.new_task(task_id="job_old", backend="qwen", prompt="old", workspace_root="/repo/a", created_at=10)
        newer = tasks.new_task(task_id="job_new", backend="qwen", prompt="new", workspace_root="/repo/b", created_at=20)
        tasks.update_task_status(newer, "completed", "done", timestamp=30, event_type="task.completed")
        with tasks.task_lock("qwen"):
            tasks.save_task(older)
            tasks.save_task(newer)

        active = tasks.list_tasks(backend="qwen", active_only=True)
        self.assertEqual([task["id"] for task in active], ["job_old"])

        completed = tasks.list_tasks(backend="qwen", state="completed")
        self.assertEqual([task["id"] for task in completed], ["job_new"])

        all_tasks = tasks.list_tasks(backend="qwen")
        self.assertEqual([task["id"] for task in all_tasks], ["job_new", "job_old"])

    def test_job_sync_creates_artifacts(self) -> None:
        client = load_client_module()
        job = client.PromptJob(
            job_id="job_result",
            backend="codex",
            prompt="finish",
            workspace_root="/repo",
            status="completed",
            result={"text": "done"},
            completed_at=50,
        )
        client.sync_task_from_job(job, event_type="task.completed", payload={"ok": True})
        loaded = tasks.load_task("codex", "job_result")
        self.assertIsNotNone(loaded)
        assert loaded is not None
        self.assertEqual(loaded["status"]["state"], "completed")
        self.assertIn("final_response", {artifact["id"] for artifact in loaded["artifacts"]})

    def test_get_task_refreshes_from_mocked_backend_response(self) -> None:
        client = load_client_module()

        async def run_case() -> dict:
            async def fake_send(_socket_path: Path, request: dict) -> dict:
                self.assertEqual(request["action"], "get_task")
                return {
                    "schemaVersion": 1,
                    "id": request["taskId"],
                    "backend": "qwen",
                    "contextId": "ctx",
                    "workspaceRoot": "/repo",
                    "status": {"state": "working", "message": "mock refresh", "timestamp": 1},
                    "createdAt": 1,
                    "updatedAt": 2,
                    "completedAt": None,
                    "prompt": "x",
                    "history": [],
                    "artifacts": [],
                    "metadata": {},
                    "eventCount": 0,
                    "lastSequence": 0,
                }

            original = client._send_socket_request
            client._send_socket_request = fake_send
            try:
                return await client.get_task_via_socket(Path("/tmp/mock.sock"), "job_mock")
            finally:
                client._send_socket_request = original

        refreshed = asyncio.run(run_case())
        self.assertEqual(refreshed["status"]["state"], "working")
        self.assertEqual(refreshed["status"]["message"], "mock refresh")


if __name__ == "__main__":
    unittest.main()
