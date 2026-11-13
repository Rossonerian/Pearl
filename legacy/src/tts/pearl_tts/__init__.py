"""Pearl V2 local streaming speech stack.

Public modules:

* ``pearl_tts.chunker``  — token stream -> speakable clauses
* ``pearl_tts.engine``   — warm local TTS daemon (Kokoro/Piper/say)
* ``pearl_tts.client``   — `pearl-tts` CLI, playback pipeline and benchmarks
* ``pearl_tts.protocol`` — tiny length-prefixed PCM socket protocol
* ``pearl_tts.config``   — JSON/env settings shared with the Swift app
"""

__version__ = "2.0.0-m1"
