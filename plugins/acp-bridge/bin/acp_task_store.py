"""Persistent task model for claude-acp-bridge.

The bridge still executes work through ACP PromptJob instances. This module
provides an A2A-inspired task lifecycle wrapper around those jobs so command
handlers, watchers, and future facades can share one durable vocabulary.
"""

from __future__ import annotations

import json
import os
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Optional

try:
    import fcntl
except ImportError:  # pragma: no cover - Unix sockets already require Unix here.
    fcntl = None  # type: ignore[assignment]

SCHEMA_VERSION = 1

TASK_STATES = {
    "submitted",
    "working",
    "input_required",
    "auth_required",
    "completed",
    "failed",
    "canceled",
    "rejected",
    "unknown",
}
TERMINAL_STATES = {"completed", "failed", "canceled", "rejected"}
INTERRUPTED_STATES = {"input_required", "auth_required"}
ACTIVE_STATES = {"submitted", "working", "input_required", "auth_required"}

TASK_EVENT_TYPES = {
    "task.submitted",
    "task.started",
    "task.status_changed",
    "task.message",
    "task.artifact_created",
    "task.artifact_updated",
    "task.permission_requested",
    "task.permission_resolved",
    "task.completed",
    "task.failed",
    "task.canceled",
    "task.cancel_failed",
    "task.notification_queued",
    "task.notification_sent",
}


def now_ts() -> float:
    return time.time()


def is_terminal_state(state: str) -> bool:
    return state in TERMINAL_STATES


def is_interrupted_state(state: str) -> bool:
    return state in INTERRUPTED_STATES


def is_active_state(state: str) -> bool:
    return state in ACTIVE_STATES


def cache_root() -> Path:
    return Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "claude-acp-bridge"


def task_root() -> Path:
    return cache_root() / "tasks"


def tasks_dir(backend: str) -> Path:
    return task_root() / backend


def task_path(backend: str, task_id: str) -> Path:
    return tasks_dir(backend) / f"{task_id}.json"


def task_events_path(backend: str, task_id: str) -> Path:
    return tasks_dir(backend) / f"{task_id}.events.jsonl"


def lock_path(backend: str) -> Path:
    return tasks_dir(backend) / ".lock"


def ensure_private_tree(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def ensure_private_file(path: Path) -> None:
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


@contextmanager
def task_lock(backend: str) -> Iterator[None]:
    ensure_private_tree(tasks_dir(backend))
    path = lock_path(backend)
    with path.open("a+", encoding="utf-8") as lock_file:
        ensure_private_file(path)
        if fcntl is not None:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            if fcntl is not None:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def normalize_task_state(state: Any) -> str:
    text = str(state or "unknown").lower()
    mapping = {
        "queued": "submitted",
        "running": "working",
        "started": "working",
        "succeeded": "completed",
        "done": "completed",
        "error": "failed",
        "interrupted": "failed",
        "cancelled": "canceled",
        "cancel_requested": "working",
        "not_cancelable": "working",
    }
    text = mapping.get(text, text)
    return text if text in TASK_STATES else "unknown"


def status_message_for_state(state: str, error: Optional[str] = None) -> str:
    if error:
        return error
    messages = {
        "submitted": "Task accepted by bridge",
        "working": "Backend is processing",
        "input_required": "Backend needs user input or permission approval",
        "auth_required": "Backend needs authentication",
        "completed": "Task completed",
        "failed": "Task failed",
        "canceled": "Task canceled",
        "rejected": "Task rejected",
        "unknown": "Task state could not be determined",
    }
    return messages.get(state, messages["unknown"])


def new_status(state: str, message: Optional[str] = None, timestamp: Optional[float] = None) -> dict[str, Any]:
    normalized = normalize_task_state(state)
    ts = now_ts() if timestamp is None else float(timestamp)
    return {
        "state": normalized,
        "message": message or status_message_for_state(normalized),
        "timestamp": ts,
    }


def new_task(
    *,
    task_id: str,
    backend: str,
    prompt: str,
    workspace_root: str,
    context_id: Optional[str] = None,
    status: str = "submitted",
    created_at: Optional[float] = None,
    metadata: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    ts = now_ts() if created_at is None else float(created_at)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "id": task_id,
        "backend": backend,
        "contextId": context_id,
        "workspaceRoot": workspace_root,
        "status": new_status(status, timestamp=ts),
        "createdAt": ts,
        "updatedAt": ts,
        "completedAt": None,
        "prompt": prompt,
        "history": [],
        "artifacts": [],
        "metadata": metadata or {},
        "eventCount": 0,
        "lastSequence": 0,
    }


def load_task(backend: str, task_id: str) -> Optional[dict[str, Any]]:
    path = task_path(backend, task_id)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def save_task(task: dict[str, Any]) -> None:
    backend = str(task["backend"])
    ensure_private_tree(tasks_dir(backend))
    path = task_path(backend, str(task["id"]))
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(task, indent=2, sort_keys=True, ensure_ascii=False), encoding="utf-8")
    ensure_private_file(tmp)
    tmp.replace(path)
    ensure_private_file(path)


def _read_last_sequence(backend: str, task_id: str) -> int:
    path = task_events_path(backend, task_id)
    last = 0
    try:
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                try:
                    event = json.loads(line)
                    last = max(last, int(event.get("sequence") or 0))
                except Exception:
                    continue
    except FileNotFoundError:
        pass
    return last


