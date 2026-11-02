"""Distribution gates use synthetic bundles and mocked Apple/GitHub commands."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "release", Path(__file__).resolve().parents[1] / "scripts/release.py"
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
FINGERPRINT = "A" * 40
TEAM = "ABCDE12345"


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "AIMeter.app"
        self.notes = self.root / "validation-notes.md"
        self.notes.write_text("Synthetic test only; no runtime verification.")

    def command(self, *args, **kwargs):
        if args[0] == "/usr/bin/codesign" and "--force" in args:
            resource = Path(args[-1]) / "Contents/_CodeSignature/CodeResources"
            resource.parent.mkdir(exist_ok=True)
            resource.write_bytes(b"synthetic signed resources")
            return ""
        if args[0] == "/usr/bin/codesign" and "--entitlements" in args:
            return plistlib.dumps(release.widget_contract()[1]).decode("utf-8")
        if args[0] == "/usr/bin/lipo":
            return "arm64 x86_64\n"
        if args[0] == "/usr/bin/otool":
            return ("/tmp/build/binary (architecture arm64):\n"
                    "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n")
        if "vtool" in args:
            return "    minos 14.0\n    minos 14.0\n"
        return ""

    def package(self, *, prerelease=False):
        source = self.root / "source"
        resources = source / "Sources/AIMeter/Resources"
        resources.mkdir(parents=True)
        (resources / "AppIcon.icns").write_bytes(b"synthetic icon")
        (resources / "personal-log.json").write_text("MUST NOT SHIP")
        (source / "LICENSE").write_text("synthetic license")
        core = source / "Sources/AIMeterCore"
        core.mkdir()
        (core / "SharedStore.swift").write_text(
            'public static let widgetSnapshotFileURL = localUsageFileURL.deletingLastPathComponent()\n'
            '    .appendingPathComponent(".ai_meter_widget.json")\n'
        )
        scripts = source / "scripts"
        scripts.mkdir()
        shutil.copyfile(release.REPO / "scripts/AIMeterWidgetExtension.entitlements",
                        scripts / "AIMeterWidgetExtension.entitlements")
        binaries = self.root / "binaries"
        binaries.mkdir()
        for name in ("AIMeter", "AIMeterWidgetExtension"):
            (binaries / name).write_bytes(b"synthetic executable")
        release.package_app(source, binaries, self.app, "1.1.1", "3", "b" * 40,
                            prerelease=prerelease)

    @patch.object(release, "run")
    def test_bundle_is_allowlisted_and_versions_match(self, command):
        command.side_effect = self.command
        self.package()
        self.assertFalse(list(self.app.rglob("personal-log.json")))
        self.assertTrue((self.app / "Contents/Resources/LICENSE").exists())
        for bundle in release.bundles(self.app):
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleVersion"], "3")
            self.assertEqual(info["AIMeterSourceCommit"], "b" * 40)
            self.assertEqual(info["AIMeterWidgetSnapshotFilename"], ".ai_meter_widget.json")
            self.assertEqual(info["AIMeterUpdateChannel"], "stable")

    @patch.object(release, "run")
    def test_prerelease_bundle_identifies_development_channel(self, command):
        command.side_effect = self.command
        self.package(prerelease=True)
        for bundle in release.bundles(self.app):
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["AIMeterUpdateChannel"], "development")
        release.verify_bundle(self.app, "1.1.1", "3", update_channel="development")
        with self.assertRaisesRegex(ValueError, "AIMeterUpdateChannel"):
            release.verify_bundle(self.app, "1.1.1", "3", update_channel="stable")

    @patch.object(release, "run")
    def test_legacy_receipt_cannot_hide_development_bundle_channel(self, command):
        command.side_effect = self.command
        self.package(prerelease=True)
        with self.assertRaisesRegex(ValueError, "update channel"):
            release.verify_receipt_channel(self.app, {})
        release.verify_receipt_channel(self.app, {"update_channel": "development"})

    @patch.object(release, "run")
    def test_legacy_stable_bundle_and_receipt_remain_compatible(self, command):
        command.side_effect = self.command
        self.package()
        for bundle in release.bundles(self.app):
            info_path = bundle / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            del info["AIMeterUpdateChannel"]
            info_path.write_bytes(plistlib.dumps(info))
        release.verify_bundle(self.app, "1.1.1", "3")
        release.verify_receipt_channel(self.app, {})

    def test_development_and_release_grants_match_current_swift_consumer(self):
        filename, grant = release.widget_contract()
        self.assertEqual(filename, ".ai_meter_widget.json")
        self.assertEqual(grant, {
            release.WIDGET_SANDBOX: True,
            release.WIDGET_HOME_READ: ["/.ai_meter_widget.json"],
        })
        self.assertNotIn(release.APP_GROUPS, grant)

    @patch.object(release, "run")
    def test_packaging_rejects_drift_between_archived_consumer_and_grant(self, command):
        command.side_effect = self.command
        self.package()
        source = self.root / "source"
        implementation = source / "Sources/AIMeterCore/SharedStore.swift"
        implementation.write_text(implementation.read_text().replace(
            ".ai_meter_widget.json", ".different_widget.json"))
        with self.assertRaisesRegex(ValueError, "Development Widget entitlements"):
            release.widget_contract(source)

    @patch.object(release, "run")
    def test_bundle_cannot_claim_a_different_display_cache_contract(self, command):
        command.side_effect = self.command
        self.package()
        widget = release.bundles(self.app)[0]
        info_file = widget / "Contents/Info.plist"
        info = plistlib.loads(info_file.read_bytes())
        info["AIMeterWidgetSnapshotFilename"] = ".ai_meter_usage.json"
        info_file.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "AIMeterWidgetSnapshotFilename"):
            release.verify_bundle(self.app, "1.1.1", "3")

    @patch.object(release, "run")
    def test_signed_widget_rejects_old_file_extra_capability_and_missing_sandbox(self, command):
        expected = release.widget_contract()[1]
        invalid = [
            dict(expected, **{release.WIDGET_HOME_READ: ["/.ai_meter_usage.json"]}),
            dict(expected, **{"com.apple.security.network.client": True}),
            dict(expected, **{release.APP_GROUPS: ["group.com.local.AIMeter"]}),
            dict(expected, **{release.WIDGET_SANDBOX: False}),
            dict(expected, **{release.WIDGET_SANDBOX: 1}),
            {},
        ]
        for grant in invalid:
            with self.subTest(grant=grant):
                command.return_value = plistlib.dumps(grant).decode("utf-8")
                with self.assertRaisesRegex(ValueError, "Signed Widget entitlements"):
                    release.verify_widget_entitlements(self.app)
        command.return_value = plistlib.dumps(expected).decode("utf-8")
        release.verify_widget_entitlements(self.app)
        self.assertEqual(command.call_args.args[-1], release.bundles(self.app)[0])

    @patch.object(release, "run")
    def test_unreadable_signed_entitlements_fail_closed(self, command):
        for encoded in ("", "not a plist", plistlib.dumps([]).decode("utf-8")):
            with self.subTest(encoded=encoded):
                command.return_value = encoded
                with self.assertRaises(ValueError):
                    release.verify_widget_entitlements(self.app)

    @patch.object(release, "check_identity")
    @patch.object(release.subprocess, "run")
    @patch.object(release, "run")
    def test_wrong_signed_grant_stops_before_apple_submission(self, command, display, identity):
        command.side_effect = self.command
        self.package()
        release.write_json(self.root / "build.json",
                           {"version": "1.1.1", "build_number": "3", "commit": "b" * 40})
        display.return_value = subprocess.CompletedProcess([], 0, "", (
            f"TeamIdentifier={TEAM}\nAuthority=Developer ID Application: Example\n"
            "Timestamp=Oct 20, 2026\nflags=0x10000(runtime)\n"))

        def wrong_grant(*args, **kwargs):
            if args[0] == "/usr/bin/codesign" and "--entitlements" in args and "-d" in args:
                return plistlib.dumps({
                    release.WIDGET_SANDBOX: True,
                    release.WIDGET_HOME_READ: ["/.ai_meter_usage.json"],
                }).decode("utf-8")
            return self.command(*args, **kwargs)

        command.side_effect = wrong_grant
        with self.assertRaisesRegex(ValueError, "Signed Widget entitlements"):
            release.notarize(self.root, FINGERPRINT, TEAM, "synthetic-profile")
        self.assertFalse(any("notarytool" in call.args for call in command.call_args_list))
        self.assertFalse((self.root / "notary-upload.zip").exists())
        self.assertFalse((self.root / "release.json").exists())

    @patch.object(release, "check_identity")
    @patch.object(release, "verify_signature")
    @patch.object(release, "run")
    def test_notarization_signs_only_current_display_cache_grant(self, command, signature, identity):
        command.side_effect = self.command
        self.package()
        release.write_json(self.root / "build.json",
                           {"version": "1.1.1", "build_number": "3", "commit": "b" * 40})

        def rejected(*args, **kwargs):
            if "notarytool" in args:
                grant = plistlib.loads((self.root / "widget-release.entitlements").read_bytes())
                self.assertEqual(grant, release.widget_contract()[1])
                return json.dumps({"status": "Invalid", "id": "synthetic-submission"})
            return self.command(*args, **kwargs)

        command.side_effect = rejected
        with self.assertRaisesRegex(ValueError, "not accepted"):
            release.notarize(self.root, FINGERPRINT, TEAM, "synthetic-profile")
        signatures = [call.args for call in command.call_args_list
                      if call.args[0] == "/usr/bin/codesign" and "--sign" in call.args]
        self.assertEqual(len(signatures), 2)
        self.assertIn(self.root / "widget-release.entitlements", signatures[0])
        self.assertNotIn("--entitlements", signatures[1])

    @patch.object(release, "run")
    def test_single_architecture_cannot_be_labeled_universal(self, command):
        command.side_effect = lambda *args, **kw: "arm64\n"
        with self.assertRaisesRegex(ValueError, "both contain"):
            self.package()

    @patch.object(release, "run")
    def test_build_machine_library_dependency_is_rejected(self, command):
        command.side_effect = lambda *args, **kw: (
            "arm64 x86_64" if args[0].endswith("lipo") else
            "    minos 14.0\n    minos 14.0\n" if "vtool" in args else
            "binary:\n\t/opt/homebrew/lib/private.dylib (compatibility version 1)\n"
        )
        with self.assertRaisesRegex(ValueError, "Non-system"):
            self.package()

    @patch.object(release, "run")
    def test_newer_macho_target_cannot_claim_macos_14_support(self, command):
        command.side_effect = lambda *args, **kw: (
            "    minos 27.0\n    minos 27.0\n" if "vtool" in args else self.command(*args, **kw)
        )
        with self.assertRaisesRegex(ValueError, "Both Mach-O"):
            self.package()

    @patch.object(release, "run")
    def test_rejects_wrong_certificate_type_and_team(self, command):
        for name in ("Apple Development", "Apple Distribution", "Developer ID Installer"):
            command.return_value = f'1) {FINGERPRINT} "{name}: Example ({TEAM})"'
            with self.assertRaisesRegex(ValueError, "identity not found"):
                release.check_identity(FINGERPRINT, TEAM)
        command.return_value = f'1) {FINGERPRINT} "Developer ID Application: Example (WRONG12345)"'
        with self.assertRaises(ValueError):
            release.check_identity(FINGERPRINT, TEAM)
        command.return_value = f'1) {FINGERPRINT} "Developer ID Application: Example ({TEAM})"'
        release.check_identity(FINGERPRINT, TEAM)

    @patch.object(release, "run")
    def test_ad_hoc_is_never_accepted(self, command):
        with self.assertRaises(ValueError):
            release.check_identity("-", TEAM)
        command.assert_not_called()

    @patch.object(release, "run")
    def test_missing_certificate_stops_before_build_metadata_or_submission(self, command):
        command.return_value = "0 valid identities found"
        with self.assertRaisesRegex(ValueError, "identity not found"):
            release.notarize(self.root, FINGERPRINT, TEAM, "synthetic-profile")
        self.assertEqual(command.call_count, 1)
        self.assertFalse((self.root / "release.json").exists())

    @patch.object(release, "check_identity")
    @patch.object(release, "verify_signature")
    @patch.object(release, "run")
    def test_rejected_notarization_never_creates_publishable_archive(self, command, signature, identity):
        command.side_effect = self.command
        self.package()
        release.write_json(self.root / "build.json",
                           {"version": "1.1.1", "build_number": "3", "commit": "b" * 40})

        def rejected(*args, **kwargs):
            if "notarytool" in args:
                return json.dumps({"status": "Invalid", "id": "synthetic-submission"})
            return self.command(*args, **kwargs)

        command.side_effect = rejected
        with self.assertRaisesRegex(ValueError, "not accepted"):
            release.notarize(self.root, FINGERPRINT, TEAM, "synthetic-profile")
        self.assertFalse((self.root / "release.json").exists())
        self.assertFalse(list(self.root.glob("AIMeter-*.zip")))
        self.assertFalse(any("stapler" in call.args for call in command.call_args_list))

    @patch.object(release, "check_identity")
    @patch.object(release, "verify_signature")
    @patch.object(release, "run")
    def test_gatekeeper_rejection_after_apple_acceptance_blocks_release(self, command, signature, identity):
        command.side_effect = self.command
        self.package()
        release.write_json(self.root / "build.json",
                           {"version": "1.1.1", "build_number": "3", "commit": "b" * 40})

        def reject_gatekeeper(*args, **kwargs):
            if "notarytool" in args:
                return json.dumps({"status": "Accepted", "id": "synthetic-submission"})
            if args[0].endswith("spctl"):
                raise subprocess.CalledProcessError(1, args)
            return self.command(*args, **kwargs)

        command.side_effect = reject_gatekeeper
        with self.assertRaises(subprocess.CalledProcessError):
            release.notarize(self.root, FINGERPRINT, TEAM, "synthetic-profile")
        self.assertFalse((self.root / "release.json").exists())
        self.assertFalse(list(self.root.glob("AIMeter-*.zip")))

    @patch.object(release, "run")
    @patch.object(release.subprocess, "run")
    def test_signature_requires_team_timestamp_and_runtime(self, process, command):
        command.side_effect = self.command
        self.package()
        for bundle in release.bundles(self.app):
            self.command("/usr/bin/codesign", "--force", bundle)
        valid = (f"TeamIdentifier={TEAM}\nAuthority=Developer ID Application: Example\n"
                 "Timestamp=Oct 20, 2026\nflags=0x10000(runtime)\n")
        for removed in (f"TeamIdentifier={TEAM}\n", "Timestamp=Oct 20, 2026\n",
                        "flags=0x10000(runtime)\n", "Authority=Developer ID Application: Example\n"):
            process.return_value = subprocess.CompletedProcess([], 0, "", valid.replace(removed, ""))
            with self.assertRaisesRegex(ValueError, "Missing Developer ID"):
                release.verify_signature(self.app, TEAM)
        process.return_value = subprocess.CompletedProcess([], 0, "", valid)
        release.verify_signature(self.app, TEAM)

    @patch.object(release, "run")
    def test_existing_bundle_is_not_reused_or_removed(self, command):
        command.side_effect = self.command
        marker = self.app / "Contents/Resources/synthetic-private.json"
        marker.parent.mkdir(parents=True)
        marker.write_text("SYNTHETIC-ONLY")
        with self.assertRaisesRegex(ValueError, "existing bundles are preserved"):
            self.package()
        self.assertEqual(marker.read_text(), "SYNTHETIC-ONLY")

    @patch.object(release, "run")
    def test_unknown_payload_stops_before_cryptographic_or_network_commands(self, command):
        command.side_effect = self.command
        self.package()
        marker = self.app / "Contents/Resources/synthetic-private.json"
        marker.write_text("SYNTHETIC-ONLY")
        command.reset_mock()
        with self.assertRaisesRegex(ValueError, "allowlist"):
            release.verify_bundle(self.app, "1.1.1", "3")
        command.assert_not_called()

    @patch.object(release, "verify_signature")
    @patch.object(release, "run")
    def test_exact_archive_manifest_is_verified_after_round_trip(self, command, signature):
        command.side_effect = self.command
        self.package()
        for bundle in release.bundles(self.app):
            self.command("/usr/bin/codesign", "--force", bundle)
        (self.app / "Contents/CodeResources").write_bytes(b"s8ch\x01\0\0\0SYNTHETIC-NOTARIZATION-TICKET")
        archive = self.root / "AIMeter-1.1.1-macos-universal.zip"
        release.zip_app(self.app, archive)
        digest = release.sha256(archive)
        release.write_json(self.root / "release.json", {
            "archive": archive.name, "version": "1.1.1", "build_number": "3",
            "sha256": digest, "team": TEAM, "commit": "b" * 40,
            "bundle_manifest": release.bundle_tools.manifest(self.app),
        })
        (self.root / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
        # Loose output is not trusted instead of the exact publishable ZIP.
        (self.app / "Contents/Resources/loose-private.json").write_text("SYNTHETIC-ONLY")
        self.assertEqual(release.validate_release(self.root)["commit"], "b" * 40)
        self.assertEqual(signature.call_count, 1)

    def receipt(self, *, update_channel=None):
        archive = self.root / "AIMeter-1.1.1-macos-universal.zip"
        archive.write_bytes(b"synthetic archive")
        digest = release.sha256(archive)
        metadata = {
            "archive": archive.name, "version": "1.1.1", "build_number": "3",
            "sha256": digest, "team": TEAM, "commit": "b" * 40,
        }
        if update_channel is not None:
            metadata["update_channel"] = update_channel
        release.write_json(self.root / "release.json", metadata)
        (self.root / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
        return archive

    @patch.object(release, "run")
    def test_archive_tampering_stops_before_upload_or_extraction(self, command):
        archive = self.receipt()
        archive.write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "changed after"):
            release.publish(self.root, self.notes)
        command.assert_not_called()

    @patch.object(release, "run")
    def test_checksum_tampering_stops_before_upload(self, command):
        self.receipt()
        (self.root / "SHA256SUMS").write_text("wrong")
        with self.assertRaisesRegex(ValueError, "SHA256SUMS"):
            release.publish(self.root, self.notes)
        command.assert_not_called()

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_unmerged_source_is_never_uploaded(self, command, validation):
        validation.return_value = {"version": "1.1.1", "commit": "b" * 40}

        def reject(*args, **kwargs):
            if "merge-base" in args:
                raise subprocess.CalledProcessError(1, args)
            return ""

        command.side_effect = reject
        with self.assertRaises(subprocess.CalledProcessError):
            release.publish(self.root, self.notes)
        self.assertFalse(any(call.args[0] == "gh" for call in command.call_args_list))

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_failed_uploaded_digest_leaves_draft(self, command, validation):
        archive = self.receipt()
        validation.return_value = json.loads((self.root / "release.json").read_text())

        def mismatch(*args, **kwargs):
            if any("matching-refs" in str(arg) for arg in args):
                return "[]"
            if args[:3] == ("gh", "release", "view"):
                return json.dumps({
                    "isDraft": True, "isPrerelease": False,
                    "tagName": "v1.1.1", "targetCommitish": "b" * 40,
                    "assets": [{"name": archive.name, "digest": "sha256:wrong"}],
                })
            return ""

        command.side_effect = mismatch
        with self.assertRaisesRegex(ValueError, "remains a draft"):
            release.publish(self.root, self.notes)
        self.assertTrue(any(call.args[:3] == ("gh", "release", "create")
                            for call in command.call_args_list))
        self.assertFalse(any(call.args[:3] == ("gh", "release", "edit")
                             for call in command.call_args_list))

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_draft_without_git_tag_publishes_only_after_both_digests_match(self, command, validation):
        archive = self.receipt()
        validation.return_value = json.loads((self.root / "release.json").read_text())
        state = {"draft": True, "checked": False}

        def github(*args, **kwargs):
            if any("matching-refs" in str(arg) for arg in args):
                return "[]"
            if args[:2] == ("gh", "api"):
                # GitHub's by-tag REST endpoint cannot resolve this untagged draft.
                raise subprocess.CalledProcessError(1, args, stderr="Not Found (HTTP 404)")
            if args[:3] == ("gh", "release", "view"):
                state["checked"] = True
                return json.dumps({
                    "isDraft": state["draft"], "isPrerelease": False,
                    "tagName": "v1.1.1",
                    "targetCommitish": "b" * 40,
                    "url": "https://github.com/example/project/releases/tag/v1.1.1",
                    "assets": [
                        {"name": p.name, "digest": "sha256:" + release.sha256(p)}
                        for p in (archive, self.root / "SHA256SUMS")
                    ],
                })
            if args[:3] == ("gh", "release", "edit"):
                self.assertTrue(state["checked"])
                state["draft"] = False
            return ""

        command.side_effect = github
        release.publish(self.root, self.notes)
        self.assertFalse(state["draft"])
        self.assertEqual(sum(call.args[:3] == ("gh", "release", "create")
                             for call in command.call_args_list), 1)
        self.assertEqual(sum(call.args[:3] == ("gh", "release", "view")
                             for call in command.call_args_list), 2)
        creation = next(call.args for call in command.call_args_list
                        if call.args[:3] == ("gh", "release", "create"))
        self.assertNotIn("--prerelease", creation)
        self.assertNotIn("--latest=false", creation)

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_prerelease_uses_distinct_tag_and_never_becomes_latest(self, command, validation):
        archive = self.receipt(update_channel="development")
        validation.return_value = json.loads((self.root / "release.json").read_text())
        state = {"draft": True}

        def github(*args, **kwargs):
            if any("matching-refs" in str(arg) for arg in args):
                self.assertTrue(args[-1].endswith("/v1.1.1-dev.3"))
                return "[]"
            if args[:3] == ("gh", "release", "view"):
                return json.dumps({
                    "isDraft": state["draft"], "isPrerelease": True,
                    "tagName": "v1.1.1-dev.3", "targetCommitish": "b" * 40,
                    "url": "https://github.com/example/project/releases/tag/v1.1.1-dev.3",
                    "assets": [
                        {"name": p.name, "digest": "sha256:" + release.sha256(p)}
                        for p in (archive, self.root / "SHA256SUMS")
                    ],
                })
            if args[:3] in (("gh", "release", "create"), ("gh", "release", "edit")):
                self.assertEqual(args[3], "v1.1.1-dev.3")
                self.assertIn("--prerelease", args)
                self.assertIn("--latest=false", args)
            if args[:3] == ("gh", "release", "edit"):
                state["draft"] = False
            return ""

        command.side_effect = github
        release.publish(self.root, self.notes, prerelease=True)
        self.assertFalse(state["draft"])
        self.assertIn("開発版", (self.root / "release-notes.md").read_text())
        self.assertEqual(sum(call.args[:3] == ("gh", "release", "create")
                             for call in command.call_args_list), 1)

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_wrong_prerelease_channel_stays_draft(self, command, validation):
        self.receipt(update_channel="development")
        validation.return_value = json.loads((self.root / "release.json").read_text())

        def wrong_channel(*args, **kwargs):
            if any("matching-refs" in str(arg) for arg in args):
                return "[]"
            if args[:3] == ("gh", "release", "view"):
                return json.dumps({
                    "isDraft": True, "isPrerelease": False,
                    "tagName": "v1.1.1-dev.3", "targetCommitish": "b" * 40,
                })
            return ""

        command.side_effect = wrong_channel
        with self.assertRaisesRegex(ValueError, "Unexpected draft"):
            release.publish(self.root, self.notes, prerelease=True)
        self.assertFalse(any(call.args[:3] == ("gh", "release", "edit")
                             for call in command.call_args_list))

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_prerelease_existing_tag_is_not_overwritten(self, command, validation):
        self.receipt(update_channel="development")
        validation.return_value = json.loads((self.root / "release.json").read_text())
        command.return_value = json.dumps([{"ref": "refs/tags/v1.1.1-dev.3"}])
        with self.assertRaisesRegex(ValueError, "already exists"):
            release.publish(self.root, self.notes, prerelease=True)
        self.assertFalse(any(call.args[:3] == ("gh", "release", "create")
                             for call in command.call_args_list))

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_publishing_cannot_change_the_verified_build_channel(self, command, validation):
        for channel, prerelease in ((None, True), ("stable", True), ("development", False),
                                    ("unknown", False)):
            with self.subTest(channel=channel, prerelease=prerelease):
                self.receipt(update_channel=channel)
                validation.return_value = json.loads((self.root / "release.json").read_text())
                with self.assertRaisesRegex(ValueError, "Release channel"):
                    release.publish(self.root, self.notes, prerelease=prerelease)
        command.assert_not_called()

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_unexpected_draft_source_cannot_be_published(self, command, validation):
        self.receipt()
        validation.return_value = json.loads((self.root / "release.json").read_text())

        def wrong_source(*args, **kwargs):
            if any("matching-refs" in str(arg) for arg in args):
                return "[]"
            if args[:3] == ("gh", "release", "view"):
                return json.dumps({
                    "isDraft": True, "isPrerelease": False,
                    "tagName": "v1.1.1", "targetCommitish": "c" * 40,
                })
            return ""

        command.side_effect = wrong_source
        with self.assertRaisesRegex(ValueError, "Unexpected draft"):
            release.publish(self.root, self.notes)
        self.assertFalse(any(call.args[:3] == ("gh", "release", "edit")
                             for call in command.call_args_list))

    @patch.object(release, "validate_release")
    @patch.object(release, "run")
    def test_existing_tag_is_not_overwritten(self, command, validation):
        validation.return_value = {"version": "1.1.1", "commit": "b" * 40}
        command.return_value = json.dumps([{"ref": "refs/tags/v1.1.1"}])
        with self.assertRaisesRegex(ValueError, "already exists"):
            release.publish(self.root, self.notes)
        self.assertFalse(any(call.args[:3] == ("gh", "release", "create")
                             for call in command.call_args_list))


if __name__ == "__main__":
    unittest.main()
