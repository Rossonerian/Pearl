"""Pearl local TTS engine daemon.

Run as ``python -m pearl_tts.engine --serve``.  The first client that needs
speech starts the daemon if it is not already running; the model stays warm for
``idle_timeout`` seconds so subsequent replies skip the 0.3-1.5 s cold load.

The daemon is intentionally a plain Unix-socket server, not HTTP.  It carries
raw PCM and has no framework overhead.  One model lock serializes synthesis;
the client pipelines playback so this is not a bottleneck (Kokoro typically
synthesizes a sentence in 15-30% of its audio duration).
"""

from __future__ import annotations

import argparse
import errno
import json
import logging
import os
import signal
import socket
import sys
import threading
import time
from collections import OrderedDict
from pathlib import Path
from socketserver import StreamRequestHandler, ThreadingUnixStreamServer
from typing import Any

from .backends import (
    BackendUnavailable,
    KokoroBackend,
    SayBackend,
    TTSBackend,
    build_backend,
)
from .config import Settings, load_settings
from .metrics import MetricWriter, now_ms
from .protocol import MAX_HEADER, ProtocolError, recv_frame, send_frame

log = logging.getLogger("pearl.tts.engine")

__all__ = ["TTServer", "run_server", "run_oneshot"]

PROTOCOL_VERSION = 1


class AudioCache:
    """Tiny LRU for acknowledgements and repeated short phrases."""

    def __init__(self, max_entries: int = 24, max_bytes: int = 24 << 20) -> None:
        self.max_entries = max_entries
        self.max_bytes = max_bytes
        self._items: OrderedDict[str, tuple[bytes, int]] = OrderedDict()
        self._bytes = 0

    def get(self, key: str) -> tuple[bytes, int] | None:
        item = self._items.get(key)
        if item is None:
            return None
        self._items.move_to_end(key)
        return item

    def put(self, key: str, pcm: bytes, rate: int) -> None:
        if key in self._items:
            old, _ = self._items.pop(key)
            self._bytes -= len(old)
        self._items[key] = (pcm, rate)
        self._bytes += len(pcm)
        while self._items and (
            len(self._items) > self.max_entries or self._bytes > self.max_bytes
        ):
            _, (old, _) = self._items.popitem(last=False)
            self._bytes -= len(old)


class TTServer(ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, address: str, settings: Settings, backend: TTSBackend,
                 warmup_ms: float, load_ms: float) -> None:
        self.settings = settings
        self.backend = backend
        self.warmup_ms = warmup_ms
        self.load_ms = load_ms
        self.metrics = MetricWriter(settings.resolved_metrics())
        self.cache = AudioCache()
        self.model_lock = threading.Lock()
        self.cancel_lock = threading.Lock()
        self.cancelled: set[str] = set()
        self.active_requests = 0
        self.last_activity = time.monotonic()
        self.started_at = time.monotonic()
        self.ack_prewarm_ms = 0.0
        super().__init__(address, _Handler)
        os.chmod(address, 0o600)

    # --------------------------------------------------------------- state
    def mark_activity(self) -> None:
        self.last_activity = time.monotonic()

    def cancel(self, request_id: str) -> None:
        with self.cancel_lock:
            self.cancelled.add(request_id)

    def is_cancelled(self, request_id: str) -> bool:
        with self.cancel_lock:
            return request_id in self.cancelled

    def clear_cancel(self, request_id: str) -> None:
        with self.cancel_lock:
            self.cancelled.discard(request_id)

    # --------------------------------------------------------------- synth
    def synthesize(self, request_id: str, text: str, voice: str,
                   speed: float, use_cache: bool = True) -> tuple[bytes, int, bool]:
        key = f"{self.backend.name}\x00{voice}\x00{speed:.3f}\x00{text}"
        if use_cache and len(text) <= 120:
            cached = self.cache.get(key)
            if cached is not None:
                return cached[0], cached[1], True
        if self.is_cancelled(request_id):
            return b"", 0, False
        with self.model_lock:
            pcm, rate = self.backend.synthesize(text, voice, speed)
        if use_cache and len(text) <= 120:
            self.cache.put(key, pcm, rate)
        return pcm, rate, False

    def prewarm_ack(self, text: str, voice: str, speed: float) -> float:
        """Synthesize an acknowledgement into the cache (one-time cost)."""
        started = time.perf_counter()
        try:
            key = f"{self.backend.name}\x00{voice}\x00{speed:.3f}\x00{text}"
            if self.cache.get(key) is None:
                pcm, rate, _ = self.synthesize("prewarm", text, voice, speed,
                                               use_cache=True)
                if not pcm:
                    return 0.0
        except Exception as exc:
            log.warning("ack prewarm failed for %r: %s", text, exc)
            return 0.0
        return (time.perf_counter() - started) * 1000.0

    # ------------------------------------------------------------- metrics
    def hello(self) -> dict[str, Any]:
        return {
            "t": "hello",
            "proto": PROTOCOL_VERSION,
            "backend": self.backend.name,
            "provider": getattr(self.backend, "_provider", "-"),
            "degraded": bool(self.backend.degraded),
            "sample_rate": self.backend.sample_rate,
            "voice": self.settings.voice,
            "load_ms": round(self.load_ms, 2),
            "warmup_ms": round(self.warmup_ms, 2),
            "ack_prewarm_ms": round(self.ack_prewarm_ms, 2),
            "ack_text": self.settings.ack_text,
            "pid": os.getpid(),
        }


