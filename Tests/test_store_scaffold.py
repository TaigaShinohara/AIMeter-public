"""Static checks for the deliberately non-runnable App Store scaffold."""
import plistlib
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "AppStore" / "Configuration"


def load(name):
    with (CONFIG / name).open("rb") as stream:
        return plistlib.load(stream)


class StoreScaffoldTests(unittest.TestCase):
    def test_host_and_widget_identity_placeholders_match(self):
        app = load("App-Info.plist")
        widget = load("Widget-Info.plist")
        keys = ("AIMeterDistribution", "AIMeterAppGroupIdentifier", "AIMeterKeychainService",
                "AIMeterWidgetKind", "AIMeterURLScheme")
        for key in keys:
            self.assertEqual(app[key], widget[key], key)
        self.assertEqual(app["AIMeterDistribution"], "app-store")
        self.assertEqual(app["CFBundleURLTypes"][0]["CFBundleURLSchemes"], [app["AIMeterURLScheme"]])

    def test_sandbox_and_widget_group_do_not_use_home_exception(self):
        app, widget = load("App.entitlements"), load("Widget.entitlements")
        self.assertTrue(app["com.apple.security.app-sandbox"])
        self.assertTrue(widget["com.apple.security.app-sandbox"])
        self.assertEqual(app["com.apple.security.application-groups"],
                         widget["com.apple.security.application-groups"])
        self.assertNotIn("com.apple.security.temporary-exception.files.home-relative-path.read-only", widget)
        self.assertNotIn("com.apple.security.network.client", widget)

    def test_both_targets_keep_build_guard_and_signing_disabled(self):
        project = (ROOT / "AppStore/AIMeterStore.xcodeproj/project.pbxproj").read_text()
        guard = (CONFIG / "StoreBuildGuard.swift").read_text()
        self.assertIn('#error(', guard)
        self.assertGreaterEqual(project.count("StoreBuildGuard.swift in Sources"), 4)
        self.assertEqual(project.count("CODE_SIGNING_ALLOWED = NO;"), 4)


if __name__ == "__main__":
    unittest.main()
