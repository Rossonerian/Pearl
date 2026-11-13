import socket
import unittest

from pearl_tts.protocol import (
    FrameDecoder,
    ProtocolError,
    encode_frame,
    recv_frame,
    send_frame,
)


class Framing(unittest.TestCase):
    def test_roundtrip_control(self):
        a, b = socket.socketpair()
        try:
            send_frame(a, {"t": "hello", "backend": "kokoro"})
            header, payload = recv_frame(b)
            self.assertEqual(header["t"], "hello")
            self.assertEqual(header["backend"], "kokoro")
            self.assertEqual(payload, b"")
        finally:
            a.close()
            b.close()

    def test_roundtrip_audio(self):
        a, b = socket.socketpair()
        pcm = bytes(range(256)) * 20
        try:
            send_frame(a, {"t": "audio", "seq": 3, "sr": 24000}, pcm)
            header, payload = recv_frame(b)
            self.assertEqual(header["t"], "audio")
            self.assertEqual(header["seq"], 3)
            self.assertEqual(header["bytes"], len(pcm))
            self.assertEqual(payload, pcm)
        finally:
            a.close()
            b.close()

    def test_encode_is_deterministic(self):
        encoded = encode_frame({"t": "ok", "id": "x"}, b"abc")
        self.assertIn(b'"t":"ok"', encoded)
        self.assertTrue(encoded.endswith(b"abc"))

    def test_decoder_incremental(self):
        frames = [
            encode_frame({"t": "a"}, b"one"),
            encode_frame({"t": "b", "bytes": 0}),
            encode_frame({"t": "c"}, b"three"),
        ]
        blob = b"".join(frames)
        decoder = FrameDecoder()
        seen = []
        for i in range(0, len(blob), 3):
            seen.extend(decoder.feed(blob[i:i + 3]))
        self.assertEqual([h["t"] for h, _ in seen], ["a", "b", "c"])
        self.assertEqual([p for _, p in seen], [b"one", b"", b"three"])

    def test_rejects_oversized_header(self):
        a, b = socket.socketpair()
        try:
            a.sendall(b"\x7f\xff\xff\xff")
            with self.assertRaises(ProtocolError):
                recv_frame(b)
        finally:
            a.close()
            b.close()


if __name__ == "__main__":
    unittest.main()
