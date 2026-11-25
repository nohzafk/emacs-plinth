"""Exercise dependency locks and archive verification without network access."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "scripts" / "emacs-deps.sh"
ARCHIVE = b"fixture archive bytes\x00\xff\n"
SHA = hashlib.sha256(ARCHIVE).hexdigest()
BASENAME = "dependency.tar.xz"
URL = f"https://example.invalid/releases/{BASENAME}"
SRCDIR = "dependency-1.2"
ENTRY = f"dependency\t{SHA}\t{URL}\t{SRCDIR}"


class DependencyArchives(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.lock = self.root / "fixture.lock"
        self.lock.write_text(f"# Dependency lock fixture\n\n{ENTRY}")
        self.cache = self.root / "archive cache"
        self.archive = self.cache / BASENAME
        self.payload = self.root / "payload"
        self.payload.write_bytes(ARCHIVE)
        self.calls = self.root / "curl-calls"
        mock = self.root / "curl"
        mock.write_text(
            r"""#!/bin/bash
set -eu
printf '%s\n' "$@" >> "$CURL_CALLS"
while [[ "$1" != --output ]]; do shift; done
cat -- "$CURL_PAYLOAD" > "$2"
[[ ! -e "$CURL_ARCHIVE" ]] || exit 98
printf 'mock curl progress\n'
exit "$CURL_STATUS"
"""
        )
        mock.chmod(0o755)
        self.env = {
            **os.environ,
            "BASH_ENV": "",  # A startup file can reorder PATH ahead of the mock.
            "PATH": f"{self.root}:{os.environ['PATH']}",
            "EBUILD_DEPS_LOCK": str(self.lock),
            "CURL_CALLS": str(self.calls),
            "CURL_PAYLOAD": str(self.payload),
            "CURL_ARCHIVE": str(self.archive),
            "CURL_STATUS": "0",
        }

    def run_helper(self, function, *args):
        return subprocess.run(
            [
                "/bin/bash",
                "-euc",
                '[[ "$(command -v curl)" == "$PWD/curl" ]] || exit 99; source "$1"; shift; "$@"',
                "bash",
                str(HELPER),
                function,
                *args,
            ],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )

    def fetch(self, stage="dependency"):
        return self.run_helper("emacs_dep_fetch", stage, self.cache.name)

    def assert_failure(self, result, message=None):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        if message:
            self.assertIn(message, result.stderr)

    def test_default_lock_is_next_to_the_helper(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / HELPER.name).write_bytes(HELPER.read_bytes())
        (scripts / "deps.lock").write_text(ENTRY)
        del self.env["EBUILD_DEPS_LOCK"]
        result = subprocess.run(
            [
                "/bin/bash",
                "-euc",
                "source scripts/emacs-deps.sh; emacs_dep_srcdir dependency",
            ],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, SRCDIR + "\n")

    def test_digest_hashes_raw_lock_and_srcdir_selects_exact_stage(self):
        raw = f"# fixture\r\n\r\ndependency-extra\tbad\r\n{ENTRY}".encode()
        self.lock.write_bytes(raw)
        digest = self.run_helper("emacs_deps_digest")
        self.assertEqual(digest.returncode, 0, digest.stderr)
        self.assertEqual(digest.stdout, hashlib.sha256(raw).hexdigest() + "\n")
        srcdir = self.run_helper("emacs_dep_srcdir", "dependency")
        self.assertEqual(srcdir.returncode, 0, srcdir.stderr)
        self.assertEqual(srcdir.stdout, SRCDIR + "\n")
        self.assertFalse(self.calls.exists())

    def test_fresh_download_publishes_verified_bytes_and_prints_absolute_path(self):
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.archive) + "\n")
        self.assertIn("mock curl progress", result.stderr)
        self.assertEqual(self.calls.read_text().splitlines()[-1], URL)
        self.assertEqual(list(self.cache.iterdir()), [self.archive])
        self.assertEqual(self.archive.read_bytes(), ARCHIVE)

    def test_cached_archive_is_verified_without_curl(self):
        self.cache.mkdir()
        self.archive.write_bytes(ARCHIVE)
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.archive) + "\n")
        self.assertFalse(self.calls.exists())
        self.archive.write_bytes(b"corrupt cache")
        self.assert_failure(self.fetch(), "SHA-256 mismatch")
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.archive.read_bytes(), b"corrupt cache")

    def test_mismatched_download_is_not_published(self):
        self.payload.write_bytes(b"wrong download")
        self.assert_failure(self.fetch(), "SHA-256 mismatch")
        self.assertTrue(self.calls.exists())
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_failed_download_is_not_published_even_with_matching_bytes(self):
        self.env["CURL_STATUS"] = "18"
        self.assert_failure(self.fetch())
        self.assertTrue(self.calls.exists())
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_missing_and_duplicate_stages_fail_before_curl(self):
        self.assert_failure(self.fetch("absent"), "missing stage")
        self.lock.write_text(f"{ENTRY}\n{ENTRY}\n")
        self.assert_failure(self.fetch(), "ambiguous stage")
        self.assertFalse(self.calls.exists())

    def test_malformed_selected_rows_fail_before_curl(self):
        for bad in (
            "dependency",
            f"dependency\t{SHA}\t{URL}",
            f"{ENTRY}\t",
            f"dependency\t\t{SHA}\t{URL}\t{SRCDIR}",
            ENTRY.replace(SHA, SHA.upper()),
            ENTRY.replace("https:", "http:"),
            ENTRY.replace(URL, "https://example.invalid"),
            ENTRY.replace(URL, "https://example.invalid/releases/.."),
            ENTRY.replace(SRCDIR, "../dependency-1.2"),
        ):
            with self.subTest(bad=bad):
                self.lock.write_text(bad + "\n")
                self.assert_failure(self.fetch(), "malformed entry")
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
