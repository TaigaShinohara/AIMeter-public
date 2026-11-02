"""Local packaging/install tests use only synthetic files and command callbacks."""
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("local_build", REPO / "scripts/local_build.py")
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)
bundle_tools = local.bundle_tools


class PackagingFixture:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aimeter-packaging-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        for name in ("scripts", "Sources/AIMeterCore", "Sources/AIMeter/Resources"):
            (self.project / name).mkdir(parents=True)
        for name in ("AIMeter.entitlements", "AIMeterWidgetExtension.entitlements"):
            shutil.copyfile(REPO / "scripts" / name, self.project / "scripts" / name)
        (self.project / "Sources/AIMeterCore/SharedStore.swift").write_text(
            'public static let widgetSnapshotFileURL = localUsageFileURL.deletingLastPathComponent()\n'
            '    .appendingPathComponent(".ai_meter_widget.json")\n')
        (self.project / "Sources/AIMeter/Resources/AppIcon.icns").write_bytes(b"synthetic icon")
        (self.project / "LICENSE").write_text("synthetic license")
        self.old_app = self.project / "AIMeter.app"
        (self.old_app / "Contents/Resources").mkdir(parents=True)
        self.markers = {
            "Contents/Resources/synthetic-private-marker.json": b"SYNTHETIC-ONLY",
            "Contents/Resources/.env.synthetic": b"SYNTHETIC_ONLY=marker",
            "Contents/Resources/nested/marker": b"SYNTHETIC-NESTED",
        }
        for name, data in self.markers.items():
            path = self.old_app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.old_zip = self.project / "AIMeter-macos-universal.zip"
        self.old_zip.write_bytes(b"SYNTHETIC-OLD-ARCHIVE")
        self.architectures = {"arm64"}
        self.calls = []
        self.fail_sign = False
        self.binaries = self.project / ".build/synthetic-binaries"
        self.disk = patch.object(local.shutil, "disk_usage", return_value=SimpleNamespace(free=10 * 1024 ** 3))
        self.disk.start()
        self.addCleanup(self.disk.stop)

    def command(self, *args, **kwargs):
        args = tuple(str(value) for value in args)
        self.calls.append(args)
        command = Path(args[0]).name
        if command == "pgrep":
            raise subprocess.CalledProcessError(1, args)
        if command == "memory_pressure":
            return "System-wide memory free percentage: 50%\n"
        if command == "git":
            return "a" * 40 + "\n" if args[1] == "rev-parse" else ""
        if command == "swift":
            if "--show-bin-path" in args:
                return str(self.binaries)
            self.binaries.mkdir(parents=True)
            for name in ("AIMeter", "AIMeterWidgetExtension"):
                (self.binaries / name).write_bytes(("synthetic " + name).encode())
            return "Synthetic compilation only.\n"
        if command == "lipo":
            return " ".join(sorted(self.architectures))
        if command == "xcrun":
            return "    minos 14.0\n" * len(self.architectures)
        if command == "otool":
            return "binary:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1)\n"
        if command == "security":
            return "0 valid identities found\n"
        if command == "codesign":
            target = Path(args[-1])
            if "--force" in args:
                if self.fail_sign:
                    raise subprocess.CalledProcessError(1, args, stderr="synthetic failure")
                resource = target / "Contents/_CodeSignature/CodeResources"
                resource.parent.mkdir()
                resource.write_bytes(b"synthetic signed resource")
            if "--entitlements" in args and "-d" in args:
                filename = "AIMeterWidgetExtension.entitlements" if target.name == "AIMeterWidget.appex" else "AIMeter.entitlements"
                return (self.project / "scripts" / filename).read_text()
            return ""
        self.fail("Unexpected command in isolated packaging test: " + command)

    def build(self):
        return local.build(self.project, runner=self.command)

    def assert_old_preserved(self):
        for name, data in self.markers.items():
            self.assertEqual((self.old_app / name).read_bytes(), data)
        self.assertEqual(self.old_zip.read_bytes(), b"SYNTHETIC-OLD-ARCHIVE")


