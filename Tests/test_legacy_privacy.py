"""No real home or credentials; verify data minimization and create-time ACLs."""
from contextlib import redirect_stdout
import ctypes
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/update_usage.py"
spec = importlib.util.spec_from_file_location("legacy_privacy", SCRIPT)
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)


class LegacyPrivacyTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="aimeter-synthetic-privacy-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def test_unknown_fields_and_status_never_enter_snapshot_or_stdout(self):
        path = self.root / ".ai_meter_usage.json"
        canary = "SYNTHETIC_PRIVATE_CANARY"
        path.write_text(json.dumps({"providers": {
            "custom": {"usedByPeriod": {"30d": 7, "unexpected": canary},
                       "status": canary, "access_token": canary},
            canary: {"usedByPeriod": {"30d": 9}}
        }}))
        output = io.StringIO()
        with mock.patch.object(Path, "home", side_effect=AssertionError("Real home forbidden")):
            with redirect_stdout(output):
                legacy.main(home=self.root)
        self.assertEqual(output.getvalue(), "[AIMeter] Local usage snapshot updated.\n")
        self.assertNotIn(str(self.root), output.getvalue())
        self.assertNotIn(canary, path.read_text())
        saved = json.loads(path.read_text())
        self.assertEqual(saved["providers"]["custom"]["usedByPeriod"], {"30d": 7})
        self.assertEqual(path.stat().st_mode & 0o7777, 0o600)

    def test_cli_failure_does_not_print_a_traceback_or_home_path(self):
        (self.root / ".ai_meter_usage.json").mkdir()
        result = subprocess.run([sys.executable, str(SCRIPT)], cwd=self.root,
                                env={"HOME": str(self.root), "TMPDIR": str(self.root),
                                     "PATH": "/usr/bin:/bin", "LANG": "C"},
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "[AIMeter] Local usage refresh failed.\n")
        self.assertNotIn(str(self.root), result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_provider_keys_reject_free_text_and_preserve_generated_identifiers(self):
        permitted = ("custom", "custom_1234", "custom_abcdef", "custom_abcdef_1234", "claude_1a2b")
        rejected = ("custom_synthetic-private-canary", "claude_account-name", "grokbot_deadbeef",
                    "custom_abcdef_hyphen", "custom_PRIVATE", "other_1234", "custom_abcdef_12345")
        for key in permitted:
            self.assertTrue(legacy.known_provider_id(key), key)
        for key in rejected:
            self.assertFalse(legacy.known_provider_id(key), key)
        path = self.root / ".ai_meter_usage.json"
        path.write_text(json.dumps({"providers": {
            key: {"usedByPeriod": {"30d": 7}, "status": "Pro"} for key in permitted + rejected
        }}))
        output = io.StringIO()
        with mock.patch.object(Path, "home", side_effect=AssertionError("Real home forbidden")), redirect_stdout(output):
            legacy.main(home=self.root)
        saved = json.loads(path.read_text())
        for key in permitted:
            self.assertEqual(saved["providers"][key]["usedByPeriod"], {"30d": 7})
        for key in rejected:
            self.assertNotIn(key, saved["providers"])
            self.assertNotIn(key, path.read_text())
            self.assertNotIn(key, output.getvalue())

    def test_storage_failure_keeps_old_snapshot_and_prints_no_success(self):
        path = self.root / ".ai_meter_usage.json"
        previous = b'{"providers":{}}'
        path.write_bytes(previous)
        output = io.StringIO()
        with mock.patch.object(legacy, "create_private_snapshot_file", side_effect=legacy.InputFailure("Synthetic")):
            with redirect_stdout(output), self.assertRaises(legacy.InputFailure):
                legacy.main(home=self.root)
        self.assertEqual(path.read_bytes(), previous)
        self.assertEqual(output.getvalue(), "")
        self.assertFalse(list(self.root.glob("*.tmp")))

    @unittest.skipUnless(sys.platform == "darwin", "Darwin create-time ACL contract")
    def test_inherited_read_acl_is_not_granted_to_snapshot(self):
        parent = self.root / "inherited"
        parent.mkdir(mode=0o700)
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,file_inherit,only_inherit", str(parent)],
                       check=True, capture_output=True)
        control = parent / "control"
        control.write_bytes(b"synthetic")
        lib = ctypes.CDLL(None, use_errno=True)
        lib.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        lib.acl_get_fd_np.restype = ctypes.c_void_p
        lib.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
        lib.acl_get_entry.restype = ctypes.c_int
        lib.acl_free.argtypes = [ctypes.c_void_p]

        def has_entry(path):
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                acl = lib.acl_get_fd_np(descriptor, 0x100)
                if not acl:
                    return False
                try:
                    entry = ctypes.c_void_p()
                    return lib.acl_get_entry(acl, 0, ctypes.byref(entry)) == 0
                finally:
                    lib.acl_free(acl)
            finally:
                os.close(descriptor)

        self.assertTrue(has_entry(control), "Control must prove ACL inheritance is active")
        snapshot = parent / "snapshot.json"
        legacy.atomic_write_json(snapshot, {"synthetic": 1})
        self.assertFalse(has_entry(snapshot))
        self.assertEqual(snapshot.stat().st_uid, os.geteuid())
        self.assertEqual(snapshot.stat().st_mode & 0o7777, 0o600)


if __name__ == "__main__":
    unittest.main()
