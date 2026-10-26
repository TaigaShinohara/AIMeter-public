#!/usr/bin/env python3
"""Manual macOS release pipeline. Requires Python 3.9+, Xcode and gh."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parent.parent
GITHUB_REPO = "TaigaShinohara/AIMeter-public"
APP_ID = "com.local.AIMeter"
WIDGET_ID = APP_ID + ".widget"
ARCHITECTURES = {"arm64", "x86_64"}


def run(*args, cwd=None):
    result = subprocess.run(
        [str(arg) for arg in args], cwd=cwd, check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    return result.stdout


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    # Readers only see complete metadata, including on an interrupted run.
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, indent=2) + "\n")
    temp.replace(path)


def check_version(version, build_number):
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        raise ValueError("Version must be three numeric components, e.g. 1.1.1.")
    if not re.fullmatch(r"[1-9]\d*", build_number):
        raise ValueError("Build number must be a positive integer.")


def bundles(app):
    return [app / "Contents/PlugIns/AIMeterWidget.appex", app]


def verify_bundle(app, version, build_number):
    for bundle, identifier, executable in (
        (app, APP_ID, "AIMeter"),
        (bundles(app)[0], WIDGET_ID, "AIMeterWidgetExtension"),
    ):
        with (bundle / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        for key, expected in {
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": executable,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build_number,
            "LSMinimumSystemVersion": "14.0",
        }.items():
            if info.get(key) != expected:
                raise ValueError("Unexpected bundle metadata: " + key)
        binary = bundle / "Contents/MacOS" / executable
        actual = set(run("/usr/bin/lipo", "-archs", binary).split())
        if actual != ARCHITECTURES:
            raise ValueError("App and widget must both contain arm64 and x86_64.")
        minimums = re.findall(r"^\s+minos\s+(\S+)", run(
            "/usr/bin/xcrun", "vtool", "-show-build", binary), re.MULTILINE)
        if minimums != ["14.0", "14.0"]:
            raise ValueError("Both Mach-O slices must target macOS 14.0.")
        # Reject accidental dependencies on build-machine libraries.
        for line in run("/usr/bin/otool", "-L", binary).splitlines():
            dependency = line.strip().split(" (", 1)[0]
            if line.startswith(("\t", " ")) and " (" in line and not dependency.startswith(
                    ("/System/Library/", "/usr/lib/")):
                raise ValueError("Non-system library dependency: " + dependency)


def package_app(source, binaries, app, version, build_number, commit):
    for bundle, executable, identifier, package_type in (
        (app, "AIMeter", APP_ID, "APPL"),
        (bundles(app)[0], "AIMeterWidgetExtension", WIDGET_ID, "XPC!"),
    ):
        contents = bundle / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        shutil.copy2(binaries / executable, contents / "MacOS" / executable)
        (contents / "MacOS" / executable).chmod(0o755)
        shutil.copy2(source / "Sources/AIMeter/Resources/AppIcon.icns",
                     contents / "Resources/AppIcon.icns")
        info = {
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": identifier,
            "CFBundleName": "AIMeter" if package_type == "APPL" else "AIMeterWidget",
            "CFBundleDisplayName": "AI Meter",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": package_type,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build_number,
            "CFBundleSupportedPlatforms": ["MacOSX"],
            "LSMinimumSystemVersion": "14.0",
            "AIMeterSourceCommit": commit,
        }
        if package_type == "XPC!":
            info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
        else:
            info.update({
                "LSUIElement": False,
                "NSHighResolutionCapable": True,
                "CFBundleURLTypes": [{
                    "CFBundleURLName": APP_ID, "CFBundleURLSchemes": ["aimeter"],
                }],
            })
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
    # Only allowlisted resources enter the public bundle.
    shutil.copy2(source / "LICENSE", app / "Contents/Resources/LICENSE")
    verify_bundle(app, version, build_number)


def build(output, version, build_number):
    check_version(version, build_number)
    if output == REPO or REPO in output.parents:
        raise ValueError("Use a new output directory outside the repository.")
    if run("git", "status", "--porcelain", cwd=REPO).strip():
        raise ValueError("Commit the intended changes and use a clean checkout first.")
    commit = run("git", "rev-parse", "HEAD", cwd=REPO).strip()
    # New directory only: never overlay stale binaries or an existing release.
    output.mkdir(parents=True, exist_ok=False)
    source = output / "source"
    source.mkdir()
    archive = output / "source.tar"
    run("git", "archive", "--format=tar", "--output=" + str(archive), commit, cwd=REPO)
    run("/usr/bin/tar", "-xf", archive, "-C", source)
    scratch = output / "build"
    command = ["/usr/bin/swift", "build", "-c", "release", "-j", "2",
               "--arch", "arm64", "--arch", "x86_64", "--scratch-path", scratch]
    print("Building arm64 + x86_64 from " + commit, flush=True)
    # Preserve compiler output without reading any runtime usage data.
    with (output / "build.log").open("w") as log:
        subprocess.run([str(x) for x in command], cwd=source, check=True,
                       stdout=log, stderr=subprocess.STDOUT)
    binaries = Path(run(*command, "--show-bin-path", cwd=source).strip())
    package_app(source, binaries, output / "AIMeter.app", version, build_number, commit)
    write_json(output / "build.json", {
        "version": version, "build_number": build_number, "commit": commit,
    })
    print("Universal bundle built. NOT ready for distribution: run notarize next.")


def check_identity(identity, team):
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity) or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Specify a certificate SHA-1 fingerprint and a 10-character Team ID.")
    identities = run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning")
    pattern = (r'\b' + re.escape(identity) + r'\s+"Developer ID Application: '
               r'[^"\n]+ \(' + re.escape(team) + r'\)"')
    if not re.search(pattern, identities, re.IGNORECASE):
        raise ValueError("Matching valid Developer ID Application identity not found.")


def verify_signature(app, team):
    for bundle in bundles(app):
        run("/usr/bin/codesign", "--verify", "--strict", "--verbose=2", bundle)
        # codesign writes its display output to stderr, including on success.
        result = subprocess.run(
            ["/usr/bin/codesign", "-d", "--verbose=4", str(bundle)],
            check=True, capture_output=True, text=True,
        )
        details = result.stderr
        if (f"TeamIdentifier={team}\n" not in details
                or "Authority=Developer ID Application:" not in details
                or "Timestamp=" not in details or "runtime" not in details):
            raise ValueError("Missing Developer ID, team, secure timestamp or hardened runtime.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)


def zip_app(app, archive):
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)


def notarize(output, identity, team, profile):
    check_identity(identity, team)
    metadata = json.loads((output / "build.json").read_text())
    app = output / "AIMeter.app"
    verify_bundle(app, metadata["version"], metadata["build_number"])
    receipt = output / "release.json"
    if receipt.exists():
        raise ValueError("This output already has a completed notarization receipt.")
    # The app does not use App Group containers. Do not request restricted group
    # entitlements that need a provisioning profile for Developer ID distribution.
    entitlements = output / "widget-release.entitlements"
    with entitlements.open("wb") as stream:
        plistlib.dump({
            "com.apple.security.app-sandbox": True,
            "com.apple.security.temporary-exception.files.home-relative-path.read-only":
                ["/.ai_meter_widget.json"],
        }, stream)
    for bundle in bundles(app):
        command = ["/usr/bin/codesign", "--force", "--sign", identity,
                   "--options", "runtime", "--timestamp"]
        if bundle != app:
            command += ["--entitlements", entitlements]
        run(*command, bundle)
    verify_signature(app, team)
    submission_zip = output / "notary-upload.zip"
    zip_app(app, submission_zip)
    # Credentials stay in Keychain. No password or API key is accepted as an argument.
    print("Submitting to Apple; credential values are never logged.", flush=True)
    try:
        result = run("/usr/bin/xcrun", "notarytool", "submit", submission_zip,
                     "--keychain-profile", profile, "--wait", "--timeout", "20m",
                     "--output-format", "json")
    except subprocess.CalledProcessError as error:
        # Preserve an ID even if waiting timed out or Apple rejected the upload.
        # Keep only known non-secret fields, never authentication diagnostics.
        try:
            failed = json.loads(error.stdout or "{}")
            write_json(output / "notary-result.json",
                       {key: failed[key] for key in ("id", "status") if key in failed})
        except (ValueError, TypeError):
            pass
        raise
    submission = json.loads(result)
    write_json(output / "notary-result.json", submission)
    if submission.get("status") != "Accepted":
        raise ValueError("Apple has not accepted the submission; no release archive was created.")
    run("/usr/bin/xcrun", "stapler", "staple", app)
    run("/usr/bin/xcrun", "stapler", "validate", app)
    verify_signature(app, team)
    run("/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app)
    archive = output / f"AIMeter-{metadata['version']}-macos-universal.zip"
    zip_app(app, archive)
    digest = sha256(archive)
    (output / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
    write_json(receipt, dict(metadata, team=team, archive=archive.name, sha256=digest,
                             notarization_id=submission["id"]))
    print("Signed, notarized, stapled and Gatekeeper-verified. Ready for publish.")


def validate_release(output):
    metadata = json.loads((output / "release.json").read_text())
    check_version(metadata["version"], metadata["build_number"])
    expected_name = f"AIMeter-{metadata['version']}-macos-universal.zip"
    if metadata["archive"] != expected_name:
        raise ValueError("Unexpected archive filename.")
    archive = output / expected_name
    if sha256(archive) != metadata["sha256"]:
        raise ValueError("Release archive changed after notarization.")
    expected_checksum = f"{metadata['sha256']}  {expected_name}\n"
    if (output / "SHA256SUMS").read_text() != expected_checksum:
        raise ValueError("SHA256SUMS does not match the verified archive.")
    # Verify the exact archive to upload, not a separate loose app.
    with tempfile.TemporaryDirectory(prefix="aimeter-release-check-") as temporary:
        root = Path(temporary)
        run("/usr/bin/ditto", "-x", "-k", archive, root)
        app = root / "AIMeter.app"
        verify_bundle(app, metadata["version"], metadata["build_number"])
        with (app / "Contents/Info.plist").open("rb") as stream:
            if plistlib.load(stream).get("AIMeterSourceCommit") != metadata["commit"]:
                raise ValueError("Archive source commit does not match the receipt.")
        verify_signature(app, metadata["team"])
        run("/usr/bin/xcrun", "stapler", "validate", app)
        run("/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app)
    return metadata


def publish(output, validation_notes):
    metadata = validate_release(output)
    validation = validation_notes.read_text().strip()
    if not validation:
        raise ValueError("Provide the actual launch/Widget/OS verification results and limitations.")
    commit = metadata["commit"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid source commit.")
    # Only reviewed/merged source may be released; refresh the public main ref.
    run("git", "fetch", "https://github.com/" + GITHUB_REPO + ".git", "main", cwd=REPO)
    run("git", "merge-base", "--is-ancestor", commit, "FETCH_HEAD", cwd=REPO)
    tag = "v" + metadata["version"]
    existing = run("gh", "api", f"repos/{GITHUB_REPO}/git/matching-refs/tags/{tag}")
    if any(ref["ref"] == "refs/tags/" + tag for ref in json.loads(existing)):
        raise ValueError("Release tag already exists; inspect it instead of overwriting.")
    notes = output / "release-notes.md"
    notes.write_text(
        f"macOS 14以降 / Apple Silicon・Intel対応（Universal Binary）。\n\n"
        f"Developer ID署名・Apple公証・公証チケット添付済みです。\n\n"
        f"1. `{metadata['archive']}` をダウンロードして展開します。\n"
        "2. `AIMeter.app` をアプリケーションフォルダに移動します。\n"
        "3. Finderから開き、初期セットアップで使うサービスを選択します。\n\n"
        "Xcode・Pythonのインストールは不要です。詳細はリポジトリの導入ガイドを参照してください。\n\n"
        "## 動作確認の範囲\n\n" + validation + "\n\n"
        f"ソース: `{commit}` / build {metadata['build_number']}\n"
    )
    # Create a draft first. The release becomes public only after asset digests match.
    run("gh", "release", "create", tag, str(output / metadata["archive"]),
        str(output / "SHA256SUMS"), "--repo", GITHUB_REPO, "--target", commit,
        "--title", "AIMeter " + metadata["version"], "--notes-file", notes, "--draft")
    # Drafts may not have a Git tag yet; the REST by-tag endpoint returns 404.
    # gh release view resolves drafts too, without creating or moving a tag.
    view = ("gh", "release", "view", tag, "--repo", GITHUB_REPO,
            "--json", "assets,isDraft,url,tagName,targetCommitish")
    remote = json.loads(run(*view))
    if (not remote["isDraft"] or remote["tagName"] != tag
            or remote["targetCommitish"] != commit):
        raise ValueError("Unexpected draft release or source commit; inspect before publishing.")
    expected = {metadata["archive"]: metadata["sha256"],
                "SHA256SUMS": sha256(output / "SHA256SUMS")}
    assets = {asset["name"]: asset for asset in remote["assets"]}
    for name, digest in expected.items():
        if assets.get(name, {}).get("digest") != "sha256:" + digest:
            raise ValueError("Uploaded asset digest not confirmed; release remains a draft.")
    run("gh", "release", "edit", tag, "--repo", GITHUB_REPO, "--draft=false")
    verified = json.loads(run(*view))
    if verified["isDraft"]:
        raise ValueError("Release is still a draft.")
    print(verified["url"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build", help="Build only; never signs or publishes")
    build_parser.add_argument("--version", required=True)
    build_parser.add_argument("--build-number", required=True)
    for subparser in (build_parser,
                      commands.add_parser("notarize", help="Sign, notarize, staple and verify"),
                      commands.add_parser("publish", help="Verify then publish GitHub Release")):
        subparser.add_argument("--output", required=True, type=Path)
        if subparser.prog.endswith(" notarize"):
            subparser.add_argument("--identity", required=True, help="Developer ID certificate SHA-1")
            subparser.add_argument("--team", required=True)
            subparser.add_argument("--keychain-profile", required=True)
        if subparser.prog.endswith(" publish"):
            subparser.add_argument("--validation-notes", required=True, type=Path,
                                   help="Markdown file with actual runtime test results/limitations")
    args = parser.parse_args()
    output = args.output.resolve()
    try:
        if args.command == "build":
            build(output, args.version, args.build_number)
        elif args.command == "notarize":
            notarize(output, args.identity, args.team, args.keychain_profile)
        else:
            publish(output, args.validation_notes)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        # Avoid echoing external command output, which may contain authentication details.
        if isinstance(error, subprocess.CalledProcessError):
            print(f"Failed: {Path(error.cmd[0]).name} exited {error.returncode}. "
                  "Inspect the local logs and any draft release before retrying.", file=sys.stderr)
        else:
            print("Failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