class BuildAppTests(PackagingFixture, unittest.TestCase):
    def test_local_bundle_records_development_update_channel(self):
        metadata = self.build()
        for bundle in bundle_tools.bundles(metadata["app"]):
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["AIMeterUpdateChannel"], "development")

    def test_bundle_rejects_mismatched_host_and_widget_update_channels(self):
        metadata = self.build()
        app = Path(metadata["app"])
        path = app / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["AIMeterUpdateChannel"] = "stable"
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "update channels differ"):
            bundle_tools.verify_bundle(app, metadata["version"], metadata["build_number"],
                                       self.command, widget_filename=".ai_meter_widget.json",
                                       architectures={"arm64"}, profile="local")

    def test_legacy_bundle_channel_is_optional_but_explicit_channel_is_required(self):
        metadata = self.build()
        app = Path(metadata["app"])
        for bundle in bundle_tools.bundles(app):
            path = bundle / "Contents/Info.plist"
            info = plistlib.loads(path.read_bytes())
            del info["AIMeterUpdateChannel"]
            path.write_bytes(plistlib.dumps(info))
        options = dict(widget_filename=".ai_meter_widget.json", architectures={"arm64"}, profile="local")
        bundle_tools.verify_bundle(app, metadata["version"], metadata["build_number"], self.command, **options)
        with self.assertRaisesRegex(ValueError, "AIMeterUpdateChannel"):
            bundle_tools.verify_bundle(app, metadata["version"], metadata["build_number"],
                                       self.command, update_channel="development", **options)

    def test_restart_discovery_is_limited_to_this_checkouts_local_packages(self):
        expected = self.project / ".build/local-packages" / ("a" * 32) / "AIMeter.app"
        unrelated = self.root / "unrelated/AIMeter.app"
        listing = ("123 " + str(expected / "Contents/MacOS/AIMeter") + "\n"
                   "124 " + str(unrelated / "Contents/MacOS/AIMeter") + "\n"
                   "125 " + str(expected / "Contents/MacOS/Other") + "\n")
        self.assertEqual(local.project_instances(self.project, runner=lambda *args: listing), {expected})

    def test_shell_entries_preserve_build_install_separation(self):
        commands = self.root / "shell-commands"
        commands.mkdir()
        recorder = commands / "python3"
        recorder.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$AIMETER_SCRIPT_RECORD"\n')
        recorder.chmod(0o755)
        record = self.root / "shell-arguments"
        environment = {"PATH": str(commands) + ":/usr/bin:/bin", "HOME": str(self.root),
                       "AIMETER_SCRIPT_RECORD": str(record), "AIMETER_INSTALL_TO_APPLICATIONS": "0"}
        result = subprocess.run(["/bin/bash", str(REPO / "scripts/build_app.sh"), "--build-number", "21"],
                                env=environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(record.read_text().splitlines()[1:], ["build", "--build-number", "21"])
        result = subprocess.run(["/bin/bash", str(REPO / "run.sh"), "--restart", "--build"],
                                env=environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(record.read_text().splitlines()[1:], ["run", "--install", "--restart", "--force-build"])

    def test_new_bundle_archive_exclude_stale_files_and_preserve_previous_artifacts(self):
        os.mkfifo(self.old_app / "Contents/Resources/synthetic-fifo")
        (self.old_app / "Contents/Resources/synthetic-link").symlink_to(self.project / "LICENSE")
        with patch.object(local.installer, "install", side_effect=AssertionError("Build must not install")):
            metadata = self.build()
        self.assert_old_preserved()
        self.assertEqual(metadata["architectures"], ["arm64"])
        self.assertNotIn("universal", Path(metadata["archive"]).name)
        app = Path(metadata["app"])
        self.assertEqual(set(bundle_tools.structure(app, signed=True)), bundle_tools.PAYLOAD | bundle_tools.SIGNATURE_FILES)
        self.assertFalse(any((app / name).exists() for name in self.markers))
        self.assertFalse(any("/Applications" in part for call in self.calls for part in call))
        with zipfile.ZipFile(metadata["archive"]) as archive:
            self.assertEqual(set(archive.namelist()), {"AIMeter.app/" + name for name in metadata["bundle_manifest"]})
            self.assertFalse(any("__MACOSX" in name or ".env" in name for name in archive.namelist()))
        for bundle in bundle_tools.bundles(app):
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["AIMeterSourceCommit"], "a" * 40)
            self.assertEqual(info["AIMeterBuildProfile"], "local")
            self.assertEqual(info["CFBundleVersion"], bundle_tools.LOCAL_BUILD_NUMBER)

    def test_universal_name_requires_both_slices(self):
        self.architectures = {"arm64", "x86_64"}
        metadata = self.build()
        self.assertIn("universal", Path(metadata["archive"]).name)

    def test_new_build_receipt_round_trip_and_existing_build_guard(self):
        metadata = self.build()
        self.assertEqual(local.current(self.project), metadata)
        calls = []
        def busy(*args, **kwargs):
            calls.append(args)
            return "123\n"
        with self.assertRaisesRegex(ValueError, "already running"):
            local.build(self.project, runner=busy)
        self.assertFalse(any(Path(str(call[0])).name == "swift" for call in calls))
        self.assert_old_preserved()

    def test_resource_parent_symlink_cannot_copy_outside_source(self):
        resources = self.project / "Sources/AIMeter/Resources"
        resources.rename(resources.with_name("original-resources"))
        outside = self.root / "outside-source"
        outside.mkdir()
        (outside / "AppIcon.icns").write_bytes(b"SYNTHETIC-OUTSIDE-SOURCE")
        resources.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "ancestors must be real"):
            self.build()
        self.assert_old_preserved()
        self.assertFalse((self.project / ".build/local-current.json").exists())

    def test_signing_failure_preserves_previous_artifacts_and_no_success_pointer(self):
        self.fail_sign = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.build()
        self.assert_old_preserved()
        self.assertFalse((self.project / ".build/local-current.json").exists())

    def test_unknown_links_directories_and_special_files_fail_validation(self):
        metadata = self.build()
        app = Path(metadata["app"])
        candidates = [app / "Contents/Resources/unknown", app / "Contents/Resources/link", app / "Contents/Resources/pipe"]
        for index, path in enumerate(candidates):
            if index == 0:
                path.mkdir()
            elif index == 1:
                path.symlink_to(self.project / "LICENSE")
            else:
                os.mkfifo(path)
            with self.assertRaises(ValueError):
                bundle_tools.structure(app)
            path.rmdir() if index == 0 else path.unlink()

    def test_version_commit_architecture_and_archive_tampering_fail(self):
        metadata = self.build()
        app = Path(metadata["app"])
        path = app / "Contents/Info.plist"
        original = path.read_bytes()
        for key, value in (("CFBundleVersion", "999"), ("AIMeterSourceCommit", "b" * 40)):
            info = plistlib.loads(original)
            info[key] = value
            path.write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                local.verify_local(app, metadata, source=self.project, runner=self.command)
            path.write_bytes(original)
        self.architectures = {"x86_64"}
        with self.assertRaises(ValueError):
            local.verify_local(app, metadata, source=self.project, runner=self.command)
        self.architectures = {"arm64"}
        with zipfile.ZipFile(metadata["archive"], "a") as archive:
            archive.writestr("AIMeter.app/Contents/Resources/extra.json", "SYNTHETIC-ONLY")
        with self.assertRaises(ValueError):
            bundle_tools.verify_zip(metadata["archive"], metadata["bundle_manifest"])

    def test_install_opt_out_does_not_read_receipt_or_call_installer(self):
        with patch.dict(os.environ, {"AIMETER_INSTALL_TO_APPLICATIONS": "0"}), \
             patch.object(local, "current", side_effect=AssertionError("No receipt read")), \
             patch.object(local.installer, "install", side_effect=AssertionError("No install")), \
             patch.object(local.sys, "argv", ["local_build.py", "install"]), \
             patch("sys.stderr", new_callable=io.StringIO) as errors:
            self.assertEqual(local.main(), 1)
            self.assertNotIn("/Applications", errors.getvalue())


