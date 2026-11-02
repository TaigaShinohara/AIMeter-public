"""Shared, explicit app-bundle construction and artifact validation.

Only the listed payload enters a new bundle. Build products, user data and old
bundles are never recursive-copy inputs. No command here publishes or installs.
"""
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import stat
import zipfile


APP_ID = "com.local.AIMeter"
WIDGET_ID = APP_ID + ".widget"
ARCHITECTURES = {"arm64", "x86_64"}
APP_VERSION = "1.2.0"
LOCAL_BUILD_NUMBER = "1"
WIDGET_SANDBOX = "com.apple.security.app-sandbox"
WIDGET_HOME_READ = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
APP_GROUPS = "com.apple.security.application-groups"
WIDGET = Path("Contents/PlugIns/AIMeterWidget.appex")
PAYLOAD = {
    "Contents/MacOS/AIMeter", "Contents/Info.plist",
    "Contents/Resources/AppIcon.icns", "Contents/Resources/LICENSE",
    str(WIDGET / "Contents/MacOS/AIMeterWidgetExtension"),
    str(WIDGET / "Contents/Info.plist"),
    str(WIDGET / "Contents/Resources/AppIcon.icns"),
}
SIGNATURE_FILES = {"Contents/_CodeSignature/CodeResources",
                   str(WIDGET / "Contents/_CodeSignature/CodeResources")}
NOTARIZATION_FILES = {"Contents/CodeResources"}


def check_version(version, build_number):
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        raise ValueError("Version must be three numeric components.")
    if not re.fullmatch(r"[1-9]\d*", build_number):
        raise ValueError("Build number must be a positive integer.")


def bundles(app):
    return [Path(app) / WIDGET, Path(app)]


def widget_contract(source):
    source = Path(source)
    implementation_path = source / "Sources/AIMeterCore/SharedStore.swift"
    regular(implementation_path, root=source)
    implementation = implementation_path.read_text()
    filenames = re.findall(
        r'public\s+static\s+let\s+widgetSnapshotFileURL\s*=\s*'
        r'localUsageFileURL\.deletingLastPathComponent\(\)\s*'
        r'\.appendingPathComponent\("([.A-Za-z0-9_-]{1,128})"\)', implementation)
    if len(filenames) != 1 or not filenames[0].startswith(".") or not filenames[0].endswith(".json"):
        raise ValueError("Cannot establish the Widget display-cache source contract.")
    filename = filenames[0]
    entitlement_path = source / "scripts/AIMeterWidgetExtension.entitlements"
    regular(entitlement_path, root=source)
    with entitlement_path.open("rb") as stream:
        development = plistlib.load(stream)
    if (not isinstance(development, dict)
            or set(development) - {WIDGET_SANDBOX, WIDGET_HOME_READ, APP_GROUPS}
            or development.get(WIDGET_SANDBOX) is not True
            or development.get(WIDGET_HOME_READ) != ["/" + filename]
            or development.get(APP_GROUPS, []) != ["group.com.local.AIMeter"]):
        raise ValueError("Development Widget entitlements do not match the display-cache contract.")
    return filename, {WIDGET_SANDBOX: True, WIDGET_HOME_READ: ["/" + filename]}


def regular(path, root=None):
    path = Path(path)
    if root is not None:
        root = Path(root)
        current = root
        for part in path.relative_to(root).parts[:-1]:
            current /= part
            if not stat.S_ISDIR(current.lstat().st_mode):
                raise ValueError("Bundle input ancestors must be real directories.")
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("Bundle inputs must be regular files.")


