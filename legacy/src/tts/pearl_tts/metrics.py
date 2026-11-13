"""Append-only JSONL metrics for TTS latency accounting.

Metrics are the only way to keep a <400 ms promise honest.  Every synthesis
request records: text size, backend, voice, cold/warm state, synthesis time,
audio duration and real-time factor.  The client records the end-to-end
numbers (text -> first audio frame -> first sample on device).
"""

from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path
from typing import Any

__all__ = ["MetricWriter", "now_ms"]

_lock = threading.Lock()


def now_ms() -> float:
    return time.monotonic() * 1000.0


class MetricWriter:
    def __init__(self, path: str | Path | None) -> None:
        self.path = Path(os.path.expanduser(str(path))) if path else None
        if self.path:
            try:
                self.path.parent.mkdir(parents=True, exist_ok=True)
            except OSError:
                self.path = None

    def write(self, event: str, **fields: Any) -> None:
        if not self.path:
            return
        record = {"ts": time.time(), "event": event, **fields}
        line = json.dumps(record, separators=(",", ":"), ensure_ascii=False)
        try:
            with _lock:
                with self.path.open("a", encoding="utf-8") as handle:
                    handle.write(line + "\n")
        except OSError:
            # Metrics must never take down speech.
            pass
