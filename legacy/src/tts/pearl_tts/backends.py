"""Local neural TTS backends.

Priority order: Kokoro-82M (ONNX) -> Piper -> macOS ``say``.

Kokoro is the production path.  It is an 82M-parameter StyleTTS2-style model
that runs comfortably faster than real time on Apple Silicon.  ONNX Runtime's
CoreML execution provider can place supported subgraphs on the Apple Neural
Engine/GPU; because Kokoro's graph has dynamic sequence lengths, the provider
often partitions rather than absorbs the whole graph.  We therefore measure
both and default to CPU unless CoreML wins on the actual machine.

Piper is a lighter fallback for machines without the Kokoro model.  macOS
``say`` is the last-resort backend so Pearl is never silent, but it is not a
neural voice and is reported as degraded in metrics.
"""

from __future__ import annotations

import json
import logging
import os
import platform
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path
from typing import Protocol

from .config import Settings

log = logging.getLogger("pearl.tts.backends")

__all__ = [
    "BackendUnavailable",
    "TTSBackend",
    "KokoroBackend",
    "PiperBackend",
    "SayBackend",
    "build_backend",
    "backend_candidates",
]

SAMPLE_RATE_FALLBACK = 24000


class BackendUnavailable(RuntimeError):
    """Raised when a backend's binary, model or dependency is missing."""


class TTSBackend(Protocol):
    name: str
    sample_rate: int
    degraded: bool

    def warmup(self, voice: str, speed: float) -> float: ...
    def synthesize(self, text: str, voice: str, speed: float) -> tuple[bytes, int]: ...
    def close(self) -> None: ...


def _to_s16le(samples, gain: float = 1.0) -> bytes:
    import numpy as np

    array = np.asarray(samples)
    if array.dtype.kind == "f":
        array = np.clip(array * gain, -1.0, 1.0) * 32767.0
    elif array.dtype != np.int16:
        array = np.clip(array, -32768, 32767)
    return np.ascontiguousarray(array.astype("<i2", copy=False)).tobytes()


def _read_wav_pcm(path: str) -> tuple[bytes, int]:
    with wave.open(path, "rb") as wav:
        channels = wav.getnchannels()
        width = wav.getsampwidth()
        rate = wav.getframerate()
        frames = wav.readframes(wav.getnframes())
    if width != 2:
        raise BackendUnavailable(f"expected 16-bit audio from say, got {width * 8}-bit")
    if channels != 1:
        import numpy as np

        pcm = np.frombuffer(frames, dtype="<i2").reshape(-1, channels)
        pcm = pcm.mean(axis=1).astype("<i2")
        frames = pcm.tobytes()
    return frames, rate