def structure(app, signed=None, allow_notarization=True):
    app = Path(app)
    if not stat.S_ISDIR(app.lstat().st_mode):
        raise ValueError("App must be a real directory.")
    expected = set(PAYLOAD)
    present = set()
    directories = set()
    for path in app.rglob("*"):
        relative = path.relative_to(app).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            directories.add(relative)
        elif stat.S_ISREG(mode):
            present.add(relative)
        else:
            raise ValueError("Bundle contains a link or special file.")
    signatures = present & SIGNATURE_FILES
    if signed is True or signatures:
        expected |= SIGNATURE_FILES
    if signed is False and signatures:
        raise ValueError("Unexpected signature resources before signing.")
    tickets = present & NOTARIZATION_FILES
    if tickets:
        if signed is False or not allow_notarization or signatures != SIGNATURE_FILES:
            raise ValueError("Unexpected notarization ticket in this build profile.")
        # stapler stores its signed ticket as this regular file, separately
        # from _CodeSignature/CodeResources. Preserve its bytes in the ZIP;
        # stapler validate remains the authority for its cryptographic validity.
        ticket = app / "Contents/CodeResources"
        with ticket.open("rb") as stream:
            header = stream.read(8)
        if header != b"s8ch\x01\0\0\0" or ticket.stat().st_size > 1024 * 1024:
            raise ValueError("Unexpected notarization ticket format.")
        expected |= NOTARIZATION_FILES
    if present != expected:
        raise ValueError("Bundle payload does not match the allowlist.")
    allowed_directories = {str(parent) for filename in expected
                           for parent in Path(filename).parents if str(parent) != "."}
    if directories != allowed_directories:
        raise ValueError("Bundle directories do not match the allowlist.")
    return sorted(present)


def verify_bundle(app, version, build_number, run, *, widget_filename,
                  architectures=ARCHITECTURES, commit=None, profile=None, signed=None,
                  update_channel=None):
    check_version(version, build_number)
    architectures = set(architectures)
    if not architectures or not architectures <= ARCHITECTURES:
        raise ValueError("Unsupported architecture set.")
    structure(app, signed=signed, allow_notarization=profile != "local")
    source_commit = None
    source_dirty = None
    channels = []
    for bundle, identifier, executable in (
        (Path(app), APP_ID, "AIMeter"), (bundles(app)[0], WIDGET_ID, "AIMeterWidgetExtension")):
        with (bundle / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        expected = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
                    "CFBundleShortVersionString": version, "CFBundleVersion": build_number,
                    "LSMinimumSystemVersion": "14.0", "AIMeterWidgetSnapshotFilename": widget_filename}
        if profile is not None:
            expected["AIMeterBuildProfile"] = profile
        if update_channel is not None:
            if update_channel not in {"stable", "development"}:
                raise ValueError("Invalid update channel.")
            expected["AIMeterUpdateChannel"] = update_channel
        for key, value in expected.items():
            if info.get(key) != value:
                raise ValueError("Unexpected bundle metadata: " + key)
        candidate = info.get("AIMeterSourceCommit", "")
        if not re.fullmatch(r"[0-9a-f]{40}", candidate) or (commit is not None and candidate != commit):
            raise ValueError("Unexpected bundle source commit.")
        if source_commit is not None and candidate != source_commit:
            raise ValueError("Host and Widget source commits differ.")
        source_commit = candidate
        dirty = info.get("AIMeterSourceDirty")
        if type(dirty) is not bool or (profile == "distribution" and dirty):
            raise ValueError("Unexpected dirty-source metadata.")
        if source_dirty is not None and source_dirty != dirty:
            raise ValueError("Host and Widget dirty-source metadata differ.")
        source_dirty = dirty
        channel = info.get("AIMeterUpdateChannel")
        if channel is not None and channel not in {"stable", "development"}:
            raise ValueError("Invalid update channel.")
        channels.append(channel)
        if len(channels) == 2 and channels[0] != channels[1]:
            raise ValueError("Host and Widget update channels differ.")
        binary = bundle / "Contents/MacOS" / executable
        actual = set(run("/usr/bin/lipo", "-archs", binary).split())
        if actual != architectures:
            raise ValueError("App and widget must both contain the expected architectures.")
        minimums = re.findall(r"^\s+minos\s+(\S+)", run("/usr/bin/xcrun", "vtool", "-show-build", binary), re.MULTILINE)
        if minimums != ["14.0"] * len(architectures):
            raise ValueError("Both Mach-O slices must target macOS 14.0.")
        for line in run("/usr/bin/otool", "-L", binary).splitlines():
            dependency = line.strip().split(" (", 1)[0]
            if line.startswith(("\t", " ")) and " (" in line and not dependency.startswith(("/System/Library/", "/usr/lib/")):
                raise ValueError("Non-system library dependency rejected.")


