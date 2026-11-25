import hashlib
import io
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MARKER = "ebuild-deps.txt"


def prepare_local_build(tmp_path):
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    for name in ("build.sh", "deps.lock", "emacs-source.lock"):
        shutil.copy(ROOT / "scripts" / name, scripts)
    for helper in (ROOT / "scripts").glob("emacs-*.sh"):
        shutil.copy(helper, scripts)
    shutil.copytree(ROOT / "patches", tmp_path / "patches")
    commands = tmp_path / "bin"
    commands.mkdir()
    for name, body in {
        "git": "exit 99\n",
        "make": 'printf "%s\\n" make >> "$TRACE"\n',
        "curl": r"""printf '%s\n' curl >> "$TRACE"
while [[ $# -gt 0 && "$1" != --output ]]; do shift; done
[[ "$#" == 4 && "$3" == -- && "$4" == "$FIXTURE_URL" ]] || exit 99
cp "$FIXTURE_ARCHIVE" "$2"
""",
    }.items():
        tool = commands / name
        tool.write_text(f"#!/bin/bash\nset -eu\n{body}")
        tool.chmod(0o755)
    (scripts / "emacs-sign.sh").write_text(
        'emacs_verify_bundle() { printf "%s\\n" verify >> "$TRACE"; }\n'
    )
    env = {
        "PATH": f"{commands}{os.pathsep}{os.defpath}",
        "JOBS": "1",
        "TRACE": str(tmp_path / "trace"),
        "PREFIX": str(tmp_path / "custom prefix"),
        "WORK": str(tmp_path / "custom work"),
        "OUT": str(tmp_path / "custom output" / "Emacs.app"),
    }

    def run(stage="no-stage", **overrides):
        return subprocess.run(
            ["/bin/bash", str(scripts / "build.sh"), stage],
            check=False,
            cwd=tmp_path,
            env=env | overrides,
            capture_output=True,
            text=True,
        )

    return run, env, scripts


def dep_marker(lock):
    return f"{hashlib.sha256(lock.read_bytes()).hexdigest()}\n"


class LocalDepsCacheTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.tmp_path = Path(directory.name)
        self.local_build = prepare_local_build(self.tmp_path)

    def test_default_paths_change_with_whole_lock(self):
        run, _, scripts = self.local_build
        tmp_path = self.tmp_path
        lock = scripts / "deps.lock"
        for _ in range(2):
            digest = dep_marker(lock)
            result = run(PREFIX="", WORK="", OUT="")
            self.assertEqual(result.returncode, 0, result.stderr)
            cache = tmp_path / "build" / f"deps-{digest.strip()}"
            self.assertEqual((cache / "prefix" / MARKER).read_text(), digest)
            self.assertEqual((cache / "work" / MARKER).read_text(), digest)
            self.assertIn(f"{cache}/emacs-31-snapshot-", result.stdout)
            with lock.open("a") as stream:
                stream.write("# Changes the whole-lock digest, not any stage\n")

    def test_relative_paths_refer_to_invoking_directory(self):
        run, _, scripts = self.local_build
        elsewhere = self.tmp_path / "search path"
        elsewhere.mkdir()
        (elsewhere / "work").mkdir()
        result = run(
            WORK="work", PREFIX="prefix", OUT="app/Emacs.app", CDPATH=str(elsewhere)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("work", "prefix"):
            self.assertEqual(
                (self.tmp_path / name / MARKER).read_text(),
                dep_marker(scripts / "deps.lock"),
            )
        self.assertIn(f"{self.tmp_path.resolve()}/app/Emacs.app", result.stdout)
        self.assertEqual(list((elsewhere / "work").iterdir()), [])

    def test_preserves_nonempty_unmarked_or_mismatched_cache(self):
        for kind in ("PREFIX", "WORK"):
            for payload in (None, "0" * 64 + "\n"):
                with (
                    self.subTest(kind=kind, payload=payload),
                    tempfile.TemporaryDirectory(dir=self.tmp_path) as case,
                ):
                    self.check_cache_rejection(Path(case), kind, payload)

    def check_cache_rejection(self, case, kind, payload):
        run, env, _ = self.local_build
        overrides = {name: str(case / name) for name in ("PREFIX", "WORK")}
        env = env | overrides
        cache = Path(env[kind])
        cache.mkdir()
        (cache / ".keep").write_text("cache data")
        marker = cache / MARKER
        if payload is not None:
            marker.write_text(payload)
        result = run(**overrides)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"use a fresh {kind} path", result.stderr)
        self.assertEqual((cache / ".keep").read_text(), "cache data")
        self.assertEqual((marker.read_text() if marker.exists() else None), payload)
        self.assertFalse(Path(env["WORK" if kind == "PREFIX" else "PREFIX"]).exists())

    def test_local_stage_verifies_fresh_and_cached_archive_before_reusing_source(self):
        run, env, scripts = self.local_build
        tmp_path = self.tmp_path
        archive = tmp_path / "fixture.tar.gz"
        configure = b'#!/bin/bash\nprintf "%s\\n" configure >> "$TRACE"\n'
        with tarfile.open(archive, "w:gz") as tar:
            member = tarfile.TarInfo("locked-source/configure")
            member.size = len(configure)
            member.mode = 0o755
            tar.addfile(member, io.BytesIO(configure))
        url = "https://example.invalid/chosen-name.tar.gz"
        lock = scripts / "deps.lock"
        lock.write_text(
            f"m4\t{hashlib.sha256(archive.read_bytes()).hexdigest()}\t{url}\tlocked-source\n"
        )
        search = tmp_path / "search"
        alternate = search / Path(env["WORK"]).name
        alternate.mkdir(parents=True)
        overrides = {
            "FIXTURE_ARCHIVE": str(archive),
            "FIXTURE_URL": url,
            "WORK": Path(env["WORK"]).name,
            "CDPATH": str(search),
        }
        Path(env["WORK"]).mkdir()  # An existing empty override is eligible.
        result = run("m4", **overrides)
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = Path(env["TRACE"])
        self.assertEqual(
            trace.read_text().splitlines(), ["curl", "configure", "make", "make"]
        )
        self.assertEqual((Path(env["PREFIX"]) / MARKER).read_text(), dep_marker(lock))
        cached = Path(env["WORK"]) / "chosen-name.tar.gz"
        self.assertEqual(cached.read_bytes(), archive.read_bytes())
        self.assertTrue((cached.parent / "locked-source" / "configure").is_file())
        self.assertEqual(list(alternate.iterdir()), [])

        result = run("m4", **overrides)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected_trace = ["curl"] + ["configure", "make", "make"] * 2
        self.assertEqual(trace.read_text().splitlines(), expected_trace)

        cached.write_bytes(b"unverified bytes")
        result = run("m4", **overrides)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertEqual(trace.read_text().splitlines(), expected_trace)
        self.assertEqual(cached.read_bytes(), b"unverified bytes")

        sentinel = Path(env["PREFIX"]) / "bin" / "m4"
        sentinel.parent.mkdir()
        sentinel.touch()
        result = run("m4", **overrides)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already built", result.stdout)
        self.assertEqual(trace.read_text().splitlines(), expected_trace)

    def test_cached_app_requires_matching_marker_before_signature_verification(self):
        run, env, scripts = self.local_build
        app = Path(env["OUT"])
        binary = app / "Contents" / "MacOS" / "Emacs"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"existing app")
        marked = subprocess.run(
            [
                "/bin/bash",
                "-eu",
                "-c",
                (
                    'source "$1/emacs-source.sh"; source "$1/emacs-patches.sh"; '
                    'source "$1/emacs-configure.sh"; emacs_mark_output "$OUT"; '
                    'emacs_mark_patches "$OUT"; emacs_mark_configuration "$OUT" "$PREFIX"'
                ),
                "bash",
                str(scripts),
            ],
            check=False,
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(marked.returncode, 0, marked.stderr)
        marker = app / "Contents" / "Resources" / MARKER
        trace = Path(env["TRACE"])
        for payload in (None, "0" * 64 + "\n"):
            if payload is not None:
                marker.write_text(payload)
            result = run("emacs")
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("use a fresh OUT path", result.stderr)
            self.assertEqual(binary.read_bytes(), b"existing app")
            self.assertFalse(trace.exists())
        marker.write_text(dep_marker(scripts / "deps.lock"))
        result = run("emacs")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already built", result.stdout)
        self.assertEqual(trace.read_text().splitlines(), ["verify"])

    def test_bundle_dependency_marker_precedes_signing(self):
        stage = (
            (ROOT / "scripts" / "build.sh").read_text().split("stage_emacs() {", 1)[1]
        )
        self.assertLess(
            stage.index('"$DEPS_DIGEST" > "$deps_marker"'),
            stage.index('emacs_sign_bundle "$OUT"'),
        )


if __name__ == "__main__":
    unittest.main()