class _Handler(StreamRequestHandler):
    server: TTServer

    def handle(self) -> None:
        self.server.mark_activity()
        try:
            send_frame(self.wfile_socket(), self.server.hello())
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

        while True:
            try:
                line = self.rfile.readline(MAX_HEADER + 1)
            except (ConnectionResetError, OSError):
                return
            if not line:
                return
            if len(line) > MAX_HEADER:
                self._send_error("", "E_BAD_REQUEST", "request too large")
                return
            self.server.mark_activity()
            try:
                request = json.loads(line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                self._send_error("", "E_BAD_JSON", "request must be one JSON object per line")
                continue
            if not isinstance(request, dict):
                self._send_error("", "E_BAD_JSON", "request must be a JSON object")
                continue
            if not self._dispatch(request):
                return

    # The handler works with the raw socket.  Socketserver's ``wfile`` is a
    # buffered file object; mixing it with sendall would reorder frames.
    def wfile_socket(self) -> socket.socket:
        return self.connection

    def _dispatch(self, request: dict[str, Any]) -> bool:
        op = request.get("op", "speak")
        if op == "ping":
            send_frame(self.connection, {"t": "pong", **self.server.hello()})
            return True
        if op == "cancel":
            request_id = str(request.get("id", ""))
            if request_id:
                self.server.cancel(request_id)
            send_frame(self.connection, {"t": "ok", "op": "cancel", "id": request_id})
            return True
        if op == "shutdown":
            send_frame(self.connection, {"t": "ok", "op": "shutdown"})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return False
        if op == "speak":
            self._speak(request)
            return True
        self._send_error(str(request.get("id", "")), "E_BAD_OP", f"unknown op {op!r}")
        return True

    def _speak(self, request: dict[str, Any]) -> None:
        request_id = str(request.get("id", "")) or f"r{int(time.time() * 1000)}"
        text = str(request.get("text", "")).strip()
        voice = str(request.get("voice") or self.server.settings.voice)
        try:
            speed = float(request.get("speed", self.server.settings.speed))
        except (TypeError, ValueError):
            speed = self.server.settings.speed
        use_cache = bool(request.get("cache", True))

        if not text:
            self._send_error(request_id, "E_EMPTY", "text is empty")
            return
        if len(text) > self.server.settings.max_text_chars:
            text = text[: self.server.settings.max_text_chars]
            log.warning("truncated request %s to %d chars", request_id,
                        self.server.settings.max_text_chars)

        self.server.active_requests += 1
        started = time.perf_counter()
        try:
            send_frame(self.connection, {"t": "start", "id": request_id, "text": text})
            pcm, rate, cached = self.server.synthesize(request_id, text, voice, speed,
                                                       use_cache=use_cache)
            synth_ms = (time.perf_counter() - started) * 1000.0
            if self.server.is_cancelled(request_id):
                send_frame(self.connection, {"t": "cancelled", "id": request_id})
                return
            if not pcm or rate <= 0:
                self._send_error(request_id, "E_EMPTY_AUDIO", "backend produced no audio")
                return

            bytes_per_sample = 2
            frame_bytes = max(320, self.server.settings.audio_frame_bytes)
            frame_bytes -= frame_bytes % bytes_per_sample
            seq = 0
            for offset in range(0, len(pcm), frame_bytes):
                if self.server.is_cancelled(request_id):
                    send_frame(self.connection, {"t": "cancelled", "id": request_id})
                    return
                payload = pcm[offset:offset + frame_bytes]
                send_frame(self.connection, {
                    "t": "audio",
                    "id": request_id,
                    "seq": seq,
                    "sr": rate,
                    "fmt": "s16le",
                    "ch": 1,
                }, payload)
                seq += 1

            audio_ms = (len(pcm) / bytes_per_sample / rate) * 1000.0
            send_frame(self.connection, {
                "t": "done",
                "id": request_id,
                "synth_ms": round(synth_ms, 3),
                "audio_ms": round(audio_ms, 3),
                "rtf": round(synth_ms / audio_ms, 4) if audio_ms else None,
                "cached": cached,
                "backend": self.server.backend.name,
                "sample_rate": rate,
                "bytes": 0,
            })
            self.server.metrics.write(
                "synth",
                id=request_id,
                backend=self.server.backend.name,
                voice=voice,
                text_chars=len(text),
                cached=cached,
                synth_ms=round(synth_ms, 3),
                audio_ms=round(audio_ms, 3),
                rtf=round(synth_ms / audio_ms, 4) if audio_ms else None,
                provider=getattr(self.server.backend, "_provider", "-"),
            )
        except (BrokenPipeError, ConnectionResetError):
            # The client vanished (barge-in / dismissal).  Synthesis is already
            # done for this chunk; drop it and stop work on the next frame.
            self.server.cancel(request_id)
        except BackendUnavailable as exc:
            self._send_error(request_id, "E_BACKEND", str(exc))
        except ProtocolError as exc:
            self._send_error(request_id, "E_PROTOCOL", str(exc))
        except Exception as exc:  # keep the daemon alive for the next request
            log.exception("synthesis failure")
            self._send_error(request_id, "E_INTERNAL", str(exc))
        finally:
            self.server.active_requests = max(0, self.server.active_requests - 1)
            self.server.clear_cancel(request_id)
            self.server.mark_activity()

    def _send_error(self, request_id: str, code: str, message: str) -> None:
        try:
            send_frame(self.connection, {
                "t": "error",
                "id": request_id,
                "code": code,
                "message": message,
            })
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


def _prepare_logging(settings: Settings, verbose: bool) -> None:
    handlers: list[logging.Handler] = []
    if verbose:
        handlers.append(logging.StreamHandler(sys.stderr))
    try:
        log_path = settings.resolved_log()
        log_path.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.FileHandler(log_path, encoding="utf-8"))
    except OSError:
        pass
    if not handlers:
        handlers.append(logging.NullHandler())
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=handlers,
        force=True,
    )