class KokoroBackend:
    name = "kokoro"
    degraded = False
    sample_rate = 24000

    def __init__(self, settings: Settings, provider: str | None = None) -> None:
        model_path = settings.resolved_kokoro_model()
        voices_path = settings.resolved_kokoro_voices()
        if not model_path.is_file():
            raise BackendUnavailable(
                f"Kokoro model not found at {model_path}. Run `make tts-models` "
                "or set PEARL_KOKORO_MODEL."
            )
        if not voices_path.is_file():
            raise BackendUnavailable(
                f"Kokoro voices file not found at {voices_path}. Run `make tts-models`."
            )

        try:
            import onnxruntime as ort
            from kokoro_onnx import Kokoro
        except ImportError as exc:
            raise BackendUnavailable(
                f"Kokoro dependencies missing ({exc}). Install with "
                "`make tts-setup` (Python 3.11/3.12 venv)."
            ) from exc

        self._provider = (provider or settings.provider or "cpu").lower()
        self._lang = settings.lang
        self._warm = False
        self._model_path = str(model_path)
        self._voices_path = str(voices_path)

        options = ort.SessionOptions()
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        options.intra_op_num_threads = max(1, min(int(settings.intra_op_threads), os.cpu_count() or 4))
        options.inter_op_num_threads = 1

        session = None
        if self._provider in ("coreml", "ane", "neural"):
            session = self._coreml_session(ort, options, settings)
            if session is None:
                log.warning("CoreML provider unavailable/failed; falling back to CPU")
                self._provider = "cpu"
        if session is None:
            session = ort.InferenceSession(
                self._model_path,
                sess_options=options,
                providers=["CPUExecutionProvider"],
            )
            self._provider = "cpu"

        # Reuse kokoro-onnx's tokenizer/config while supplying our own session
        # (this is the only way to pass CoreML provider options).
        kokoro = Kokoro.__new__(Kokoro)
        kokoro._setup(
            session=session,
            model_path=self._model_path,
            voices_path=self._voices_path,
            espeak_config=None,
            vocab_config=None,
        )
        self._kokoro = kokoro
        self._dtype = "cpu"

    def _coreml_session(self, ort, options, settings: Settings):
        units = {
            "all": "All",
            "cpu_and_gpu": "CPUAndGPU",
            "cpu_and_ne": "CPUAndNeuralEngine",
            "cpu_only": "CPUOnly",
        }.get(settings.coreml_units.lower())
        if units is None:
            log.warning("Unknown coreml_units=%r; using CPUAndNeuralEngine", settings.coreml_units)
            units = "CPUAndNeuralEngine"
        provider_options = {
            "ModelFormat": "MLProgram",
            "MLComputeUnits": units,
            "RequireStaticInputShapes": "0",
            "EnableOnSubgraphs": "1",
        }
        try:
            return ort.InferenceSession(
                self._model_path,
                sess_options=options,
                providers=["CoreMLExecutionProvider", "CPUExecutionProvider"],
                provider_options=[provider_options, {}],
            )
        except Exception as exc:  # EP failures are opaque; degrade to CPU
            log.warning("CoreML session creation failed: %s", exc)
            return None

    def warmup(self, voice: str, speed: float) -> float:
        import time

        started = time.perf_counter()
        # A short utterance forces graph partitioning, allocator growth and
        # (for CoreML) compilation before the user's first real sentence.
        self.synthesize("Ready.", voice, speed)
        elapsed = (time.perf_counter() - started) * 1000.0
        self._warm = True
        return elapsed

    def synthesize(self, text: str, voice: str, speed: float) -> tuple[bytes, int]:
        try:
            samples, rate = self._kokoro.create(
                text,
                voice=voice or "bf_emma",
                speed=max(0.5, min(2.0, speed)),
                lang=self._lang,
                trim=True,
            )
        except Exception as exc:
            raise BackendUnavailable(f"Kokoro synthesis failed: {exc}") from exc
        self.sample_rate = int(rate or SAMPLE_RATE_FALLBACK)
        return _to_s16le(samples, gain=1.0), self.sample_rate

    def close(self) -> None:
        self._kokoro = None


