"""`pearl-tts` — streaming text-to-speech client and benchmark harness.

Two modes matter:

* **stream** — text arrives from an LLM (Ollama NDJSON, stdin, or argv), the
  chunker emits clauses, synthesis and playback run on separate threads, and
  audio starts on the first clause.
* **bench** — measures cold start, time-to-first-audio, synthesis RTF and
  underrun risk with the real backend, and writes a JSON report.

The client never imports the model itself unless the daemon cannot be started;
keeping the heavy ONNX session out of the CLI process is what allows the HUD
and orchestrator to stay small.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import queue
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Iterator

from .chunker import ChunkerConfig, StreamingChunker, chunk_text
from .config import Settings, load_settings
from .metrics import MetricWriter, now_ms
from .protocol import ProtocolError, recv_frame

__all__ = ["main", "TTSClient", "ensure_engine", "stop_engine", "engine_status"]

OLLAMA_URL = os.environ.get("PEARL_OLLAMA_URL", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("PEARL_OLLAMA_MODEL", "pearl-1.5b:latest")


class EngineError(RuntimeError):
    def __init__(self, message: str, code: str = "E_ENGINE") -> None:
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------------------
# Daemon lifecycle
# ---------------------------------------------------------------------------

def _connect(settings: Settings, timeout: float = 2.0) -> socket.socket:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(str(settings.resolved_socket()))
    return sock


def _read_hello(sock: socket.socket, timeout: float = 30.0) -> dict[str, Any]:
    sock.settimeout(timeout)
    header, _ = recv_frame(sock)
    if header.get("t") != "hello":
        raise EngineError(f"unexpected handshake: {header!r}", "E_HANDSHAKE")
    return header


def engine_status(settings: Settings) -> dict[str, Any] | None:
    try:
        sock = _connect(settings, timeout=0.5)
    except OSError:
        return None
    try:
        sock.sendall(b'{"op":"ping"}\n')
        header, _ = recv_frame(sock)
        return header
    except (OSError, ProtocolError):
        return None
    finally:
        sock.close()


def stop_engine(settings: Settings, timeout: float = 5.0) -> bool:
    try:
        sock = _connect(settings, timeout=0.5)
    except OSError:
        # Fall back to the pid file if the socket is wedged.
        pid_file = Path(os.path.expanduser(settings.pid_file))
        try:
            pid = int(pid_file.read_text().strip())
            os.kill(pid, signal.SIGTERM)
            return True
        except (OSError, ValueError):
            return False
    try:
        sock.sendall(b'{"op":"shutdown"}\n')
        try:
            recv_frame(sock)
        except (OSError, ProtocolError):
            pass
    except OSError:
        pass
    finally:
        sock.close()

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not settings.resolved_socket().exists():
            return True
        time.sleep(0.05)
    return False


def ensure_engine(settings: Settings, start_timeout: float = 30.0,
                  verbose: bool = False) -> dict[str, Any]:
    """Connect to the daemon, starting it if necessary. Returns the hello frame."""
    try:
        sock = _connect(settings)
        hello = _read_hello(sock, timeout=5.0)
        sock.close()
        return hello
    except (OSError, EngineError, ProtocolError):
        pass

    socket_path = settings.resolved_socket()
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    log_path = settings.resolved_log()
    log_path.parent.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    package_parent = str(Path(__file__).resolve().parents[1])
    env["PYTHONPATH"] = package_parent + (
        os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else ""
    )
    cmd = [sys.executable, "-m", "pearl_tts.engine", "--serve"]
    if verbose:
        cmd.append("--verbose")

    with log_path.open("ab") as log_handle:
        subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=log_handle,
            stderr=log_handle,
            env=env,
            start_new_session=True,
            close_fds=True,
        )

    started = time.monotonic()
    last_error: Exception | None = None
    while time.monotonic() - started < start_timeout:
        if socket_path.exists():
            try:
                sock = _connect(settings, timeout=1.0)
                hello = _read_hello(sock, timeout=10.0)
                hello["client_wait_ms"] = round((time.monotonic() - started) * 1000.0, 1)
                sock.close()
                return hello
            except (OSError, EngineError, ProtocolError) as exc:
                last_error = exc
        time.sleep(0.025)

    tail = ""
    try:
        tail = log_path.read_text(encoding="utf-8")[-2000:]
    except OSError:
        pass
    raise EngineError(
        "TTS engine did not become ready within "
        f"{start_timeout:.0f}s ({last_error}).\nSee {log_path}\n{tail}",
        "E_START_TIMEOUT",
    )


# ---------------------------------------------------------------------------
# Socket client
# ---------------------------------------------------------------------------

class TTSClient:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.sock: socket.socket | None = None
        self.hello: dict[str, Any] = {}
        self._request_counter = 0
        self._lock = threading.Lock()

    def connect(self, start_timeout: float = 30.0, verbose: bool = False) -> None:
        self.hello = ensure_engine(self.settings, start_timeout=start_timeout, verbose=verbose)
        self.sock = _connect(self.settings, timeout=self.settings.request_timeout)
        self.sock.settimeout(self.settings.request_timeout)
        # Consume the greeting on the long-lived connection too.
        header, _ = recv_frame(self.sock)
        if header.get("t") == "hello":
            self.hello.update(header)

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def _next_id(self) -> str:
        with self._lock:
            self._request_counter += 1
            return f"{os.getpid()}-{self._request_counter}"

    def cancel(self, request_id: str) -> None:
        """Cancel via a short control connection so barge-in can interrupt reads."""
        try:
            sock = _connect(self.settings, timeout=0.5)
        except OSError:
            return
        try:
            sock.sendall((json.dumps({"op": "cancel", "id": request_id}) + "\n").encode())
            sock.settimeout(0.5)
            try:
                recv_frame(sock)
            except (OSError, ProtocolError):
                pass
        except OSError:
            pass
        finally:
            sock.close()

    def speak_frames(self, text: str, voice: str | None = None,
                     speed: float | None = None, cache: bool = True,
                     ) -> Iterator[tuple[dict[str, Any], bytes]]:
        """Yield (header, pcm) frames for one clause. Raises EngineError."""
        if self.sock is None:
            raise EngineError("not connected", "E_NOT_CONNECTED")
        request_id = self._next_id()
        request = {
            "op": "speak",
            "id": request_id,
            "text": text,
            "voice": voice or self.settings.voice,
            "speed": speed if speed is not None else self.settings.speed,
            "cache": cache,
        }
        self.sock.sendall((json.dumps(request, ensure_ascii=False) + "\n").encode("utf-8"))
        try:
            while True:
                header, payload = recv_frame(self.sock)
                kind = header.get("t")
                if kind == "audio":
                    yield header, payload
                elif kind == "done":
                    return
                elif kind in ("cancelled", "cancelling"):
                    return
                elif kind == "error":
                    raise EngineError(header.get("message", "engine error"),
                                      header.get("code", "E_ENGINE"))
                elif kind == "start":
                    continue
                else:
                    continue
        except (BrokenPipeError, ConnectionResetError) as exc:
            raise EngineError(f"engine connection lost: {exc}", "E_DISCONNECTED") from exc

    def speak_collect(self, text: str, voice: str | None = None,
                      speed: float | None = None, cache: bool = True,
                      ) -> tuple[bytes, int, dict[str, Any]]:
        pcm = bytearray()
        rate = 0
        first_frame_ms: float | None = None
        started = now_ms()
        meta: dict[str, Any] = {}
        for header, payload in self.speak_frames(text, voice, speed, cache=cache):
            if first_frame_ms is None:
                first_frame_ms = now_ms() - started
            rate = int(header.get("sr", rate or 24000))
            pcm.extend(payload)
        meta["first_frame_ms"] = round(first_frame_ms or 0.0, 3)
        return bytes(pcm), rate, meta


# ---------------------------------------------------------------------------
# Playback
# ---------------------------------------------------------------------------

class PlaybackSink:
    def prepare(self, rate: int) -> None:
        """Optionally open the device before the first chunk arrives."""
        return None

    def push(self, pcm: bytes, rate: int) -> None: ...
    def finish(self) -> None: ...


class NullSink(PlaybackSink):
    def prepare(self, rate: int) -> None:
        return None

    def push(self, pcm: bytes, rate: int) -> None:
        return None

    def finish(self) -> None:
        return None


class SoundDeviceSink(PlaybackSink):
    """Gapless CoreAudio playback with a blocking write (natural backpressure)."""

    def __init__(self) -> None:
        import sounddevice as sd

        self._sd = sd
        self._stream = None
        self._rate = 0
        self.open_ms = 0.0
        self.underruns = 0
        self.played_bytes = 0
        self._lock = threading.RLock()

    def _open(self, rate: int) -> None:
        started = time.perf_counter()
        kwargs = dict(
            samplerate=rate,
            channels=1,
            dtype="int16",
            latency="low",
        )
        try:
            self._stream = self._sd.RawOutputStream(blocksize=512, **kwargs)
        except Exception:
            # Some devices reject small blocks; let PortAudio choose.
            self._stream = self._sd.RawOutputStream(blocksize=0, **kwargs)
        self._stream.start()
        self._rate = rate
        self.open_ms = (time.perf_counter() - started) * 1000.0

    def prepare(self, rate: int) -> None:
        """Pay the CoreAudio device-open cost while Pearl is still thinking."""
        with self._lock:
            if self._stream is None:
                self._open(rate)
                # Prime the device with 10 ms of silence; the first real frame
                # then starts immediately instead of waiting on CoreAudio.
                try:
                    self._stream.write(b"\x00\x00" * max(1, rate // 100))
                except Exception:
                    pass

    def push(self, pcm: bytes, rate: int) -> None:
        if not pcm:
            return
        with self._lock:
            if self._stream is None or rate != self._rate:
                if self._stream is not None:
                    try:
                        self._stream.stop()
                        self._stream.close()
                    except Exception:
                        pass
                self._open(rate)
            try:
                self._stream.write(pcm)
                self.played_bytes += len(pcm)
            except Exception:
                self.underruns += 1
                raise

    def finish(self) -> None:
        with self._lock:
            if self._stream is not None:
                try:
                    self._stream.stop()
                except Exception:
                    pass
                try:
                    self._stream.close()
                except Exception:
                    pass
                self._stream = None


class AfplaySink(PlaybackSink):
    """Last-resort player: one temp WAV per clause. Has audible gaps."""

    def __init__(self) -> None:
        self._afplay = "/usr/bin/afplay"
        self._rate = 0
        self.open_ms = 0.0

    def push(self, pcm: bytes, rate: int) -> None:
        if not pcm:
            return
        fd, path = tempfile.mkstemp(prefix="pearl-play-", suffix=".wav")
        os.close(fd)
        try:
            with wave.open(path, "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(rate)
                wav.writeframes(pcm)
            subprocess.run([self._afplay, path], check=False)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass

    def finish(self) -> None:
        return None


def _rms_level(pcm: bytes) -> float:
    if not pcm:
        return 0.0
    try:
        import numpy as np

        samples = np.frombuffer(pcm, dtype="<i2")
        if samples.size == 0:
            return 0.0
        rms = float(np.sqrt(np.mean(samples.astype(np.float64) ** 2)))
        return max(0.0, min(1.0, rms / 12000.0))
    except Exception:
        sample_count = len(pcm) // 2
        if sample_count == 0:
            return 0.0
        step = max(1, sample_count // 512)
        total = 0.0
        count = 0
        for i in range(0, sample_count, step):
            value = int.from_bytes(pcm[2 * i:2 * i + 2], "little", signed=True)
            total += value * value
            count += 1
        return min(1.0, math.sqrt(total / max(1, count)) / 12000.0)


class StateWriter:
    """Publishes speaking state + RMS for the HUD without shared memory."""

    def __init__(self, path: str, backend: str) -> None:
        self.path = Path(os.path.expanduser(path)) if path else None
        self.backend = backend
        self._last_write = 0.0
        if self.path:
            try:
                self.path.parent.mkdir(parents=True, exist_ok=True)
            except OSError:
                self.path = None

    def update(self, state: str, level: float = 0.0, force: bool = False) -> None:
        if not self.path:
            return
        now = time.monotonic()
        if not force and now - self._last_write < 0.04:
            return
        self._last_write = now
        payload = json.dumps({
            "state": state,
            "level": round(level, 4),
            "backend": self.backend,
            "ts": round(time.time(), 3),
        })
        try:
            temp = self.path.with_suffix(".tmp")
            temp.write_text(payload, encoding="utf-8")
            os.replace(temp, self.path)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Streaming pipeline
# ---------------------------------------------------------------------------

@dataclass
class TurnMetrics:
    started_ms: float
    first_text_ms: float | None = None
    first_chunk_ms: float | None = None
    first_audio_ms: float | None = None
    first_write_ms: float | None = None
    text_source: str = "argv"
    chunks: int = 0
    frames: int = 0
    audio_ms: float = 0.0
    synth_ms: float = 0.0
    engine: dict[str, Any] = field(default_factory=dict)

    def summary(self) -> dict[str, Any]:
        first_audio = self.first_audio_ms
        first_write = self.first_write_ms
        first_chunk = self.first_chunk_ms
        audible = first_write if first_write is not None else first_audio
        # Time from text being available to the first audible sample.  Device
        # open (prepare_ms) is intentionally excluded when it happened before
        # text arrived, because it overlaps "thinking"/LLM latency.
        if audible is not None and first_chunk is not None:
            ttfa = max(0.0, audible - first_chunk)
        else:
            ttfa = 0.0
        return {
            "text_source": self.text_source,
            "first_text_ms": round(self.first_text_ms or 0.0, 1),
            "first_chunk_ms": round(self.first_chunk_ms or 0.0, 1),
            "first_audio_frame_ms": round(first_audio or 0.0, 1),
            "first_audio_write_ms": round(first_write or 0.0, 1),
            "ttfa_ms": round(ttfa, 1),
            "ttfa_frame_ms": round(
                max(0.0, (first_audio or 0.0) - (first_chunk or 0.0)), 1
            ),
            "audio_ms": round(self.audio_ms, 1),
            "chunks": self.chunks,
            "frames": self.frames,
            "engine_backend": self.engine.get("backend"),
            "engine_provider": self.engine.get("provider"),
            "engine_degraded": self.engine.get("degraded"),
            "engine_load_ms": self.engine.get("load_ms"),
            "engine_warmup_ms": self.engine.get("warmup_ms"),
        }


class Pipeline:
    def __init__(self, client: TTSClient, settings: Settings, sink: PlaybackSink,
                 state: StateWriter, print_text: bool = False) -> None:
        self.client = client
        self.settings = settings
        self.sink = sink
        self.state = state
        self.print_text = print_text
        self.chunk_queue: queue.Queue[str | None] = queue.Queue(maxsize=6)
        self.audio_queue: queue.Queue[tuple[bytes, int] | None] = queue.Queue(maxsize=24)
        self.cancel_event = threading.Event()
        self.metrics = TurnMetrics(started_ms=now_ms())
        self.metrics.engine = dict(client.hello)
        self.error: Exception | None = None
        self._first_chunk_time: float | None = None
        self._first_audio_time: float | None = None
        self._first_write_time: float | None = None
        self._audio_bytes = 0
        self._rate_hint = 0
        self._save_chunks: list[bytes] = []
        self._save_rate = 0
        self.prepare_ms = 0.0
        self._synth_thread: threading.Thread | None = None
        self._play_thread: threading.Thread | None = None

    # -------------------------------------------------------------- workers
    def _synth_worker(self) -> None:
        while not self.cancel_event.is_set():
            try:
                chunk = self.chunk_queue.get(timeout=0.25)
            except queue.Empty:
                continue
            if chunk is None:
                break
            try:
                first = True
                for header, payload in self.client.speak_frames(chunk):
                    if self.cancel_event.is_set():
                        break
                    if first:
                        first = False
                        if self._first_audio_time is None:
                            self._first_audio_time = now_ms() - self.metrics.started_ms
                            self.metrics.first_audio_ms = self._first_audio_time
                    rate = int(header.get("sr", 24000))
                    self._rate_hint = rate
                    self.metrics.frames += 1
                    while not self.cancel_event.is_set():
                        try:
                            self.audio_queue.put((payload, rate), timeout=0.1)
                            break
                        except queue.Full:
                            continue
            except EngineError as exc:
                self.error = exc
                self.cancel_event.set()
                break
            finally:
                self.chunk_queue.task_done()

        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            try:
                self.audio_queue.put(None, timeout=0.1)
                break
            except queue.Full:
                continue

    def _play_worker(self) -> None:
        while True:
            item = self.audio_queue.get()
            if item is None:
                break
            pcm, rate = item
            if self.cancel_event.is_set():
                continue
            try:
                self.sink.push(pcm, rate)
            except Exception as exc:
                self.error = exc
                self.cancel_event.set()
                break
            if self._first_write_time is None:
                self._first_write_time = now_ms() - self.metrics.started_ms
                self.metrics.first_write_ms = self._first_write_time
            self._audio_bytes += len(pcm)
            self.metrics.audio_ms = (self._audio_bytes / 2 / max(1, rate)) * 1000.0
            level = _rms_level(pcm)
            self.state.update("speaking", level)
            if self.settings.save_audio:
                self._save_chunks.append(pcm)
                self._save_rate = rate
            self.audio_queue.task_done()

    # ------------------------------------------------------------- producer
    def _put_chunk(self, chunk: str) -> None:
        if self.cancel_event.is_set():
            return
        if self._first_chunk_time is None:
            self._first_chunk_time = now_ms() - self.metrics.started_ms
            self.metrics.first_chunk_ms = self._first_chunk_time
        self.metrics.chunks += 1
        if self.print_text:
            print(chunk, flush=True)
        # Bounded queue with timeout so a worker failure cannot deadlock the
        # producer (or leave the process hanging on Ctrl-C).
        while not self.cancel_event.is_set():
            try:
                self.chunk_queue.put(chunk, timeout=0.1)
                return
            except queue.Full:
                continue

    def run(self, text_iter: Iterable[str], ack: str | None = None) -> dict[str, Any]:
        # Open the audio device before any text exists.  CoreAudio device-open
        # can cost 200-400 ms on macOS; doing it during "thinking" keeps it out
        # of the time-to-first-syllable budget.
        try:
            self.sink.prepare(int(self.client.hello.get("sample_rate", 24000)))
        except Exception:
            pass
        self._synth_thread = threading.Thread(target=self._synth_worker,
                                              name="tts-synth", daemon=True)
        self._play_thread = threading.Thread(target=self._play_worker,
                                             name="tts-play", daemon=True)
        self._synth_thread.start()
        self._play_thread.start()

        if ack:
            self._put_chunk(ack)
        chunker = StreamingChunker(ChunkerConfig(
            sentence_min_chars=self.settings.sentence_min_chars,
            clause_min_chars=self.settings.clause_min_chars,
            first_clause_min_chars=self.settings.first_clause_min_chars,
            max_chars=self.settings.max_chars,
            code_policy=self.settings.code_policy,
        ))

        try:
            for fragment in text_iter:
                if not fragment:
                    continue
                if self.metrics.first_text_ms is None:
                    self.metrics.first_text_ms = now_ms() - self.metrics.started_ms
                for chunk in chunker.feed(fragment):
                    self._put_chunk(chunk)
                if self.cancel_event.is_set():
                    break
            if not self.cancel_event.is_set():
                for chunk in chunker.flush():
                    self._put_chunk(chunk)
        finally:
            deadline = time.monotonic() + 1.0
            while time.monotonic() < deadline:
                try:
                    self.chunk_queue.put(None, timeout=0.1)
                    break
                except queue.Full:
                    continue

        self._synth_thread.join(timeout=self.settings.request_timeout)
        self._play_thread.join(timeout=self.settings.request_timeout)
        self.sink.finish()
        self.state.update("idle", 0.0, force=True)

        if self.settings.save_audio and self._save_chunks:
            self._write_wav()
        return self.metrics.summary()

    def _write_wav(self) -> None:
        path = Path(os.path.expanduser(self.settings.save_audio))
        path.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(path), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(self._save_rate or 24000)
            wav.writeframes(b"".join(self._save_chunks))


# ---------------------------------------------------------------------------
# Text sources
# ---------------------------------------------------------------------------

def _stream_stdin() -> Iterator[str]:
    stdin = sys.stdin
    while True:
        fragment = stdin.read(128)
        if not fragment:
            return
        yield fragment


def _stream_ollama(prompt: str, model: str) -> Iterator[str]:
    payload = json.dumps({
        "model": model,
        "prompt": prompt,
        "stream": True,
        "options": {"temperature": 0.7},
    }).encode("utf-8")
    request = urllib.request.Request(
        f"{OLLAMA_URL}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            for raw_line in response:
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                token = event.get("response") or event.get("message", {}).get("content", "")
                if token:
                    yield token
                if event.get("done"):
                    return
    except (urllib.error.URLError, OSError) as exc:
        raise EngineError(f"Ollama streaming failed: {exc}", "E_OLLAMA") from exc


def _typewriter(text: str, words_per_minute: int = 420) -> Iterator[str]:
    delay = 60.0 / max(60, words_per_minute)
    for word in text.split(" "):
        yield word + " "
        time.sleep(delay)


# ---------------------------------------------------------------------------
# Benchmarks
# ---------------------------------------------------------------------------

BENCH_PHRASES = [
    "Sure, User. Let me check that for you.",
    "The Axiom pull request is clean; there are three modified files and no failing tests.",
    "I've moved your screenshots to the Trash and added a reminder for four o'clock.",
]


def run_bench(settings: Settings, cold: bool, voice: str | None, speed: float | None,
              reps: int = 3, start_timeout: float = 60.0) -> dict[str, Any]:
    if cold:
        stop_engine(settings)

    client = TTSClient(settings)
    started = time.perf_counter()
    client.connect(start_timeout=start_timeout)
    connect_ms = (time.perf_counter() - started) * 1000.0
    hello = dict(client.hello)

    results: list[dict[str, Any]] = []
    ack_ttfa_ms: float | None = None
    try:
        # Warm pass: one short utterance is excluded from the reported numbers.
        list(client.speak_frames("One moment."))

        # The daemon pre-synthesizes the opening phrase at startup. Measure the
        # cached path separately: this is what masks LLM first-token latency.
        if settings.prewarm_acks:
            t_ack = now_ms()
            client.speak_collect(settings.ack_text)
            ack_ttfa_ms = now_ms() - t_ack

        for phrase in BENCH_PHRASES:
            for _ in range(max(1, reps)):
                chunks = chunk_text(phrase)
                first_chunk = chunks[0] if chunks else phrase
                t0 = now_ms()
                pcm, rate, meta = client.speak_collect(first_chunk, voice, speed,
                                                       cache=False)
                ttfa = now_ms() - t0
                total_pcm = len(pcm)
                total_audio_ms = total_pcm / 2 / max(1, rate) * 1000.0
                chunk_results = []
                for chunk in chunks[1:]:
                    t1 = now_ms()
                    c_pcm, c_rate, _ = client.speak_collect(chunk, voice, speed,
                                                           cache=False)
                    c_synth = now_ms() - t1
                    c_audio = len(c_pcm) / 2 / max(1, c_rate) * 1000.0
                    chunk_results.append({
                        "chars": len(chunk),
                        "synth_ms": round(c_synth, 2),
                        "audio_ms": round(c_audio, 2),
                        "rtf": round(c_synth / c_audio, 3) if c_audio else None,
                    })
                    total_pcm += len(c_pcm)
                    total_audio_ms += c_audio
                results.append({
                    "phrase": phrase,
                    "first_chunk_chars": len(first_chunk),
                    "first_chunk_synth_ms": round(meta.get("first_frame_ms", ttfa), 2),
                    "ttfa_ms": round(ttfa, 2),
                    "chunks": len(chunks),
                    "audio_ms": round(total_audio_ms, 1),
                    "total_chars": len(phrase),
                    "degraded": hello.get("degraded"),
                    "chunk_details": chunk_results,
                })
    finally:
        client.close()

    def _median(values: list[float]) -> float:
        if not values:
            return 0.0
        values = sorted(values)
        mid = len(values) // 2
        return values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) / 2

    ttfas = [r["ttfa_ms"] for r in results]
    rtfs = [
        d["rtf"] for r in results for d in r["chunk_details"] if d.get("rtf") is not None
    ]
    report = {
        "engine": hello,
        "connect_ms": round(connect_ms, 2),
        "ack": {
            "text": hello.get("ack_text"),
            "prewarm_ms": hello.get("ack_prewarm_ms"),
            "ttfa_ms": round(ack_ttfa_ms, 2) if ack_ttfa_ms is not None else None,
        },
        "reps": reps,
        "phrases": len(BENCH_PHRASES),
        "ttfa_ms": {
            "min": round(min(ttfas), 2) if ttfas else None,
            "median": round(_median(ttfas), 2),
            "max": round(max(ttfas), 2) if ttfas else None,
            "p95": round(sorted(ttfas)[max(0, int(len(ttfas) * 0.95) - 1)], 2) if ttfas else None,
        },
        "rtf": {
            "min": round(min(rtfs), 3) if rtfs else None,
            "median": round(_median(rtfs), 3),
            "max": round(max(rtfs), 3) if rtfs else None,
        },
        "results": results,
    }
    return report


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pearl-tts",
        description="Streaming local neural TTS for Pearl (Kokoro/Piper/say).",
    )
    parser.add_argument("text", nargs="*", help="text to speak")
    parser.add_argument("--voice", default="", help="backend voice id")
    parser.add_argument("--speed", type=float, default=None)
    parser.add_argument("--backend", default="", help="auto|kokoro|piper|say")
    parser.add_argument("--provider", default="", help="cpu|coreml")
    parser.add_argument("--ollama", metavar="PROMPT", default="",
                        help="stream an Ollama reply straight into speech")
    parser.add_argument("--model", default=OLLAMA_MODEL)
    parser.add_argument("--stdin", action="store_true", help="stream stdin as text")
    parser.add_argument("--typewriter", action="store_true",
                        help="simulate token arrival for latency demos")
    parser.add_argument("--no-play", action="store_true", help="synthesize without playback")
    parser.add_argument("--save", default="", help="also write the turn to a .wav")
    parser.add_argument("--player", choices=["auto", "sounddevice", "afplay", "null"],
                        default="auto")
    parser.add_argument("--print-text", action="store_true", help="print clauses to stdout")
    parser.add_argument("--ack", action="store_true",
                        help="speak a cached acknowledgement immediately (masks LLM latency)")
    parser.add_argument("--ack-text", default="",
                        help="override the acknowledgement phrase")
    parser.add_argument("--json", action="store_true", help="print metrics JSON to stdout")
    parser.add_argument("--quiet", "-q", action="store_true", help="no status output")
    parser.add_argument("--state-file", default="", help="HUD state JSON path")
    parser.add_argument("--start-timeout", type=float, default=30.0)
    parser.add_argument("--bench", action="store_true", help="run the latency benchmark")
    parser.add_argument("--cold", action="store_true", help="stop the warm daemon first")
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--engine-status", action="store_true")
    parser.add_argument("--engine-start", action="store_true")
    parser.add_argument("--engine-stop", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    settings = load_settings()
    if args.voice:
        settings.voice = args.voice
    if args.speed is not None:
        settings.speed = args.speed
    if args.backend:
        settings.backend = args.backend
    if args.provider:
        settings.provider = args.provider
    if args.no_play:
        settings.no_play = True
    if args.save:
        settings.save_audio = args.save
    if args.state_file:
        settings.state_file = args.state_file

    if args.engine_status:
        status = engine_status(settings)
        print(json.dumps(status or {"status": "stopped"}, indent=2))
        return 0
    if args.engine_start:
        try:
            hello = ensure_engine(settings, start_timeout=max(args.start_timeout, 5.0),
                                  verbose=args.verbose)
        except EngineError as exc:
            sys.stderr.write(f"pearl-tts: {exc}\n")
            return 1
        print(json.dumps(hello, indent=2))
        return 0
    if args.engine_stop:
        print("stopped" if stop_engine(settings) else "not running")
        return 0

    if args.bench:
        report = run_bench(settings, cold=args.cold, voice=args.voice or None,
                           speed=args.speed, reps=args.reps,
                           start_timeout=max(args.start_timeout, 60.0))
        print(json.dumps(report, indent=2))
        return 0

    if args.ollama:
        text_iter: Iterable[str] = _stream_ollama(args.ollama, args.model)
        source = "ollama"
    elif args.stdin or (not args.text and not sys.stdin.isatty()):
        text_iter = _stream_stdin()
        source = "stdin"
    elif args.text:
        payload = " ".join(args.text)
        text_iter = _typewriter(payload) if args.typewriter else [payload]
        source = "argv"
    else:
        if sys.stdin.isatty():
            _build_parser().print_help(sys.stderr)
            return 2
        text_iter = _stream_stdin()
        source = "stdin"

    client = TTSClient(settings)
    try:
        client.connect(start_timeout=max(args.start_timeout, 1.0), verbose=args.verbose)
    except EngineError as exc:
        sys.stderr.write(f"pearl-tts: {exc}\n")
        sys.stderr.write(
            "Hint: run `make tts-setup` then `make tts-models`, or install Piper, "
            "or set PEARL_TTS_BACKEND=say.\n"
        )
        return 1

    if args.player == "null" or settings.no_play:
        sink: PlaybackSink = NullSink()
    elif args.player == "afplay":
        sink = AfplaySink()
    elif args.player == "sounddevice":
        try:
            sink = SoundDeviceSink()
        except Exception as exc:
            sys.stderr.write(f"pearl-tts: sounddevice unavailable: {exc}\n")
            return 1
    else:
        try:
            sink = SoundDeviceSink()
        except Exception:
            sink = AfplaySink()

    backend_name = str(client.hello.get("backend", "?"))
    state = StateWriter(settings.state_file, backend_name)
    state.update("thinking", 0.0, force=True)
    # Pre-open CoreAudio while the first tokens are still being generated.
    prepare_started = now_ms()
    try:
        sink.prepare(int(client.hello.get("sample_rate", 24000)))
    except Exception:
        pass
    prepare_ms = now_ms() - prepare_started
    ack_text = None
    if args.ack:
        ack_text = args.ack_text or settings.ack_text
    pipeline = Pipeline(client, settings, sink, state, print_text=args.print_text)

    def _handle_sigint(_signum, _frame):
        pipeline.cancel_event.set()
        sink.finish()

    signal.signal(signal.SIGINT, _handle_sigint)

    try:
        summary = pipeline.run(text_iter, ack=ack_text)
    except EngineError as exc:
        sys.stderr.write(f"pearl-tts: {exc}\n")
        client.close()
        return 1
    finally:
        client.close()

    summary["text_source"] = source
    summary["prepare_ms"] = round(prepare_ms, 1)
    metrics = MetricWriter(settings.resolved_metrics())
    metrics.write("turn", **summary)

    if not args.quiet:
        sys.stderr.write(json.dumps(summary, separators=(",", ":")) + "\n")
    if args.json:
        print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
