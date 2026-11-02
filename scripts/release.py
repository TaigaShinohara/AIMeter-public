#!/usr/bin/env python3
"""Manual macOS release pipeline. Requires Python 3.9+, Xcode and gh."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parent.parent
_bundle_spec = importlib.util.spec_from_file_location("aimeter_app_bundle", REPO / "scripts/app_bundle.py")
bundle_tools = importlib.util.module_from_spec(_bundle_spec)
_bundle_spec.loader.exec_module(bundle_tools)
GITHUB_REPO = "TaigaShinohara/AIMeter-public"
APP_ID = bundle_tools.APP_ID
WIDGET_ID = bundle_tools.WIDGET_ID
ARCHITECTURES = bundle_tools.ARCHITECTURES
WIDGET_SANDBOX = bundle_tools.WIDGET_SANDBOX
WIDGET_HOME_READ = bundle_tools.WIDGET_HOME_READ
APP_GROUPS = bundle_tools.APP_GROUPS


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
    bundle_tools.check_version(version, build_number)


def bundles(app):
    return bundle_tools.bundles(app)


def widget_contract(source=REPO):
    return bundle_tools.widget_contract(source)


def verify_widget_entitlements(app):
    _, expected = widget_contract()
    encoded = run("/usr/bin/codesign", "-d", "--entitlements", ":-", bundles(app)[0])
    try:
        actual = plistlib.loads(encoded.encode("utf-8"))
    except (ValueError, TypeError, plistlib.InvalidFileException) as error:
        raise ValueError("Cannot read signed Widget entitlements.") from error
    if not isinstance(actual, dict) or actual != expected or actual.get(WIDGET_SANDBOX) is not True:
        raise ValueError("Signed Widget entitlements do not match the display-cache contract.")


def verify_bundle(app, version, build_number, widget_filename=None, commit=None, update_channel=None):
    filename = widget_filename or widget_contract()[0]
    bundle_tools.verify_bundle(app, version, build_number, run, widget_filename=filename,
                               architectures=ARCHITECTURES, commit=commit, profile="distribution",
                               update_channel=update_channel)


def package_app(source, binaries, app, version, build_number, commit, *, prerelease=False):
    bundle_tools.package_app(source, binaries, app, version, build_number, commit, run,
                              architectures=ARCHITECTURES, profile="distribution",
                              update_channel="development" if prerelease else "stable")


def verify_receipt_channel(app, metadata):
    # A missing channel belongs to the older stable-only release format.
    channel = metadata.get("update_channel", "stable")
    with (app / "Contents/Info.plist").open("rb") as stream:
        embedded = plistlib.load(stream).get("AIMeterUpdateChannel", "stable")
    if channel not in {"stable", "development"} or embedded != channel:
        raise ValueError("Bundle update channel does not match the release receipt.")


def build(output, version, build_number, *, prerelease=False):
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
    package_app(source, binaries, output / "AIMeter.app", version, build_number, commit,
                prerelease=prerelease)
    write_json(output / "build.json", {
        "version": version, "build_number": build_number, "commit": commit,
        "update_channel": "development" if prerelease else "stable",
        "bundle_manifest": bundle_tools.manifest(output / "AIMeter.app"),
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
    bundle_tools.structure(app, signed=True)
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
    verify_widget_entitlements(app)


def zip_app(app, archive):
    bundle_tools.zip_app(app, archive)


def notarize(output, identity, team, profile):
    check_identity(identity, team)
    metadata = json.loads((output / "build.json").read_text())
    app = output / "AIMeter.app"
    verify_bundle(app, metadata["version"], metadata["build_number"], commit=metadata["commit"],
                  update_channel=metadata.get("update_channel"))
    verify_receipt_channel(app, metadata)
    receipt = output / "release.json"
    if receipt.exists():
        raise ValueError("This output already has a completed notarization receipt.")
    # Use the checked-in grant only after binding it to the Swift consumer.
    # App Groups are not used by the sharing code and remain development-only.
    _, widget_entitlements = widget_contract()
    entitlements = output / "widget-release.entitlements"
    with entitlements.open("wb") as stream:
        plistlib.dump(widget_entitlements, stream)
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
                             notarization_id=submission["id"],
                             bundle_manifest=bundle_tools.manifest(app)))
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
        expected = metadata.get("bundle_manifest")
        if not isinstance(expected, dict):
            raise ValueError("Release receipt has no verified bundle manifest; rebuild the candidate.")
        app = bundle_tools.extract_zip(archive, root, expected)
        verify_bundle(app, metadata["version"], metadata["build_number"], commit=metadata["commit"],
                      update_channel=metadata.get("update_channel"))
        verify_receipt_channel(app, metadata)
        with (app / "Contents/Info.plist").open("rb") as stream:
            if plistlib.load(stream).get("AIMeterSourceCommit") != metadata["commit"]:
                raise ValueError("Archive source commit does not match the receipt.")
        verify_signature(app, metadata["team"])
        run("/usr/bin/xcrun", "stapler", "validate", app)
        run("/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app)
    return metadata


def publish(output, validation_notes, *, prerelease=False):
    metadata = validate_release(output)
    expected_channel = "development" if prerelease else "stable"
    # Legacy receipts predate channels and can only describe stable releases.
    if metadata.get("update_channel", "stable") != expected_channel:
        raise ValueError("Release channel does not match the verified build; rebuild for the selected channel.")
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
    if prerelease:
        check_version(metadata["version"], metadata["build_number"])
        tag += "-dev." + metadata["build_number"]
    existing = run("gh", "api", f"repos/{GITHUB_REPO}/git/matching-refs/tags/{tag}")
    if any(ref["ref"] == "refs/tags/" + tag for ref in json.loads(existing)):
        raise ValueError("Release tag already exists; inspect it instead of overwriting.")
    notes = output / "release-notes.md"
    channel_note = ("開発版です。安定版の公開前に変更を試すための配布です。\n\n"
                    if prerelease else "")
    notes.write_text(channel_note +
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
    title = "AIMeter " + metadata["version"]
    channel_flags = ["--prerelease", "--latest=false"] if prerelease else []
    if prerelease:
        title += " 開発版 (build " + metadata["build_number"] + ")"
    run("gh", "release", "create", tag, str(output / metadata["archive"]),
        str(output / "SHA256SUMS"), "--repo", GITHUB_REPO, "--target", commit,
        "--title", title, "--notes-file", notes, "--draft", *channel_flags)
    # Drafts may not have a Git tag yet; the REST by-tag endpoint returns 404.
    # gh release view resolves drafts too, without creating or moving a tag.
    view = ("gh", "release", "view", tag, "--repo", GITHUB_REPO,
            "--json", "assets,isDraft,isPrerelease,url,tagName,targetCommitish")
    remote = json.loads(run(*view))
    if (not remote["isDraft"] or remote["tagName"] != tag
            or remote["targetCommitish"] != commit
            or remote.get("isPrerelease") is not prerelease):
        raise ValueError("Unexpected draft release or source commit; inspect before publishing.")
    expected = {metadata["archive"]: metadata["sha256"],
                "SHA256SUMS": sha256(output / "SHA256SUMS")}
    assets = {asset["name"]: asset for asset in remote["assets"]}
    for name, digest in expected.items():
        if assets.get(name, {}).get("digest") != "sha256:" + digest:
            raise ValueError("Uploaded asset digest not confirmed; release remains a draft.")
    run("gh", "release", "edit", tag, "--repo", GITHUB_REPO, "--draft=false", *channel_flags)
    verified = json.loads(run(*view))
    if verified["isDraft"]:
        raise ValueError("Release is still a draft.")
    if (verified.get("isPrerelease") is not prerelease or verified["tagName"] != tag
            or verified["targetCommitish"] != commit):
        raise ValueError("Published release channel or source changed; inspect the release.")
    print(verified["url"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build", help="Build only; never signs or publishes")
    build_parser.add_argument("--version", required=True)
    build_parser.add_argument("--build-number", required=True)
    build_parser.add_argument("--prerelease", action="store_true",
                              help="Build a development-channel distribution candidate")
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
            subparser.add_argument("--prerelease", action="store_true",
                                   help="Publish a development prerelease without changing the latest stable release")
    args = parser.parse_args()
    output = args.output.resolve()
    try:
        if args.command == "build":
            build(output, args.version, args.build_number, prerelease=args.prerelease)
        elif args.command == "notarize":
            notarize(output, args.identity, args.team, args.keychain_profile)
        else:
            publish(output, args.validation_notes, prerelease=args.prerelease)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
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