def append_task_event(
    task: dict[str, Any],
    event_type: str,
    payload: Optional[dict[str, Any]] = None,
    *,
    timestamp: Optional[float] = None,
) -> dict[str, Any]:
    backend = str(task["backend"])
    task_id = str(task["id"])
    ensure_private_tree(tasks_dir(backend))
    ts = now_ts() if timestamp is None else float(timestamp)
    sequence = max(int(task.get("lastSequence") or 0), _read_last_sequence(backend, task_id)) + 1
    event = {
        "eventId": f"evt_{uuid.uuid4().hex}",
        "taskId": task_id,
        "backend": backend,
        "timestamp": ts,
        "type": event_type if event_type in TASK_EVENT_TYPES else event_type,
        "sequence": sequence,
        "payload": payload or {},
    }
    path = task_events_path(backend, task_id)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")
    ensure_private_file(path)
    task["lastSequence"] = sequence
    task["eventCount"] = int(task.get("eventCount") or 0) + 1
    task["updatedAt"] = max(float(task.get("updatedAt") or 0), ts)
    return event


def load_task_events(backend: str, task_id: str, *, offset: int = 0, limit: int = 500) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    path = task_events_path(backend, task_id)
    try:
        with path.open("r", encoding="utf-8") as f:
            for index, line in enumerate(f):
                if index < offset:
                    continue
                if len(events) >= limit:
                    break
                try:
                    item = json.loads(line)
                    if isinstance(item, dict):
                        events.append(item)
                except Exception:
                    continue
    except FileNotFoundError:
        pass
    return events


def update_task_status(
    task: dict[str, Any],
    state: str,
    message: Optional[str] = None,
    *,
    timestamp: Optional[float] = None,
    event_type: Optional[str] = None,
    payload: Optional[dict[str, Any]] = None,
) -> Optional[dict[str, Any]]:
    ts = now_ts() if timestamp is None else float(timestamp)
    normalized = normalize_task_state(state)
    old_state = str((task.get("status") or {}).get("state") or "unknown")
    old_message = str((task.get("status") or {}).get("message") or "")
    new_message = message or status_message_for_state(normalized)
    changed = old_state != normalized or old_message != new_message
    task["status"] = {"state": normalized, "message": new_message, "timestamp": ts}
    task["updatedAt"] = ts
    if is_terminal_state(normalized) and not task.get("completedAt"):
        task["completedAt"] = ts
    if changed or event_type:
        return append_task_event(
            task,
            event_type or "task.status_changed",
            {
                "from": old_state,
                "to": normalized,
                "message": new_message,
                **(payload or {}),
            },
            timestamp=ts,
        )
    return None


def upsert_artifact(task: dict[str, Any], artifact: dict[str, Any]) -> tuple[dict[str, Any], bool, bool]:
    artifacts = task.setdefault("artifacts", [])
    artifact_id = str(artifact.get("id") or f"artifact_{uuid.uuid4().hex[:12]}")
    ts = now_ts()
    normalized = {
        "id": artifact_id,
        "type": artifact.get("type") or "output",
        "title": artifact.get("title") or artifact_id,
        "createdAt": artifact.get("createdAt") or ts,
        "updatedAt": ts,
        **{k: v for k, v in artifact.items() if k not in {"id", "type", "title", "createdAt", "updatedAt"}},
    }
    for index, existing in enumerate(artifacts):
        if existing.get("id") == artifact_id:
            normalized["createdAt"] = existing.get("createdAt") or normalized["createdAt"]
            comparable_existing = {k: v for k, v in existing.items() if k != "updatedAt"}
            comparable_new = {k: v for k, v in normalized.items() if k != "updatedAt"}
            if comparable_existing == comparable_new:
                return existing, False, False
            artifacts[index] = normalized
            task["updatedAt"] = ts
            return normalized, False, True
    artifacts.append(normalized)
    task["updatedAt"] = ts
    return normalized, True, True


def append_history(task: dict[str, Any], role: str, message: str, *, timestamp: Optional[float] = None) -> None:
    if not message:
        return
    history = task.setdefault("history", [])
    history.append(
        {
            "role": role,
            "message": message,
            "timestamp": now_ts() if timestamp is None else float(timestamp),
        }
    )
    if len(history) > 100:
        del history[:-100]


def list_tasks(
    *,
    backend: Optional[str] = None,
    context_id: Optional[str] = None,
    session_id: Optional[str] = None,
    state: Optional[str] = None,
    active_only: bool = False,
    updated_after: Optional[float] = None,
    limit: Optional[int] = None,
) -> list[dict[str, Any]]:
    root = task_root()
    if not root.exists():
        return []
    backends = [backend] if backend else [p.name for p in root.iterdir() if p.is_dir()]
    result: list[dict[str, Any]] = []
    for b in backends:
        directory = tasks_dir(b)
        if not directory.exists():
            continue
        for path in directory.glob("*.json"):
            if path.name.endswith(".events.jsonl"):
                continue
            try:
                task = json.loads(path.read_text(encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(task, dict):
                continue
            task_state = str((task.get("status") or {}).get("state") or "unknown")
            metadata = task.get("metadata") if isinstance(task.get("metadata"), dict) else {}
            if context_id and task.get("contextId") != context_id:
                continue
            if session_id and metadata.get("sessionId") != session_id:
                continue
            if state and task_state != normalize_task_state(state):
                continue
            if active_only and not is_active_state(task_state):
                continue
            if updated_after is not None and float(task.get("updatedAt") or 0) <= float(updated_after):
                continue
            result.append(task)
    result.sort(key=lambda item: float(item.get("updatedAt") or 0), reverse=True)
    return result[:limit] if limit is not None else result


def compact_task(task: dict[str, Any], *, include_artifacts: bool = True, history_limit: Optional[int] = None) -> dict[str, Any]:
    data = dict(task)
    if not include_artifacts:
        data["artifacts"] = []
    if history_limit is not None:
        history = list(data.get("history") or [])
        data["history"] = history[-history_limit:]
    return data