def _load_backend(settings: Settings) -> tuple[TTSBackend, float, float]:
    load_started = time.perf_counter()
    backend = build_backend(settings)
    load_ms = (time.perf_counter() - load_started) * 1000.0

    try:
        warmup_ms = backend.warmup(settings.voice, settings.speed)
    except BackendUnavailable as exc:
        log.warning("warmup failed for %s: %s", backend.name, exc)
        warmup_ms = 0.0
        if (
            backend.name == "kokoro"
            and getattr(backend, "_provider", "cpu") != "cpu"
            and (settings.backend or "auto").lower() == "auto"
        ):
            # CoreML can compile a partition that fails at execution time.
            # Retry the same model on CPU before giving up on Kokoro entirely.
            log.warning("retrying Kokoro on CPU after CoreML warmup failure")
            try:
                backend = KokoroBackend(settings, provider="cpu")
                warmup_ms = backend.warmup(settings.voice, settings.speed)
                load_ms = (time.perf_counter() - load_started) * 1000.0
            except BackendUnavailable as cpu_exc:
                log.warning("CPU Kokoro warmup failed: %s", cpu_exc)
                backend = None
        else:
            backend = None

        if backend is None:
            if (settings.backend or "auto").lower() == "auto":
                log.warning("falling back to macOS say backend")
                backend = SayBackend(settings)
                warmup_ms = backend.warmup(settings.voice, settings.speed)
                load_ms = (time.perf_counter() - load_started) * 1000.0
            else:
                raise

    log.info(
        "backend ready: %s provider=%s load=%.1fms warmup=%.1fms",
        backend.name,
        getattr(backend, "_provider", "-"),
        load_ms,
        warmup_ms,
    )
    return backend, load_ms, warmup_ms