class PiperBackend:
    name = "piper"
    degraded = False

    def __init__(self, settings: Settings) -> None:
        binary = shutil.which(settings.piper_bin) or settings.piper_bin
        if not binary or not Path(binary).exists():
            raise BackendUnavailable(
                "piper binary not found. Install Piper or set PEARL_PIPER_BIN."
            )
        model = Path(os.path.expanduser(settings.piper_model)) if settings.piper_model else None
        if not model or not model.is_file():
            raise BackendUnavailable(
                "Piper voice model missing. Set PEARL_PIPER_MODEL to a .onnx voice."
            )
        self._binary = binary
        self._model = str(model)
        self._config = (
            os.path.expanduser(settings.piper_config) if settings.piper_config else ""
        )
        self._sample_rate = 22050
        if self._config and Path(self._config).is_file():
            try:
                cfg = json.loads(Path(self._config).read_text(encoding="utf-8"))
                self._sample_rate = int(cfg.get("audio", {}).get("sample_rate", 22050))
            except (OSError, ValueError, TypeError):
                pass
        self.sample_rate = self._sample_rate

    def warmup(self, voice: str, speed: float) -> float:
        import time

        started = time.perf_counter()
        self.synthesize("Ready.", voice, speed)
        return (time.perf_counter() - started) * 1000.0

    def synthesize(self, text: str, voice: str, speed: float) -> tuple[bytes, int]:
        length_scale = str(max(0.5, min(2.0, 1.0 / max(0.5, speed))))
        base = [
            self._binary,
            "--model", self._model,
            "--output-raw",
            "--sentence-silence", "0.05",
        ]
        if self._config:
            base.extend(["--config", self._config])

        last_error = ""
        for scale_flag in ("--length-scale", "--length_scale"):
            cmd = base + [scale_flag, length_scale]
            try:
                result = subprocess.run(
                    cmd,
                    input=text.encode("utf-8"),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=30,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                last_error = str(exc)
                break
            if result.returncode == 0 and result.stdout:
                return result.stdout, self._sample_rate
            last_error = result.stderr.decode("utf-8", "replace")[-500:]
        raise BackendUnavailable(f"Piper failed: {last_error or 'no output'}")

    def close(self) -> None:
        return None


class SayBackend:
    """Degraded fallback.  Not neural, but always present on macOS."""

    name = "say"
    degraded = True
    sample_rate = 24000

    def __init__(self, settings: Settings) -> None:
        self._bin = shutil.which("say")
        if not self._bin:
            raise BackendUnavailable("macOS `say` not found")
        self._voice = settings.say_voice
        self._rate = int(settings.say_rate)
        self.sample_rate = 24000

    def warmup(self, voice: str, speed: float) -> float:
        import time

        started = time.perf_counter()
        self.synthesize("Ready.", voice, speed)
        return (time.perf_counter() - started) * 1000.0

    def synthesize(self, text: str, voice: str, speed: float) -> tuple[bytes, int]:
        voice_name = voice if voice and voice not in ("bf_emma", "af_heart") else self._voice
        rate = int(max(120, min(300, self._rate * max(0.6, min(1.6, speed)))))
        fd, path = tempfile.mkstemp(prefix="pearl-say-", suffix=".wav")
        os.close(fd)
        try:
            cmd = [
                self._bin,
                "-v", voice_name,
                "-r", str(rate),
                "--data-format", "LEI16@24000",
                "-o", path,
                text,
            ]
            result = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE, timeout=30)
            if result.returncode != 0:
                # Retry with the system default voice rather than going silent.
                cmd = [self._bin, "-r", str(rate),
                       "--data-format", "LEI16@24000", "-o", path, text]
                result = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.PIPE, timeout=30)
            if result.returncode != 0:
                raise BackendUnavailable(
                    "say failed: " + result.stderr.decode("utf-8", "replace")[-300:]
                )
            pcm, rate_out = _read_wav_pcm(path)
            self.sample_rate = rate_out
            return pcm, rate_out
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass

    def close(self) -> None:
        return None


def backend_candidates(settings: Settings) -> list[str]:
    requested = (settings.backend or "auto").lower()
    if requested not in ("auto", "kokoro", "piper", "say"):
        raise BackendUnavailable(f"unknown backend {requested!r}")
    if requested != "auto":
        return [requested]
    return ["kokoro", "piper", "say"]


def build_backend(settings: Settings) -> TTSBackend:
    errors: list[str] = []
    for name in backend_candidates(settings):
        try:
            if name == "kokoro":
                backend = KokoroBackend(settings)
            elif name == "piper":
                backend = PiperBackend(settings)
            elif name == "say":
                backend = SayBackend(settings)
            else:  # pragma: no cover - guarded by backend_candidates
                raise BackendUnavailable(name)
            log.info(
                "TTS backend=%s provider=%s degraded=%s platform=%s",
                backend.name,
                getattr(backend, "_provider", "-"),
                backend.degraded,
                platform.machine(),
            )
            return backend
        except BackendUnavailable as exc:
            errors.append(f"{name}: {exc}")
            log.warning("backend %s unavailable: %s", name, exc)
    raise BackendUnavailable("no usable TTS backend:\n  " + "\n  ".join(errors))