class InstallAppTests(PackagingFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.metadata = self.build()
        self.app = Path(self.metadata["app"])
        self.destination = self.root / "Applications/AIMeter.app"
        self.destination.parent.mkdir()
        shutil.copytree(self.app, self.destination)
        self.previous_content = b"SYNTHETIC-PREVIOUS-LICENSE"
        (self.destination / "Contents/Resources/LICENSE").write_bytes(self.previous_content)
        self.events = []

    def verify(self, app):
        local.verify_local(app, self.metadata, source=self.project, runner=self.command)

    def callbacks(self):
        return {"stop_app": lambda app: self.events.append("stop"),
                "register_app": lambda app: self.events.append("register"),
                "launch_app": lambda app: self.events.append("launch"),
                "verify_previous_app": lambda app: local.installer.verify_previous(app, runner=self.command)}

    def test_install_replaces_complete_bundle_and_retains_previous(self):
        backup = local.installer.install(self.app, self.destination, self.verify, **self.callbacks())
        self.verify(self.destination)
        self.assertEqual((backup / "Contents/Resources/LICENSE").read_bytes(), self.previous_content)
        self.assertEqual(self.events, ["stop", "register", "launch"])

    def test_invalid_source_and_symlink_target_stop_before_copy_or_process_control(self):
        marker = self.app / "Contents/Resources/unknown.json"
        marker.write_text("SYNTHETIC-ONLY")
        with patch.object(local.installer, "copy_bundle") as copy:
            with self.assertRaises(ValueError):
                local.installer.install(self.app, self.destination, self.verify,
                                        copy_app=copy, **self.callbacks())
            copy.assert_not_called()
        marker.unlink()
        other = self.root / "other-app"
        self.destination.rename(other)
        self.destination.symlink_to(other, target_is_directory=True)
        with self.assertRaises(ValueError):
            local.installer.install(self.app, self.destination, self.verify, **self.callbacks())
        self.assertEqual(self.events, [])

    def test_unknown_or_invalidly_signed_previous_bundle_is_not_a_rollback_candidate(self):
        marker = self.destination / "Contents/Resources/old-private.json"
        marker.write_text("SYNTHETIC-ONLY")
        with patch.object(local.installer, "copy_bundle") as copy:
            with self.assertRaisesRegex(ValueError, "allowlist"):
                local.installer.install(self.app, self.destination, self.verify,
                                        copy_app=copy, **self.callbacks())
            copy.assert_not_called()
        self.assertEqual(self.events, [])
        marker.unlink()
        callbacks = self.callbacks()
        def bad_signature(app):
            raise ValueError("synthetic previous signature failure")
        callbacks["verify_previous_app"] = bad_signature
        with patch.object(local.installer, "copy_bundle") as copy:
            with self.assertRaisesRegex(ValueError, "previous signature failure"):
                local.installer.install(self.app, self.destination, self.verify, copy_app=copy, **callbacks)
            copy.assert_not_called()
        self.assertEqual(self.events, [])
        self.assertEqual((self.destination / "Contents/Resources/LICENSE").read_bytes(), self.previous_content)

    def test_copy_or_staging_verification_failure_keeps_current_app(self):
        def broken_copy(source, target):
            raise OSError("synthetic copy failure")
        with self.assertRaises(OSError):
            local.installer.install(self.app, self.destination, self.verify, copy_app=broken_copy, **self.callbacks())
        self.assertEqual((self.destination / "Contents/Resources/LICENSE").read_bytes(), self.previous_content)
        self.assertEqual(self.events, [])
        def broken_verify(app):
            if Path(app) != self.app:
                raise ValueError("synthetic staging verification failure")
            self.verify(app)
        with self.assertRaises(ValueError):
            local.installer.install(self.app, self.destination, broken_verify, **self.callbacks())
        self.assertEqual((self.destination / "Contents/Resources/LICENSE").read_bytes(), self.previous_content)
        self.assertEqual(self.events, [])

    def test_rename_or_launch_failure_restores_previous_app(self):
        original_rename = os.rename
        def broken_rename(source, target):
            if Path(source).name == "candidate.app":
                raise OSError("synthetic switch failure")
            original_rename(source, target)
        with self.assertRaises(ValueError):
            local.installer.install(self.app, self.destination, self.verify, rename=broken_rename, **self.callbacks())
        self.assertEqual((self.destination / "Contents/Resources/LICENSE").read_bytes(), self.previous_content)
        launches = []
        def broken_launch(app):
            launches.append(Path(app))
            if len(launches) == 1:
                raise ValueError("synthetic launch failure")
        callbacks = self.callbacks()
        callbacks["launch_app"] = broken_launch
        with self.assertRaises(ValueError):
            local.installer.install(self.app, self.destination, self.verify, **callbacks)
        self.assertEqual((self.destination / "Contents/Resources/LICENSE").read_bytes(), self.previous_content)
        self.assertEqual(len(launches), 2)

    def test_registration_failure_restores_previous_app(self):
        registrations = []
        def broken_registration(app):
            registrations.append(Path(app))
            if len(registrations) == 1:
                raise ValueError("synthetic registration failure")
        callbacks = self.callbacks()
        callbacks["register_app"] = broken_registration
        with self.assertRaises(ValueError):
            local.installer.install(self.app, self.destination, self.verify, **callbacks)
        self.assertEqual((self.destination / "Contents/Resources/LICENSE").read_bytes(), self.previous_content)
        self.assertEqual(len(registrations), 2)

    def test_widget_only_launch_is_rejected_and_previous_main_is_restored(self):
        launches = []
        def synthetic_launch(app):
            launches.append(Path(app))
            def runner(*args):
                if Path(args[0]).name == "open":
                    return ""
                main = str(Path(app) / "Contents/MacOS/AIMeter")
                widget = str(Path(app) / "Contents/PlugIns/AIMeterWidget.appex/Contents/MacOS/AIMeterWidgetExtension")
                return "1234 " + (widget if len(launches) == 1 else main) + "\n"
            local.installer.launch(app, runner=runner, sleeper=lambda seconds: None)
        callbacks = self.callbacks()
        callbacks["launch_app"] = synthetic_launch
        with self.assertRaisesRegex(ValueError, "previous installation state was restored"):
            local.installer.install(self.app, self.destination, self.verify, **callbacks)
        self.assertEqual((self.destination / "Contents/Resources/LICENSE").read_bytes(), self.previous_content)
        self.assertEqual(len(launches), 2)

    def test_main_must_remain_alive_during_launch_verification(self):
        snapshots = iter(["1234 " + str(self.app / "Contents/MacOS/AIMeter") + "\n", ""])
        def runner(*args):
            return "" if Path(args[0]).name == "open" else next(snapshots)
        with self.assertRaisesRegex(ValueError, "main app exited"):
            local.installer.launch(self.app, runner=runner, sleeper=lambda seconds: None)


if __name__ == "__main__":
    unittest.main()
