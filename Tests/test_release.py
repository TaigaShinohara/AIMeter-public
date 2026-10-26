"""Distribution gates use synthetic bundles and mocked Apple/GitHub commands."""
import importlib.util
import json
from pathlib import Path
import plistlib
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
        if args[0] == "/usr/bin/lipo":
            return "arm64 x86_64\n"
        if args[0] == "/usr/bin/otool":
            return ("/tmp/build/binary (architecture arm64):\n"
                    "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n")
        if "vtool" in args:
            return "    minos 14.0\n    minos 14.0\n"
        return ""

    def package(self):
        source = self.root / "source"
        resources = source / "Sources/AIMeter/Resources"
        resources.mkdir(parents=True)
        (resources / "AppIcon.icns").write_bytes(b"synthetic icon")
        (resources / "personal-log.json").write_text("MUST NOT SHIP")
        (source / "LICENSE").write_text("synthetic license")
        binaries = self.root / "binaries"
        binaries.mkdir()
        for name in ("AIMeter", "AIMeterWidgetExtension"):
            (binaries / name).write_bytes(b"synthetic executable")
        release.package_app(source, binaries, self.app, "1.1.1", "3", "b" * 40)

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
    def test_notarization_grants_only_widget_snapshot_read_access(self, command, signature, identity):
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
        entitlements_path = self.root / "widget-release.entitlements"
        entitlements = plistlib.loads(entitlements_path.read_bytes())
        self.assertEqual(entitlements, {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.temporary-exception.files.home-relative-path.read-only":
                ["/.ai_meter_widget.json"],
        })
        signing = [call.args for call in command.call_args_list
                   if call.args[:2] == ("/usr/bin/codesign", "--force")]
        self.assertEqual(len(signing), 2)
        self.assertEqual(signing[0][-3:],
                         ("--entitlements", entitlements_path, release.bundles(self.app)[0]))
        self.assertNotIn("--entitlements", signing[1])

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
        valid = (f"TeamIdentifier={TEAM}\nAuthority=Developer ID Application: Example\n"
                 "Timestamp=Oct 20, 2026\nflags=0x10000(runtime)\n")
        for removed in (f"TeamIdentifier={TEAM}\n", "Timestamp=Oct 20, 2026\n",
                        "flags=0x10000(runtime)\n", "Authority=Developer ID Application: Example\n"):
            process.return_value = subprocess.CompletedProcess([], 0, "", valid.replace(removed, ""))
            with self.assertRaisesRegex(ValueError, "Missing Developer ID"):
                release.verify_signature(self.app, TEAM)
        process.return_value = subprocess.CompletedProcess([], 0, "", valid)
        release.verify_signature(self.app, TEAM)

    def receipt(self):
        archive = self.root / "AIMeter-1.1.1-macos-universal.zip"
        archive.write_bytes(b"synthetic archive")
        digest = release.sha256(archive)
        release.write_json(self.root / "release.json", {
            "archive": archive.name, "version": "1.1.1", "build_number": "3",
            "sha256": digest, "team": TEAM, "commit": "b" * 40,
        })
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
                    "isDraft": True, "tagName": "v1.1.1", "targetCommitish": "b" * 40,
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
                    "isDraft": state["draft"], "tagName": "v1.1.1",
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
        self.assertTrue(any(call.args == (
            "git", "fetch", "https://github.com/TaigaShinohara/AIMeter-public.git", "main"
        ) for call in command.call_args_list))
        creation = next(call.args for call in command.call_args_list
                        if call.args[:3] == ("gh", "release", "create"))
        self.assertEqual(creation[creation.index("--repo") + 1],
                         "TaigaShinohara/AIMeter-public")

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
                    "isDraft": True, "tagName": "v1.1.1", "targetCommitish": "c" * 40,
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
