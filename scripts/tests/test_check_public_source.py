import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("public_check", Path(__file__).parents[1] / "check_public_source.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class PublicSourceTests(unittest.TestCase):
    def test_detects_disclosure_without_echoing_value(self):
        sensitive = ("/" + "Users/" + "private-user/" + "project").encode()
        self.assertIn("absolute home directory", check.findings("source.swift", sensitive))
        self.assertNotIn(sensitive.decode(), "\n".join(check.findings("source.swift", sensitive)))
        key = ("gh" + "p_" + "a" * 36).encode()
        self.assertIn("GitHub token", check.findings("source.swift", key))
        self.assertNotIn(key.decode(), "\n".join(check.findings("source.swift", key)))

    def test_rejects_private_files_and_accepts_synthetic_fixtures(self):
        self.assertTrue(check.findings("dist/signature.txt", b"example"))
        self.assertTrue(check.findings(".env.local", b"example"))
        self.assertEqual(check.findings("Tests/Fixtures/sample.json", b'{"id":"fixture-root","email":"person@example.com"}'), [])

    def test_flags_screenshot_metadata(self):
        png = b"\x89PNG\r\n\x1a\n" + (0).to_bytes(4, "big") + b"tEXt" + b"\0" * 4
        self.assertIn("screenshot text or EXIF metadata", check.findings("docs/images/demo.png", png))


if __name__ == "__main__":
    unittest.main()
