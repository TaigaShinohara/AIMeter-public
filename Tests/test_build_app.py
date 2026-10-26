"""Exercise local packaging with synthetic binaries and isolated command stubs.

No build, Keychain access, signing, system registration, or installation occurs.
The ditto stub fails before any /Applications copy, so set -e also prevents the
script's absolute lsregister call if the installation opt-out ever regresses.
"""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


COMMAND_STUB = r'''
import json
import os
from pathlib import Path
import sys
import zipfile

command = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["AIMETER_TEST_RECORD"], "a", encoding="utf-8") as record:
    record.write(json.dumps([command] + args) + "\n")

# Never allow even a mocked installation step to precede real registration.
if any(arg == "/Applications" or arg.startswith("/Applications/") for arg in args):
    sys.exit("The test must not install or register an app")

if command == "swift":
    if args != ["build", "-c", "release"]:
        sys.exit("Unexpected build arguments")
    binaries = Path.cwd() / ".build/release"
    binaries.mkdir(parents=True)
    for name in ("AIMeter", "AIMeterWidgetExtension"):
        (binaries / name).write_bytes(("synthetic " + name).encode())
elif command == "security":
    print("0 valid identities found")
elif command == "codesign":
    if os.environ.get("AIMETER_TEST_FAIL_CODESIGN") == "1":
        sys.exit("Synthetic signing failure")
elif command == "ditto":
    if args[:4] != ["-c", "-k", "--sequesterRsrc", "--keepParent"] or len(args) != 6:
        sys.exit("Only synthetic archive creation is allowed")
    source, destination = (Path(value) for value in args[-2:])
    root = Path.cwd().resolve()
    if source.parent.resolve() != root or destination.parent.resolve() != root:
        sys.exit("Archive paths must remain in the temporary project")
    with zipfile.ZipFile(destination, "w") as archive:
        for path in sorted(source.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(source.parent))
else:
    sys.exit("System registration is forbidden in this test")
'''


class BuildAppTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="aimeter-build-script-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / "project"
        scripts = self.project / "scripts"
        scripts.mkdir(parents=True)
        source_scripts = Path(__file__).resolve().parents[1] / "scripts"
        for name in ("build_app.sh", "AIMeter.entitlements", "AIMeterWidgetExtension.entitlements"):
            shutil.copyfile(source_scripts / name, scripts / name)

        self.app = self.project / "AIMeter.app"
        resources = self.app / "Contents/Resources"
        resources.mkdir(parents=True)
        (resources / "update_usage.py").write_text("stale bundled script", encoding="utf-8")
        icon = self.project / "Sources/AIMeter/Resources/AppIcon.icns"
        icon.parent.mkdir(parents=True)
        icon.write_bytes(b"synthetic icon")

        commands = self.root / "commands"
        commands.mkdir()
        for name in ("swift", "security", "codesign", "ditto", "pluginkit", "lsregister"):
            stub = commands / name
            stub.write_text("#!" + sys.executable + "\n" + COMMAND_STUB, encoding="utf-8")
            stub.chmod(0o755)
        self.record = self.root / "commands.jsonl"
        home = self.root / "home"
        home.mkdir()
        self.environment = {
            "PATH": str(commands) + ":/usr/bin:/bin",
            "HOME": str(home),
            "TMPDIR": str(self.root),
            "LANG": "C",
            "AIMETER_INSTALL_TO_APPLICATIONS": "0",
            "AIMETER_TEST_RECORD": str(self.record),
        }
        self.archive = self.project / "AIMeter-macos-universal.zip"

    def run_script(self):
        return subprocess.run(
            ["/bin/bash", str(self.project / "scripts/build_app.sh")],
            cwd=self.project, env=self.environment, capture_output=True,
            text=True, timeout=15,
        )

    def calls(self):
        return [json.loads(line) for line in self.record.read_text(encoding="utf-8").splitlines()]

    def test_packaging_removes_legacy_script_signs_runtime_and_skips_installation(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.app / "Contents/Resources/update_usage.py").exists())
        widget = self.app / "Contents/PlugIns/AIMeterWidget.appex"
        for bundle, executable, identifier in (
            (self.app, "AIMeter", "com.local.AIMeter"),
            (widget, "AIMeterWidgetExtension", "com.local.AIMeter.widget"),
        ):
            self.assertEqual((bundle / "Contents/MacOS" / executable).read_bytes(),
                             ("synthetic " + executable).encode())
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleExecutable"], executable)
            self.assertEqual(info["CFBundleIdentifier"], identifier)
            self.assertEqual((bundle / "Contents/Resources/AppIcon.icns").read_bytes(), b"synthetic icon")

        calls = self.calls()
        self.assertEqual([call[0] for call in calls], ["swift", "security", "codesign", "codesign", "ditto"])
        signing = [call for call in calls if call[0] == "codesign"]
        self.assertEqual([call[-1] for call in signing], [str(widget), str(self.app)])
        for call in signing:
            self.assertEqual(call[call.index("--options") + 1], "runtime")
            self.assertEqual(call[call.index("--sign") + 1], "-")
        self.assertFalse(any("/Applications" in arg for call in calls for arg in call))
        self.assertNotIn("Syncing to", result.stdout)
        with zipfile.ZipFile(self.archive) as archive:
            names = set(archive.namelist())
            for prefix, executable in (("AIMeter.app", "AIMeter"),
                                       ("AIMeter.app/Contents/PlugIns/AIMeterWidget.appex", "AIMeterWidgetExtension")):
                self.assertIn(prefix + "/Contents/Info.plist", names)
                self.assertIn(prefix + "/Contents/MacOS/" + executable, names)
            self.assertFalse(any(name.endswith("update_usage.py") for name in names))

    def test_signing_failure_stops_before_installation_and_archive_creation(self):
        self.environment["AIMETER_TEST_FAIL_CODESIGN"] = "1"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Synthetic signing failure", result.stderr)
        self.assertEqual([call[0] for call in self.calls()], ["swift", "security", "codesign"])
        self.assertFalse(self.archive.exists())


if __name__ == "__main__":
    unittest.main()
