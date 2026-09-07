"""Release contract checks: tags, published hashes, and archive completeness."""

import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "release", Path(__file__).resolve().parents[1] / "scripts" / "release.py"
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_tags(self):
        for tag in ("v0.4.0", "v1.2.3-rc.1", "v1.2.3-beta"):
            self.assertEqual(release.version_for(tag), tag[1:])
        for tag in ("main", "1.2.3", "v1.2", "v01.2.3", "v1.2.3-01", "v1.2.3\nsha=bad", 'v1.2.3-"'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.version_for(tag)

    def archives(self, directory, executable=True):
        for platform in release.PLATFORMS:
            with tarfile.open(directory / f"git-weight-{platform}.tar.gz", "w:gz") as archive:
                for name in ("git-weight", "LICENSE", "README.md"):
                    content = f"{platform} {name}".encode()
                    entry = tarfile.TarInfo(name)
                    entry.size = len(content)
                    entry.mode = 0o755 if name == "git-weight" and executable else 0o644
                    archive.addfile(entry, io.BytesIO(content))

    def test_formula_and_checksums_match_all_archives(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.archives(directory)
            release.package("v0.4.0", directory)
            formula = (directory / "git-weight.rb").read_text()
            checksums = (directory / "checksums.txt").read_text().splitlines()
            self.assertEqual(len(checksums), 4)
            for line in checksums:
                digest, name = line.split()
                self.assertEqual(digest, hashlib.sha256((directory / name).read_bytes()).hexdigest())
                self.assertIn(f'/releases/download/v0.4.0/{name}"', formula)
                self.assertIn(f'sha256 "{digest}"', formula)
            self.assertIn('version "0.4.0"', formula)
            self.assertIn('bin.install "git-weight"', formula)

    def test_missing_archive_does_not_generate_formula(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.archives(directory)
            (directory / "git-weight-linux-arm64.tar.gz").unlink()
            with self.assertRaises(FileNotFoundError):
                release.package("v0.4.0", directory)
            self.assertFalse((directory / "git-weight.rb").exists())

    def test_nonexecutable_binary_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.archives(directory, executable=False)
            with self.assertRaisesRegex(ValueError, "not executable"):
                release.package("v0.4.0", directory)


if __name__ == "__main__":
    unittest.main()