def package_app(source, binaries, app, version, build_number, commit, run,
                *, architectures=ARCHITECTURES, profile="distribution", dirty=False,
                update_channel=None):
    source, binaries, app = Path(source), Path(binaries), Path(app)
    check_version(version, build_number)
    if app.exists() or app.is_symlink():
        raise ValueError("Use a new app bundle; existing bundles are preserved.")
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or profile not in {"local", "distribution"}:
        raise ValueError("Invalid source commit or build profile.")
    if profile == "distribution" and dirty:
        raise ValueError("Distribution cannot contain a dirty working tree.")
    if update_channel is None:
        update_channel = "development" if profile == "local" else "stable"
    if update_channel not in {"stable", "development"}:
        raise ValueError("Invalid update channel.")
    filename, _ = widget_contract(source)
    for bundle, executable, identifier, package_type in (
        (app, "AIMeter", APP_ID, "APPL"),
        (bundles(app)[0], "AIMeterWidgetExtension", WIDGET_ID, "XPC!")):
        contents = bundle / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        for original, target in ((binaries / executable, contents / "MacOS" / executable),
                                 (source / "Sources/AIMeter/Resources/AppIcon.icns", contents / "Resources/AppIcon.icns")):
            regular(original, root=binaries if target.parent.name == "MacOS" else source)
            shutil.copyfile(original, target)
            target.chmod(0o755 if target.parent.name == "MacOS" else 0o644)
        info = {"CFBundleExecutable": executable, "CFBundleIdentifier": identifier,
                "CFBundleName": "AIMeter" if package_type == "APPL" else "AIMeterWidget",
                "CFBundleDisplayName": "AI Meter", "CFBundleIconFile": "AppIcon",
                "CFBundlePackageType": package_type, "CFBundleShortVersionString": version,
                "CFBundleVersion": build_number, "CFBundleSupportedPlatforms": ["MacOSX"],
                "LSMinimumSystemVersion": "14.0", "AIMeterSourceCommit": commit,
                "AIMeterBuildProfile": profile, "AIMeterSourceDirty": bool(dirty),
                "AIMeterUpdateChannel": update_channel,
                "AIMeterWidgetSnapshotFilename": filename}
        if package_type == "XPC!":
            info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
        else:
            info.update({"LSUIElement": False, "NSHighResolutionCapable": True,
                         "CFBundleURLTypes": [{"CFBundleURLName": APP_ID, "CFBundleURLSchemes": ["aimeter"]}]})
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
        (contents / "Info.plist").chmod(0o644)
    regular(source / "LICENSE", root=source)
    shutil.copyfile(source / "LICENSE", app / "Contents/Resources/LICENSE")
    (app / "Contents/Resources/LICENSE").chmod(0o644)
    verify_bundle(app, version, build_number, run, widget_filename=filename,
                  architectures=architectures, commit=commit, profile=profile, signed=False,
                  update_channel=update_channel)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def manifest(app):
    return {name: {"sha256": digest(Path(app) / name), "size": (Path(app) / name).stat().st_size,
                   "mode": stat.S_IMODE((Path(app) / name).stat().st_mode)}
            for name in structure(app)}


def verify_manifest(app, expected):
    if not isinstance(expected, dict) or manifest(app) != expected:
        raise ValueError("App content changed after verification.")


