"""Length-prefixed JSON + binary framing for the Pearl TTS socket.

Wire format (little-endian host, network byte order length):

    [4-byte big-endian JSON length][JSON header][optional raw payload]

Headers are UTF-8 JSON objects and always contain a ``t`` (type) field:

    {"t": "hello", ...}                 server -> client, once per connection
    {"t": "start", "id": "...", ...}    synthesis accepted
    {"t": "audio", "id": "...", "seq": 0, "sr": 24000, "bytes": 9600}
    {"t": "done", "id": "...", ...}
    {"t": "error", "id": "...", "code": "...", "message": "..."}
    {"t": "pong", ...} / {"t": "ok", ...}

Audio payloads are raw signed 16-bit little-endian mono PCM.  Keeping the
transport this small matters: an HTTP stack adds 2-10 ms per chunk, which is
a meaningful slice of a 400 ms budget.
"""

from __future__ import annotations

import json
import socket
import struct
from typing import Any

__all__ = [
    "ProtocolError",
    "MAX_HEADER",
    "MAX_PAYLOAD",
    "send_frame",
    "recv_frame",
    "encode_frame",
    "FrameDecoder",
]

MAX_HEADER = 1 << 20       # 1 MiB of JSON is already absurd for this protocol
MAX_PAYLOAD = 64 << 20     # 64 MiB safety ceiling for one audio frame
_LEN = struct.Struct(">I")


class ProtocolError(RuntimeError):
    pass


def encode_frame(header: dict[str, Any], payload: bytes = b"") -> bytes:
    if payload:
        header = dict(header)
        header["bytes"] = len(payload)
    raw = json.dumps(header, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(raw) > MAX_HEADER:
        raise ProtocolError("header too large")
    return _LEN.pack(len(raw)) + raw + payload


def send_frame(sock: socket.socket, header: dict[str, Any], payload: bytes = b"") -> None:
    if payload:
        header = dict(header)
        header["bytes"] = len(payload)
    sock.sendall(encode_frame(header, payload))


def _recv_exact(sock: socket.socket, length: int) -> bytes:
    if length < 0 or length > MAX_PAYLOAD + MAX_HEADER:
        raise ProtocolError(f"invalid frame length {length}")
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        piece = sock.recv(min(remaining, 1 << 20))
        if not piece:
            raise ProtocolError("connection closed mid-frame")
        chunks.append(piece)
        remaining -= len(piece)
    return b"".join(chunks)


def recv_frame(sock: socket.socket) -> tuple[dict[str, Any], bytes]:
    prefix = _recv_exact(sock, 4)
    (header_len,) = _LEN.unpack(prefix)
    if header_len > MAX_HEADER:
        raise ProtocolError(f"header too large: {header_len}")
    raw_header = _recv_exact(sock, header_len)
    try:
        header = json.loads(raw_header.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"bad JSON header: {exc}") from exc
    if not isinstance(header, dict):
        raise ProtocolError("header must be a JSON object")

    payload_len = header.get("bytes", 0)
    if not isinstance(payload_len, int) or payload_len < 0 or payload_len > MAX_PAYLOAD:
        raise ProtocolError(f"invalid payload length {payload_len!r}")
    payload = _recv_exact(sock, payload_len) if payload_len else b""
    return header, payload


class FrameDecoder:
    """Incremental decoder for non-blocking / stream readers (tests, M4 app)."""

    def __init__(self) -> None:
        self._buffer = bytearray()

    def feed(self, data: bytes) -> list[tuple[dict[str, Any], bytes]]:
        self._buffer.extend(data)
        frames: list[tuple[dict[str, Any], bytes]] = []
        while True:
            if len(self._buffer) < 4:
                return frames
            (header_len,) = _LEN.unpack_from(self._buffer, 0)
            if header_len > MAX_HEADER:
                raise ProtocolError(f"header too large: {header_len}")
            end_header = 4 + header_len
            if len(self._buffer) < end_header:
                return frames
            try:
                header = json.loads(self._buffer[4:end_header].decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ProtocolError(f"bad JSON header: {exc}") from exc
            payload_len = header.get("bytes", 0)
            if not isinstance(payload_len, int) or payload_len < 0 or payload_len > MAX_PAYLOAD:
                raise ProtocolError(f"invalid payload length {payload_len!r}")
            end_payload = end_header + payload_len
            if len(self._buffer) < end_payload:
                return frames
            payload = bytes(self._buffer[end_header:end_payload])
            del self._buffer[:end_payload]
            frames.append((header, payload))