def run_server(settings: Settings, verbose: bool = False) -> int:
    _prepare_logging(settings, verbose)
    socket_path = settings.resolved_socket()
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(socket_path.parent, 0o700)
    except OSError:
        pass

    if socket_path.exists():
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        probe.settimeout(0.25)
        try:
            probe.connect(str(socket_path))
            log.info("TTS engine already running at %s", socket_path)
            return 0
        except OSError:
            try:
                socket_path.unlink()
            except OSError:
                pass
        finally:
            probe.close()

    backend, load_ms, warmup_ms = _load_backend(settings)
    try:
        server = TTServer(str(socket_path), settings, backend, warmup_ms, load_ms)
    except OSError as exc:
        log.error("cannot bind %s: %s", socket_path, exc)
        return 1

    if settings.prewarm_acks and settings.ack_text.strip():
        server.ack_prewarm_ms = server.prewarm_ack(
            settings.ack_text.strip(), settings.voice, settings.speed
        )
        log.info("ack %r cached in %.1fms", settings.ack_text, server.ack_prewarm_ms)

    metrics = MetricWriter(settings.resolved_metrics())
    metrics.write(
        "engine_start",
        backend=backend.name,
        provider=getattr(backend, "_provider", "-"),
        load_ms=round(load_ms, 2),
        warmup_ms=round(warmup_ms, 2),
        ack_prewarm_ms=round(server.ack_prewarm_ms, 2),
        sample_rate=backend.sample_rate,
        pid=os.getpid(),
    )

    pid_path = Path(os.path.expanduser(settings.pid_file))
    try:
        pid_path.parent.mkdir(parents=True, exist_ok=True)
        pid_path.write_text(str(os.getpid()), encoding="utf-8")
    except OSError:
        pass

    stop = threading.Event()

    def _signal(_signum, _frame):
        stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _signal)
    signal.signal(signal.SIGINT, _signal)

    def _idle_watch() -> None:
        timeout = float(settings.idle_timeout)
        if timeout <= 0:
            return
        while not stop.wait(2.0):
            if server.active_requests:
                continue
            if time.monotonic() - server.last_activity > timeout:
                log.info("idle for %.0fs; shutting down to release memory", timeout)
                stop.set()
                server.shutdown()
                return

    threading.Thread(target=_idle_watch, name="idle-watch", daemon=True).start()
    log.info("listening on %s", socket_path)

    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        try:
            if socket_path.exists():
                socket_path.unlink()
        except OSError:
            pass
        try:
            if pid_path.exists() and pid_path.read_text().strip() == str(os.getpid()):
                pid_path.unlink()
        except OSError:
            pass
        metrics.write("engine_stop", uptime_s=round(time.monotonic() - server.started_at, 3))
        try:
            backend.close()
        except Exception:
            pass
        log.info("stopped")
    return 0


def run_oneshot(settings: Settings, text: str, output: str | None,
                voice: str | None, speed: float | None) -> int:
    """Synthesize one utterance and write raw s16le PCM (or a WAV)."""
    _prepare_logging(settings, verbose=True)
    backend, load_ms, warmup_ms = _load_backend(settings)
    started = time.perf_counter()
    pcm, rate = backend.synthesize(text, voice or settings.voice,
                                   speed if speed is not None else settings.speed)
    synth_ms = (time.perf_counter() - started) * 1000.0
    audio_ms = (len(pcm) / 2 / rate) * 1000.0

    if output and output != "-":
        path = Path(os.path.expanduser(output))
        if path.suffix.lower() == ".wav":
            import wave

            with wave.open(str(path), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(rate)
                wav.writeframes(pcm)
        else:
            path.write_bytes(pcm)
        destination = str(path)
    else:
        sys.stdout.buffer.write(pcm)
        sys.stdout.buffer.flush()
        destination = "stdout"

    summary = {
        "backend": backend.name,
        "provider": getattr(backend, "_provider", "-"),
        "sample_rate": rate,
        "load_ms": round(load_ms, 2),
        "warmup_ms": round(warmup_ms, 2),
        "synth_ms": round(synth_ms, 2),
        "audio_ms": round(audio_ms, 2),
        "rtf": round(synth_ms / audio_ms, 4) if audio_ms else None,
        "destination": destination,
        "degraded": backend.degraded,
    }
    sys.stderr.write(json.dumps(summary) + "\n")
    backend.close()
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pearl-tts-engine", description=__doc__)
    parser.add_argument("--serve", action="store_true", help="run the socket daemon (default)")
    parser.add_argument("--oneshot", action="store_true", help="synthesize one text and exit")
    parser.add_argument("--status", action="store_true", help="print effective settings and exit")
    parser.add_argument("--text", default="", help="text for --oneshot")
    parser.add_argument("--output", "-o", default="", help="raw PCM or .wav path for --oneshot")
    parser.add_argument("--voice", default="")
    parser.add_argument("--speed", type=float, default=None)
    parser.add_argument("--backend", default="", help="auto|kokoro|piper|say")
    parser.add_argument("--provider", default="", help="cpu|coreml")
    parser.add_argument("--idle-timeout", type=float, default=None)
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args(argv)

    settings = load_settings()
    if args.backend:
        settings.backend = args.backend
    if args.provider:
        settings.provider = args.provider
    if args.idle_timeout is not None:
        settings.idle_timeout = args.idle_timeout

    if args.status:
        from .config import settings_to_json

        print(settings_to_json(settings))
        return 0

    if args.oneshot:
        text = args.text
        if not text and not sys.stdin.isatty():
            text = sys.stdin.read()
        if not text.strip():
            parser.error("--oneshot requires --text or stdin")
        return run_oneshot(settings, text, args.output or None,
                           args.voice or None, args.speed)

    return run_server(settings, verbose=args.verbose)


if __name__ == "__main__":
    raise SystemExit(main())
