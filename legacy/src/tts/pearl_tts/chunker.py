"""Streaming clause chunker: LLM tokens in, speakable clauses out.

The chunker is deliberately independent of any TTS engine.  It turns a token
stream into small, natural-sounding units so that synthesis can begin long
before the model has finished generating.  Getting this layer right is worth
100-250 ms of time-to-first-audio on a 1.5B local model.

Design rules
------------
1. Terminal punctuation (``. ! ? …``) closes a chunk as soon as it is followed
   by whitespace.  Short sentences such as "Yes." are therefore spoken at once
   instead of waiting for the next sentence.
2. Clause punctuation (``, ; : —``) closes a chunk only after a soft minimum
   length, which avoids choppy "Sure," / "User," fragments.
3. Abbreviations, decimals, initials and ellipses never split.
4. Fenced Markdown code is not spoken (it is unlistenable and often huge).
   Inline code keeps its text; links keep their label; bare URLs become "link".
5. A hard maximum prevents a punctuation-free monologue from delaying audio
   forever.
6. The first chunk uses lower thresholds than later chunks.  That is the whole
   point: get *something* into the synthesizer within tens of milliseconds.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

__all__ = ["ChunkerConfig", "StreamingChunker", "chunk_text"]

_TERMINAL = ".!?…"
_CLAUSE = ",;:—"
_OPENERS = "\"'([{“‘"
_CLOSERS = "\"')]}”’"

# Words that end in a period but rarely end a sentence.
_ABBREVIATIONS = frozenset(
    {
        "mr", "mrs", "ms", "mx", "dr", "prof", "sr", "jr", "st", "mt",
        "vs", "etc", "eg", "ie", "cf", "al", "approx", "est", "fig",
        "no", "nos", "inc", "ltd", "co", "corp", "dept", "univ", "assn",
        "ave", "blvd", "rd", "apt", "ste", "gov", "sen", "rep", "gen",
        "col", "capt", "lt", "sgt", "rev", "hon", "pres",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept",
        "oct", "nov", "dec", "mon", "tue", "tues", "wed", "thu", "thur",
        "thurs", "fri", "sat", "sun",
        "min", "max", "avg", "std", "temp", "vol", "dept",
    }
)

# Multi-dot abbreviations ("e.g.", "U.S.") handled separately.
_MULTIDOT_ABBREVIATIONS = frozenset({"e.g", "i.e", "u.s", "u.k", "a.m", "p.m", "ph.d"})

_EMOJI_RE = re.compile(
    "[" + "".join(
        [
            "\U0001F000-\U0001FAFF",  # emoji & pictographs
            "\U00002600-\U000027BF",  # misc symbols / dingbats
            "\U0000FE00-\U0000FE0F",  # variation selectors
            "\U0001F1E6-\U0001F1FF",  # regional indicators
            "\U0000200D",             # ZWJ
        ]
    ) + "]"
)


@dataclass(frozen=True)
class ChunkerConfig:
    """Tuning knobs.  Defaults are optimized for conversational replies."""

    # A sentence may be emitted at any length >= this.
    sentence_min_chars: int = 2
    # A clause split needs this many characters, except for the first chunk.
    clause_min_chars: int = 28
    # The very first clause split may happen earlier.
    first_clause_min_chars: int = 16
    # Never emit a chunk longer than this without trying to split it.
    max_chars: int = 220
    # Hard floor: chunks shorter than this are always merged forward.
    absolute_min_chars: int = 2
    # "skip" drops fenced code; "announce" speaks a short placeholder once.
    code_policy: str = "skip"
    # Render Markdown for speech (strip emphasis markers, headings, bullets).
    clean_markdown: bool = True
    # Replace bare URLs with this word so Pearl does not read out query strings.
    url_placeholder: str = "link"

    def __post_init__(self) -> None:
        if self.code_policy not in ("skip", "announce"):
            raise ValueError("code_policy must be 'skip' or 'announce'")
        if self.max_chars < 8:
            raise ValueError("max_chars must be >= 8")


class StreamingChunker:
    """Stateful chunker.  Feed arbitrary text fragments, receive clauses.

    ``feed()`` may be called with tokens, words, lines or whole documents.  It
    returns a (possibly empty) list of ready-to-synthesize strings.  Call
    ``flush()`` at end-of-stream to drain the tail.
    """

    def __init__(self, config: ChunkerConfig | None = None) -> None:
        self.config = config or ChunkerConfig()
        self._buf = ""
        self._in_code = False
        self._just_opened_code = False
        self._skipped_code_block = False
        self._emitted_any = False
        self._pending_announcement = False

    # ------------------------------------------------------------------ API
    def feed(self, text: str) -> list[str]:
        if not text:
            return []
        self._buf += self._sanitize(text)
        return self._drain(final=False)

    def flush(self) -> list[str]:
        return self._drain(final=True)

    @property
    def pending(self) -> str:
        """Text currently buffered (useful for tests / debugging)."""
        return self._buf

    # ------------------------------------------------------------- sanitize
    def _sanitize(self, text: str) -> str:
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        text = unicodedata.normalize("NFKC", text)

        out: list[str] = []
        i = 0
        n = len(text)
        while i < n:
            if text.startswith("```", i):
                self._in_code = not self._in_code
                i += 3
                if self._in_code:
                    self._just_opened_code = True
                    self._skipped_code_block = True
                    # Drop the language tag that follows the opening fence.
                    nl = text.find("\n", i)
                    i = n if nl == -1 else nl + 1
                else:
                    # Drop a trailing newline immediately after the fence.
                    if i < n and text[i] == "\n":
                        i += 1
                    if self.config.code_policy == "announce":
                        self._pending_announcement = True
                continue

            ch = text[i]
            i += 1
            if self._in_code:
                continue

            if self._just_opened_code and ch in " \t":
                # Already consumed language tag above; keep this branch for
                # fences that are immediately followed by code on the same line.
                continue
            self._just_opened_code = False
            out.append(ch)

        s = "".join(out)
        if not s:
            return ""

        if self.config.clean_markdown:
            # Markdown links -> label, then bare URLs -> placeholder.
            s = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", s)
            s = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", s)
            s = re.sub(r"https?://\S+", f" {self.config.url_placeholder} ", s)
            s = re.sub(r"www\.\S+", f" {self.config.url_placeholder} ", s)
            # Emphasis / inline code markers.  Keep the prose inside.
            s = re.sub(r"\*\*([^*]+)\*\*", r"\1", s)
            s = re.sub(r"__([^_]+)__", r"\1", s)
            s = re.sub(r"(?<!\w)\*([^*\n]+)\*(?!\w)", r"\1", s)
            s = re.sub(r"(?<!\w)_([^_\n]+)_(?!\w)", r"\1", s)
            s = s.replace("`", "")
            # Headings & list bullets at line starts.
            s = re.sub(r"(?m)^[ \t]{0,3}#{1,6}[ \t]*", "", s)
            s = re.sub(r"(?m)^[ \t]*[-*+•][ \t]+", "", s)
            # Blockquotes.
            s = re.sub(r"(?m)^[ \t]*>[ \t]?", "", s)
            # Table separators are not speech.
            s = re.sub(r"(?m)^[ \t]*\|?[ \t:|-]{4,}\|?[ \t]*$", "", s)

        s = _EMOJI_RE.sub("", s)
        # Curly quotes/dashes to ASCII for stable prosody and matching.
        s = (
            s.replace("“", '"').replace("”", '"')
            .replace("‘", "'").replace("’", "'")
            .replace("—", "-").replace("–", "-")
        )
        # Collapse runs of spaces/tabs but preserve newlines as boundaries.
        s = re.sub(r"[ \t\f\v]+", " ", s)
        s = re.sub(r"\n{2,}", "\n", s)
        return s

    # --------------------------------------------------------------- drain
    def _drain(self, final: bool) -> list[str]:
        chunks: list[str] = []

        while True:
            if self._pending_announcement and not self._in_code:
                # Emit the placeholder before whatever prose follows the block.
                self._pending_announcement = False
                if self._buf.strip():
                    chunks.append("I've put that code on screen.")
                    self._emitted_any = True

            boundary = self._find_boundary(final)
            if boundary is not None:
                cut, _kind = boundary
                raw, self._buf = self._buf[:cut], self._buf[cut:]
                clean = self._clean(raw)
                if clean:
                    chunks.append(clean)
                    self._emitted_any = True
                continue

            # No boundary.  Enforce the hard maximum.
            if len(self._buf) > self.config.max_chars:
                cut = self._hard_cut()
                raw, self._buf = self._buf[:cut], self._buf[cut:]
                clean = self._clean(raw)
                if clean:
                    chunks.append(clean)
                    self._emitted_any = True
                continue
            break

        if final:
            if self._in_code:
                # Unterminated fence: treat the tail as code, not prose.
                self._buf = ""
            if self._pending_announcement and not self._buf.strip():
                self._pending_announcement = False
            clean = self._clean(self._buf)
            self._buf = ""
            if clean:
                chunks.append(clean)

        return chunks

    # ------------------------------------------------------------ boundaries
    def _find_boundary(self, final: bool) -> tuple[int, str] | None:
        s = self._buf
        n = len(s)
        if not n:
            return None

        for i, ch in enumerate(s):
            if ch == "\n":
                need = 1 if not self._emitted_any else self.config.absolute_min_chars
                if len(s[:i].strip()) >= need:
                    return i + 1, "newline"
                continue

            if ch in _TERMINAL:
                # A dot at the very end may be a decimal/abbreviation still
                # being streamed; wait for the next character unless flushing.
                if i == n - 1 and not final:
                    continue
                if i + 1 < n:
                    nxt = s[i + 1]
                    if nxt == ".":
                        # Ellipsis: never split on the first two dots.
                        continue
                    if nxt not in " \n\t" + _CLOSERS:
                        continue
                    if ch == "." and self._is_abbreviation(s, i):
                        continue
                elif ch == "." and self._is_abbreviation(s, i):
                    continue

                end = i + 1
                while end < n and s[end] in _CLOSERS:
                    end += 1
                text_len = len(self._clean(s[:end]))
                # "Well..." is a pause, not a sentence: require a clause-sized
                # buffer before cutting on the final dot of an ellipsis.
                is_ellipsis = ch == "." and i > 0 and s[i - 1] == "."
                need = self.config.sentence_min_chars
                if is_ellipsis:
                    need = (
                        self.config.first_clause_min_chars
                        if not self._emitted_any
                        else self.config.clause_min_chars
                    )
                if text_len >= need:
                    return end, "sentence"
                continue

            if ch in _CLAUSE:
                if i == n - 1 and not final:
                    continue
                if i + 1 < n and s[i + 1] not in " \n\t":
                    continue
                need = (
                    self.config.first_clause_min_chars
                    if not self._emitted_any
                    else self.config.clause_min_chars
                )
                if len(self._clean(s[: i + 1])) >= need:
                    return i + 1, "clause"

        return None

    def _is_abbreviation(self, s: str, dot_index: int) -> bool:
        # Decimal: 3.14, version numbers 1.5B, IPs.
        if dot_index + 1 < len(s) and s[dot_index + 1].isdigit():
            return True
        if dot_index > 0 and s[dot_index - 1].isdigit():
            return True

        prefix = s[:dot_index]
        match = re.search(r"([A-Za-z][A-Za-z.]*)$", prefix)
        if not match:
            return False
        word = match.group(1).rstrip(".").lower()
        if word in _ABBREVIATIONS or word in _MULTIDOT_ABBREVIATIONS:
            return True

        # Single-letter initial such as "J. Smith" or "A. I. research".
        if len(word) == 1 and word.isalpha():
            return True
        return False

    def _hard_cut(self) -> int:
        s = self._buf
        limit = self.config.max_chars
        window = s[:limit]
        # Prefer a clause boundary, then a sentence boundary, then whitespace.
        for punct in (",", ";", ":", ".", "!", "?"):
            idx = window.rfind(punct)
            if idx >= self.config.absolute_min_chars:
                return idx + 1
        idx = window.rfind(" ")
        if idx >= self.config.absolute_min_chars:
            return idx + 1
        return limit

    # -------------------------------------------------------------- cleaning
    @staticmethod
    def _clean(raw: str) -> str:
        text = raw.strip()
        if not text:
            return ""
        text = re.sub(r"\s+", " ", text)
        text = re.sub(r"^[\s,;:.\-]+", "", text)
        text = re.sub(r"\s+([,;:.!?])", r"\1", text)
        if not re.search(r"[A-Za-z0-9]", text):
            return ""
        # A chunk of only punctuation / separators is not worth speaking.
        if len(text) < 1:
            return ""
        return text


def chunk_text(text: str, config: ChunkerConfig | None = None) -> list[str]:
    """Convenience wrapper for non-streaming text."""
    chunker = StreamingChunker(config)
    return chunker.feed(text) + chunker.flush()
