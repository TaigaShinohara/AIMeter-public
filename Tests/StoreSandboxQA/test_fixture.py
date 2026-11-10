"""Synthetic-only tests; each case owns all paths it creates."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock
import uuid


SCRIPT = Path(__file__).with_name("fixture.py")
SPEC = importlib.util.spec_from_file_location("store_sandbox_qa_fixture", SCRIPT)
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


class FixtureControllerTests(unittest.TestCase):
    def setUp(self):
        self.root = "/private/tmp/aimeter-store-sandbox-qa-" + uuid.uuid4().hex
        self.held = self.root + "-test-held"

    def create_owned_fixture(self):
        fixture.create_fixture(self.root)

    def test_fifo_marker_fails_without_blocking(self):
        self.create_owned_fixture()
        marker = os.path.join(self.root, ".fixture")
        os.unlink(marker)
        os.mkfifo(marker, 0o600)
        result = subprocess.run([sys.executable, str(SCRIPT), "replace-root", self.root],
                                capture_output=True, timeout=3, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr.strip(), b"FIXTURE_OPERATION_FAILED")
        self.assertTrue(os.path.isdir(os.path.join(self.root, "base", "selected")))

    def test_existing_destination_is_never_overwritten(self):
        self.create_owned_fixture()
        base = Path(self.root) / "base"
        existing = base / "kept-selected"
        existing.mkdir()
        (existing / "keep.txt").write_bytes(b"synthetic-existing")
        with self.assertRaises(OSError):
            fixture.replace(self.root, "root")
        self.assertEqual((existing / "keep.txt").read_bytes(), b"synthetic-existing")
        self.assertTrue((base / "selected").is_dir())
        self.assertFalse((base / "selected").is_symlink())

    def test_symlink_root_is_rejected(self):
        self.create_owned_fixture()
        os.rename(self.root, self.held)
        os.symlink(self.held, self.root)
        with self.assertRaises((OSError, ValueError)):
            fixture.checked_root(self.root)
        self.assertTrue(os.path.isdir(os.path.join(self.held, "base", "selected")))

    def test_root_swap_between_stat_and_open_is_rejected(self):
        self.create_owned_fixture()
        original_open = fixture.open_dir
        name = os.path.basename(self.root)

        def swap(parent_fd, child):
            if child == name:
                os.rename(self.root, self.held)
                os.mkdir(self.root, 0o700)
            return original_open(parent_fd, child)

        with mock.patch.object(fixture, "open_dir", side_effect=swap):
            with self.assertRaises(ValueError):
                fixture.checked_root(self.root)
        self.assertTrue(os.path.isdir(os.path.join(self.held, "base", "selected")))


if __name__ == "__main__":
    unittest.main()
