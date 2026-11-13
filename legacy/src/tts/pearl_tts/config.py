"""Configuration for the Pearl streaming TTS stack.

Resolution order (lowest to highest precedence):

1. built-in defaults
2. ``config/tts.json`` in the repository (installed as ``~/.pearl/tts.json``)
3. ``~/.pearl/tts.json`` (user overrides)
4. ``PEARL_TTS_*`` environment variables

Everything is plain JSON so the Swift app, the server and the CLI can read the
same settings without a dependency on Python.
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, fields
from pathlib import Path
from typing import Any

__all__ = ["Settings", "load_settings", "settings_to_json"]

_MODEL_DIR = "~/Library/Application Support/Pearl/Models"
_STATE_DIR = "~/.pearl"


@dataclass
class Settings:
    # Backend selection: auto | kokoro | piper | say
    backend: str = "auto"
    # onnxruntime execution provider: cpu | coreml | auto (empty = cpu)
    provider: str = "cpu"
    # CoreML compute units when provider == coreml: all | cpu_and_gpu |
    # cpu_and_ne | cpu_only.  cpu_and_ne is the only way to request the ANE.
    coreml_units: str = "cpu_and_ne"
    voice: str = "bf_emma"
    speed: float = 1.0
    lang: str = "en-us"

    model_dir: str = _MODEL_DIR
    kokoro_model: str = ""
    kokoro_voices: str = ""
    intra_op_threads: int = 4
    piper_bin: str = "piper"
    piper_model: str = ""
    piper_config: str = ""
    say_voice: str = "Samantha"
    say_rate: int = 180

    socket_path: str = f"{_STATE_DIR}/run/tts.sock"
    pid_file: str = f"{_STATE_DIR}/run/tts.pid"
    log_file: str = f"{_STATE_DIR}/logs/tts-engine.log"
    metrics_file: str = f"{_STATE_DIR}/metrics/tts.jsonl"
    idle_timeout: float = 300.0
    max_text_chars: int = 1200
    audio_frame_bytes: int = 9600     # 200 ms of 24 kHz s16le mono
    request_timeout: float = 120.0

    # Chunker tuning (passed through to ChunkerConfig)
    sentence_min_chars: int = 2
    clause_min_chars: int = 28
    first_clause_min_chars: int = 16
    max_chars: int = 220
    code_policy: str = "skip"

    # Playback / integration
    state_file: str = f"{_STATE_DIR}/run/audio-state.json"
    save_audio: str = ""
    no_play: bool = False
    # Cached opening phrase. Speaking it immediately masks the model's
    # first-token latency without waiting for the real answer.
    ack_text: str = "Sure, User."
    prewarm_acks: bool = True

    def resolved_model_dir(self) -> Path:
        return Path(os.path.expanduser(os.path.expandvars(self.model_dir)))

    def resolved_socket(self) -> Path:
        return Path(os.path.expanduser(os.path.expandvars(self.socket_path)))

    def resolved_metrics(self) -> Path:
        return Path(os.path.expanduser(os.path.expandvars(self.metrics_file)))

    def resolved_log(self) -> Path:
        return Path(os.path.expanduser(os.path.expandvars(self.log_file)))

    def resolved_kokoro_model(self) -> Path:
        if self.kokoro_model:
            return Path(os.path.expanduser(os.path.expandvars(self.kokoro_model)))
        # Prefer the dynamically-quantized INT8 export: on Apple Silicon CPU it
        # is ~3x faster than fp32 at conversational quality, which is the
        # difference between a 350 ms and a 900 ms first word.
        base = self.resolved_model_dir()
        for name in ("kokoro-v1.0.int8.onnx", "kokoro-v1.0.fp16.onnx", "kokoro-v1.0.onnx"):
            candidate = base / name
            if candidate.is_file():
                return candidate
        return base / "kokoro-v1.0.int8.onnx"

    def resolved_kokoro_voices(self) -> Path:
        if self.kokoro_voices:
            return Path(os.path.expanduser(os.path.expandvars(self.kokoro_voices)))
        return self.resolved_model_dir() / "voices-v1.0.bin"


_ENV_MAP: dict[str, tuple[str, type]] = {
    "PEARL_TTS_BACKEND": ("backend", str),
    "PEARL_TTS_PROVIDER": ("provider", str),
    "PEARL_TTS_COREML_UNITS": ("coreml_units", str),
    "PEARL_TTS_VOICE": ("voice", str),
    "PEARL_TTS_SPEED": ("speed", float),
    "PEARL_TTS_LANG": ("lang", str),
    "PEARL_TTS_MODEL_DIR": ("model_dir", str),
    "PEARL_KOKORO_MODEL": ("kokoro_model", str),
    "PEARL_KOKORO_VOICES": ("kokoro_voices", str),
    "PEARL_TTS_THREADS": ("intra_op_threads", int),
    "PEARL_PIPER_BIN": ("piper_bin", str),
    "PEARL_PIPER_MODEL": ("piper_model", str),
    "PEARL_PIPER_CONFIG": ("piper_config", str),
    "PEARL_SAY_VOICE": ("say_voice", str),
    "PEARL_SAY_RATE": ("say_rate", int),
    "PEARL_TTS_SOCKET": ("socket_path", str),
    "PEARL_TTS_IDLE_TIMEOUT": ("idle_timeout", float),
    "PEARL_TTS_METRICS": ("metrics_file", str),
    "PEARL_TTS_STATE_FILE": ("state_file", str),
    "PEARL_TTS_NO_PLAY": ("no_play", "bool"),
    "PEARL_TTS_ACK": ("ack_text", str),
    "PEARL_TTS_PREWARM_ACKS": ("prewarm_acks", "bool"),
}


def _coerce(value: Any, kind: type | str) -> Any:
    if kind == "bool":
        if isinstance(value, bool):
            return value
        return str(value).strip().lower() in {"1", "true", "yes", "on"}
    return kind(value)


def _apply_file(settings: Settings, path: Path) -> None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return
    except (OSError, json.JSONDecodeError):
        return
    if not isinstance(data, dict):
        return
    known = {f.name: f.type for f in fields(Settings)}
    for key, value in data.items():
        if key in known:
            try:
                setattr(settings, key, _coerce(value, type(getattr(settings, key))))
            except (TypeError, ValueError):
                continue


def load_settings(path: str | os.PathLike[str] | None = None) -> Settings:
    settings = Settings()

    repo_config = Path(__file__).resolve().parents[3] / "config" / "tts.json"
    _apply_file(settings, repo_config)

    user_config = Path(os.path.expanduser("~/.pearl/tts.json"))
    _apply_file(settings, user_config)

    if path:
        _apply_file(settings, Path(os.path.expanduser(str(path))))

    for env_name, (attr, kind) in _ENV_MAP.items():
        value = os.environ.get(env_name)
        if value is None or value == "":
            continue
        try:
            setattr(settings, attr, _coerce(value, kind))
        except (TypeError, ValueError):
            continue

    return settings


def settings_to_json(settings: Settings) -> str:
    return json.dumps(asdict(settings), indent=2, sort_keys=True)
