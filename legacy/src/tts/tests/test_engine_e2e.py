import os
import tempfile
import unittest
from pathlib import Path

from pearl_tts.client import TTSClient, ensure_engine, stop_engine
from pearl_tts.config import Settings


@unittest.skipUnless(os.environ.get("PEARL_TTS_E2E"), "set PEARL_TTS_E2E=1 to run")
class EngineOverSocket(unittest.TestCase):
    """End-to-end check with the degraded say backend (no model download)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        os.environ["PEARL_TTS_BACKEND"] = "say"
        os.environ["PEARL_TTS_SOCKET"] = str(root / "tts.sock")
        os.environ["PEARL_TTS_IDLE_TIMEOUT"] = "20"
        os.environ["PEARL_TTS_METRICS"] = str(root / "metrics.jsonl")
        cls.settings = Settings(
            backend="say",
            socket_path=str(root / "tts.sock"),
            pid_file=str(root / "tts.pid"),
            log_file=str(root / "engine.log"),
            metrics_file=str(root / "metrics.jsonl"),
            idle_timeout=20.0,
            voice="Samantha",
        )

    @classmethod
    def tearDownClass(cls):
        stop_engine(cls.settings)
        cls.tmp.cleanup()
        for key in ("PEARL_TTS_BACKEND", "PEARL_TTS_SOCKET",
                    "PEARL_TTS_IDLE_TIMEOUT", "PEARL_TTS_METRICS"):
            os.environ.pop(key, None)

    def test_hello_and_speech(self):
        hello = ensure_engine(self.settings, start_timeout=30.0)
        self.assertEqual(hello["backend"], "say")
        self.assertTrue(hello["degraded"])

        client = TTSClient(self.settings)
        client.connect(start_timeout=20.0)
        try:
            pcm, rate, meta = client.speak_collect("Hello User.")
            self.assertEqual(rate, 24000)
            self.assertGreater(len(pcm), 4000)
            self.assertGreater(meta["first_frame_ms"], 0.0)
        finally:
            client.close()

    def test_cache_hit_for_short_phrase(self):
        client = TTSClient(self.settings)
        client.connect(start_timeout=20.0)
        try:
            first = client.speak_collect("Cached phrase.")
            second = client.speak_collect("Cached phrase.")
            self.assertEqual(first[0], second[0])
        finally:
            client.close()


if __name__ == "__main__":
    unittest.main()
