import os
import shutil
import unittest

from pearl_tts.backends import SayBackend, backend_candidates
from pearl_tts.config import Settings


class Defaults(unittest.TestCase):
    def test_auto_order(self):
        self.assertEqual(backend_candidates(Settings()), ["kokoro", "piper", "say"])

    def test_forced_backend(self):
        self.assertEqual(backend_candidates(Settings(backend="say")), ["say"])

    def test_unknown_backend(self):
        with self.assertRaises(Exception):
            backend_candidates(Settings(backend="nope"))

    def test_settings_paths(self):
        settings = Settings()
        self.assertTrue(str(settings.resolved_kokoro_model()).endswith("kokoro-v1.0.onnx"))
        self.assertTrue(str(settings.resolved_socket()).endswith("tts.sock"))


@unittest.skipUnless(shutil.which("say"), "macOS say not available")
class SayFallback(unittest.TestCase):
    def test_say_produces_24k_pcm(self):
        backend = SayBackend(Settings())
        pcm, rate = backend.synthesize("Testing Pearl.", "Samantha", 1.0)
        self.assertGreater(len(pcm), 2000)
        self.assertEqual(rate, 24000)

    def test_warmup_returns_timing(self):
        backend = SayBackend(Settings())
        elapsed = backend.warmup("Samantha", 1.0)
        self.assertGreaterEqual(elapsed, 0.0)


if __name__ == "__main__":
    unittest.main()