def zip_app(app, archive):
    app, archive = Path(app), Path(archive)
    expected = manifest(app)
    # Write bytes and ordinary mode bits only, never Finder metadata, ACLs,
    # extended attributes, AppleDouble entries, or build-machine ownership.
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED) as output:
        for name in expected:
            info = zipfile.ZipInfo("AIMeter.app/" + name)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | expected[name]["mode"]) << 16
            output.writestr(info, (app / name).read_bytes())
    verify_zip(archive, expected)


def verify_zip(archive, expected):
    if not isinstance(expected, dict) or set(expected) not in (PAYLOAD, PAYLOAD | SIGNATURE_FILES,
                                                            PAYLOAD | SIGNATURE_FILES | NOTARIZATION_FILES):
        raise ValueError("Archive manifest does not match the fixed payload allowlist.")
    for entry in expected.values():
        if (not isinstance(entry, dict) or set(entry) != {"sha256", "size", "mode"}
                or not isinstance(entry["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
                or type(entry["size"]) is not int or entry["size"] < 0
                or type(entry["mode"]) is not int or entry["mode"] not in {0o600, 0o644, 0o755}):
            raise ValueError("Invalid archive manifest fields.")
    with zipfile.ZipFile(archive) as source:
        names = source.namelist()
        if len(names) != len(set(names)) or set(names) != {"AIMeter.app/" + name for name in expected}:
            raise ValueError("Archive payload does not match the bundle manifest.")
        for name, entry in expected.items():
            info = source.getinfo("AIMeter.app/" + name)
            mode = info.external_attr >> 16
            if (info.file_size != entry["size"] or not stat.S_ISREG(mode)
                    or stat.S_IMODE(mode) != entry["mode"] or info.extra or info.comment):
                raise ValueError("Archive entry metadata does not match the bundle manifest.")
            if hashlib.sha256(source.read(info)).hexdigest() != entry["sha256"]:
                raise ValueError("Archive bytes do not match the bundle manifest.")


def extract_zip(archive, root, expected):
    verify_zip(archive, expected)
    app = Path(root) / "AIMeter.app"
    if app.exists() or app.is_symlink():
        raise ValueError("Archive extraction needs a new app path.")
    with zipfile.ZipFile(archive) as source:
        for name, entry in expected.items():
            # expected originated from the fixed bundle allowlist, and this
            # independent check also protects a forged receipt.
            if name not in PAYLOAD | SIGNATURE_FILES | NOTARIZATION_FILES:
                raise ValueError("Unsupported archive manifest path.")
            target = app / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as stream:
                stream.write(source.read("AIMeter.app/" + name))
            target.chmod(entry["mode"])
    verify_manifest(app, expected)
    return app


def verify_qa_structure(app):
    app = Path(app)
    pairs = [(app, "com.local.AIMeterWidgetQA", "AIMeterWidgetQAHost"),
             (app / "Contents/PlugIns/AIMeterWidgetQA.appex", "com.local.AIMeterWidgetQA.widget", "AIMeterWidgetQAExtension")]
    expected = set()
    for bundle, identifier, executable in pairs:
        relative = bundle.relative_to(app)
        expected |= {str(relative / "Contents/Info.plist"), str(relative / "Contents/MacOS" / executable),
                     str(relative / "Contents/_CodeSignature/CodeResources")}
        with (bundle / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleIdentifier") != identifier or info.get("CFBundleExecutable") != executable:
            raise ValueError("QA bundle identity is not isolated.")
    actual = set()
    directories = set()
    for path in app.rglob("*"):
        mode = path.lstat().st_mode
        if stat.S_ISREG(mode):
            actual.add(path.relative_to(app).as_posix())
        elif stat.S_ISDIR(mode):
            directories.add(path.relative_to(app).as_posix())
        else:
            raise ValueError("QA bundle contains a link or special file.")
    allowed_directories = {str(parent) for filename in expected for parent in Path(filename).parents if str(parent) != "."}
    if actual != expected or directories != allowed_directories:
        raise ValueError("QA bundle payload does not match the allowlist.")
