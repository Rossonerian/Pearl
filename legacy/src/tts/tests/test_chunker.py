import unittest

from pearl_tts.chunker import ChunkerConfig, StreamingChunker, chunk_text


class ChunkerBasics(unittest.TestCase):
    def test_first_sentence_is_small_and_fast(self):
        chunks = chunk_text("Sure, User. Let me check that for you.")
        self.assertEqual(chunks[0], "Sure, User.")
        self.assertEqual(chunks[-1], "Let me check that for you.")

    def test_short_sentence_is_not_glued_to_next(self):
        chunks = chunk_text("Yes. Absolutely.")
        self.assertEqual(chunks, ["Yes.", "Absolutely."])

    def test_clause_split_only_after_soft_minimum(self):
        chunks = chunk_text("One moment, User.")
        # "One moment," is below the first clause threshold; keep it whole.
        self.assertEqual(chunks, ["One moment, User."])

    def test_decimal_and_version_do_not_split(self):
        chunks = chunk_text("The value is 3.14 in version 1.5B today.")
        self.assertEqual(len(chunks), 1)
        self.assertIn("3.14", chunks[0])

    def test_abbreviations_do_not_split(self):
        text = "Dr. Smith met Mrs. Jones at 9 a.m. near the U.S. embassy."
        chunks = chunk_text(text)
        joined = " ".join(chunks)
        self.assertEqual(joined.replace("  ", " "), text)

    def test_initials_do_not_split(self):
        chunks = chunk_text("J. R. Tolkien wrote it. It is famous.")
        self.assertEqual(chunks[0], "J. R. Tolkien wrote it.")
        self.assertEqual(len(chunks), 2)

    def test_ellipsis_is_one_boundary(self):
        chunks = chunk_text("Well... that is interesting. Let us continue.")
        self.assertEqual(chunks[0], "Well... that is interesting.")

    def test_code_fence_is_skipped(self):
        text = "Here is the code:\n```python\nprint('hi')\n```\nDone."
        chunks = chunk_text(text)
        speech = " ".join(chunks)
        self.assertNotIn("print", speech)
        self.assertNotIn("```", speech)
        self.assertIn("Here is the code", speech)
        self.assertIn("Done.", speech)

    def test_code_announce_policy(self):
        cfg = ChunkerConfig(code_policy="announce")
        chunks = chunk_text("Look:\n```js\nlet x = 1\n```\nThat works.", cfg)
        self.assertTrue(any("code on screen" in c for c in chunks))

    def test_markdown_is_rendered_for_speech(self):
        chunks = chunk_text("**Great** work, [User](https://example.com)!")
        self.assertEqual(chunks, ["Great work, User!"])

    def test_urls_become_placeholder(self):
        chunks = chunk_text("Open https://example.com/a?b=c now.")
        self.assertIn("link", chunks[0].lower())
        self.assertNotIn("example.com", chunks[0])

    def test_emoji_is_removed(self):
        chunks = chunk_text("Nice work 🎉🚀 User.")
        self.assertNotIn("🎉", chunks[0])
        self.assertIn("Nice work", chunks[0])

    def test_hard_maximum(self):
        cfg = ChunkerConfig(max_chars=40)
        chunks = chunk_text("a" * 200, cfg)
        self.assertGreaterEqual(len(chunks), 5)
        self.assertTrue(all(len(c) <= 40 for c in chunks))

    def test_no_empty_chunks(self):
        chunks = chunk_text("!!! ... ,,, Hello. ...")
        self.assertTrue(chunks)
        self.assertTrue(all(c.strip() for c in chunks))

    def test_bullets_and_headings(self):
        chunks = chunk_text("## Status\n- Battery is fine\n- Build is green")
        speech = " ".join(chunks)
        self.assertNotIn("#", speech)
        self.assertNotIn("- ", speech)
        self.assertIn("Battery is fine", speech)

    def test_empty_and_whitespace(self):
        self.assertEqual(chunk_text(""), [])
        self.assertEqual(chunk_text("   \n\t  "), [])
        self.assertEqual(chunk_text("```\ncode only\n```"), [])


class StreamingEquivalence(unittest.TestCase):
    def test_char_by_char_matches_whole_text(self):
        text = (
            "Sure, User. I'll check the Axiom pull request, then update your "
            "calendar. The build is clean; no failing tests. Anything else?"
        )
        whole = chunk_text(text)
        chunker = StreamingChunker()
        streamed = []
        for ch in text:
            streamed.extend(chunker.feed(ch))
        streamed.extend(chunker.flush())
        self.assertEqual(streamed, whole)

    def test_word_by_word_matches_whole_text(self):
        text = "Dr. Smith has 3.14 dollars. That is odd, but fine. Next item."
        whole = chunk_text(text)
        chunker = StreamingChunker()
        streamed = []
        for word in text.split(" "):
            streamed.extend(chunker.feed(word + " "))
        streamed.extend(chunker.flush())
        self.assertEqual(streamed, whole)

    def test_flush_drains_short_tail(self):
        chunker = StreamingChunker()
        self.assertEqual(chunker.feed("Hello"), [])
        self.assertEqual(chunker.flush(), ["Hello"])


if __name__ == "__main__":
    unittest.main()
