#!/usr/bin/env python3
"""Local build, explicit install, and launch; never publish or notarize."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import uuid
import zipfile


sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parent.parent


def sibling(name):
    spec = importlib.util.spec_from_file_location("aimeter_" + name, REPO / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bundle_tools = sibling("app_bundle")
installer = sibling("install_app")


def run(*args, cwd=None):
    return subprocess.run([str(arg) for arg in args], cwd=cwd, check=True,
                          capture_output=True, text=True).stdout


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with temporary.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    temporary.replace(path)


def resources(repo, runner):
    for name in ("swift-build", "swift-test", "xcodebuild"):
        try:
            runner("/usr/bin/pgrep", "-x", name)
        except subprocess.CalledProcessError as error:
            if error.returncode == 1:
                continue
            raise ValueError("Cannot check existing build processes.") from error
        raise ValueError("A build or test is already running.")
    runner("/usr/bin/memory_pressure", "-Q")
    if shutil.disk_usage(repo).free < 2 * 1024 ** 3:
        raise ValueError("Insufficient free disk space for a new local build.")


def verify_local(app, metadata, source=REPO, runner=run):
    bundle_tools.verify_bundle(app, metadata["version"], metadata["build_number"], runner,
                               widget_filename=bundle_tools.widget_contract(source)[0],
                               architectures=metadata["architectures"], commit=metadata["commit"],
                               profile="local", signed=True)
    bundle_tools.verify_manifest(app, metadata["bundle_manifest"])
    runner("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    for bundle, entitlement_file in ((Path(app), "AIMeter.entitlements"),
                                     (bundle_tools.bundles(app)[0], "AIMeterWidgetExtension.entitlements")):
        with (Path(source) / "scripts" / entitlement_file).open("rb") as stream:
            expected = plistlib.load(stream)
        encoded = runner("/usr/bin/codesign", "-d", "--entitlements", ":-", bundle)
        if plistlib.loads(encoded.encode()) != expected:
            raise ValueError("Local signed entitlements differ from the declared contract.")


def build(repo=REPO, *, output=None, version=bundle_tools.APP_VERSION,
          build_number=bundle_tools.LOCAL_BUILD_NUMBER, runner=run):
    repo = Path(repo)
    bundle_tools.check_version(version, build_number)
    resources(repo, runner)
    commit = runner("git", "rev-parse", "HEAD", cwd=repo).strip()
    dirty = bool(runner("git", "status", "--porcelain", cwd=repo).strip())
    output = Path(output) if output is not None else repo / ".build/local-packages" / uuid.uuid4().hex
    output.mkdir(parents=True, exist_ok=False)
    command = ("/usr/bin/swift", "build", "-c", "release", "-j", "2")
    # Compiler diagnostics stay local, outside the bundle/archive. No runtime
    # account data or environment dump is gathered for packaging.
    diagnostics = runner(*command, cwd=repo)
    (output / "build.log").write_text(diagnostics)
    binaries = Path(runner(*command, "--show-bin-path", cwd=repo).strip())
    architectures = sorted(set(runner("/usr/bin/lipo", "-archs", binaries / "AIMeter").split()))
    app = output / "AIMeter.app"
    bundle_tools.package_app(repo, binaries, app, version, build_number, commit, runner,
                              architectures=architectures, profile="local", dirty=dirty)
    identities = runner("/usr/bin/security", "find-identity", "-v", "-p", "codesigning")
    candidates = re.findall(r'\b([A-Fa-f0-9]{40})\s+"(?:Apple Development|Developer ID Application):[^"\n]+"', identities)
    identity = candidates[0] if candidates else "-"
    for bundle, entitlement_file in ((bundle_tools.bundles(app)[0], "AIMeterWidgetExtension.entitlements"),
                                     (app, "AIMeter.entitlements")):
        runner("/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none",
               "--sign", identity, "--entitlements", repo / "scripts" / entitlement_file, bundle)
    metadata = {"version": version, "build_number": build_number, "commit": commit,
                "dirty": dirty, "architectures": architectures, "profile": "local",
                "app": str(app.resolve()), "bundle_manifest": bundle_tools.manifest(app)}
    verify_local(app, metadata, source=repo, runner=runner)
    label = "universal" if set(architectures) == bundle_tools.ARCHITECTURES else "-".join(architectures)
    archive = output / ("AIMeter-" + version + "-macos-" + label + "-local.zip")
    bundle_tools.zip_app(app, archive)
    metadata["archive"] = str(archive.resolve())
    metadata["archive_sha256"] = bundle_tools.digest(archive)
    write_json(output / "local-build.json", metadata)
    pointer = repo / ".build/local-current.json"
    pointer.parent.mkdir(exist_ok=True)
    write_json(pointer, {"receipt": str((output / "local-build.json").resolve())})
    return metadata


def current(repo=REPO):
    repo = Path(repo)
    pointer_path = repo / ".build/local-current.json"
    if not stat.S_ISREG(pointer_path.lstat().st_mode):
        raise ValueError("Local build pointer must be a regular file.")
    pointer = json.loads(pointer_path.read_text())
    receipt = Path(pointer["receipt"])
    # A launcher pointer may select only our retained local packages, not a
    # credential file or arbitrary downloaded bundle elsewhere on the machine.
    receipt.resolve().relative_to((repo / ".build/local-packages").resolve())
    if receipt.is_symlink() or receipt.name != "local-build.json":
        raise ValueError("Invalid local build receipt path.")
    metadata = json.loads(receipt.read_text())
    app, archive = Path(metadata["app"]), Path(metadata["archive"])
    if (metadata.get("profile") != "local" or app.name != "AIMeter.app"
            or app.parent.resolve() != receipt.parent.resolve()
            or archive.parent.resolve() != receipt.parent.resolve() or archive.is_symlink()
            or not archive.name.startswith("AIMeter-") or not archive.name.endswith("-local.zip")):
        raise ValueError("Invalid local build receipt.")
    if bundle_tools.digest(metadata["archive"]) != metadata["archive_sha256"]:
        raise ValueError("Local build archive changed after verification.")
    return metadata


def source_newer(app, repo=REPO):
    executable = Path(app) / "Contents/MacOS/AIMeter"
    if not executable.is_file():
        return True
    built_at = executable.stat().st_mtime
    paths = [Path(repo) / "Package.swift"]
    paths += [path for directory in ("Sources", "scripts") for path in (Path(repo) / directory).rglob("*")
              if path.is_file() and "__pycache__" not in path.parts]
    return any(path.stat().st_mtime > built_at for path in paths)


def project_instances(repo=REPO, runner=run):
    root = (Path(repo) / ".build/local-packages").resolve()
    apps = set()
    for line in runner("/bin/ps", "-axo", "pid=,comm=").splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit() or int(fields[0]) <= 0:
            continue
        executable = Path(fields[1])
        try:
            parts = executable.resolve().relative_to(root).parts
        except ValueError:
            continue
        if (len(parts) == 5 and re.fullmatch(r"[0-9a-f]{32}", parts[0])
                and parts[1:] == ("AIMeter.app", "Contents", "MacOS", "AIMeter")):
            apps.add(executable.parents[2])
    return apps


def stop_for_restart(target):
    # Different retained local builds share the product's settings/data. Stop
    # only verified copies belonging to this checkout or the selected install,
    # so an opt-out launch cannot leave two writers running simultaneously.
    candidates = project_instances() | {Path(target)}
    for app in candidates:
        if installer.process_ids(app):
            installer.verify_previous(app)
            installer.stop(app)


def run_app(*, restart=False, force=False, allow_install=False):
    target = Path("/Applications/AIMeter.app")
    try:
        metadata = current()
    except (OSError, ValueError, KeyError, TypeError):
        metadata = None
    revision_changed = metadata is not None and metadata["commit"] != run("git", "rev-parse", "HEAD", cwd=REPO).strip()
    if force or metadata is None or revision_changed or source_newer(metadata["app"]):
        metadata = build()
        restart = True
    app = Path(metadata["app"])
    verify_local(app, metadata)
    can_install = allow_install and os.environ.get("AIMETER_INSTALL_TO_APPLICATIONS", "1") != "0"
    if can_install and os.access(target.parent, os.W_OK):
        different = not target.exists()
        if not different:
            try:
                verify_local(target, metadata)
            except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
                different = True
        if restart or different:
            for previous_local in project_instances():
                installer.verify_previous(previous_local)
                installer.stop(previous_local)
            installer.install(app, target, lambda value: verify_local(value, metadata))
        else:
            if not installer.process_ids(target, include_widget=False):
                stop_for_restart(target)
                installer.launch(target)
            else:
                run("/usr/bin/open", "aimeter://show")
    else:
        if restart or not installer.process_ids(app, include_widget=False):
            # The opt-out prevents installation, while an explicit rebuild or
            # restart may stop the verified currently running product.
            stop_for_restart(target)
        if not installer.process_ids(app, include_widget=False):
            installer.launch(app)
        else:
            run("/usr/bin/open", "aimeter://show")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    building = commands.add_parser("build", help="Build only, with a new bundle/archive")
    building.add_argument("--version", default=bundle_tools.APP_VERSION)
    building.add_argument("--build-number", default=bundle_tools.LOCAL_BUILD_NUMBER)
    running = commands.add_parser("run", help="Build if required and launch")
    running.add_argument("--restart", action="store_true")
    running.add_argument("--force-build", action="store_true")
    running.add_argument("--install", action="store_true", help="Explicitly permit local installation")
    installing = commands.add_parser("install", help="Explicitly install the verified current local build")
    installing.add_argument("--destination", type=Path, default=Path("/Applications/AIMeter.app"))
    qa = commands.add_parser("verify-qa", help="Verify isolated QA payload after signing")
    qa.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "build":
            build(version=args.version, build_number=args.build_number)
            print("[AIMeter] Verified local bundle and archive are ready.")
        elif args.command == "run":
            run_app(restart=args.restart, force=args.force_build, allow_install=args.install)
        elif args.command == "verify-qa":
            bundle_tools.verify_qa_structure(args.app)
        else:
            if os.environ.get("AIMETER_INSTALL_TO_APPLICATIONS", "1") == "0":
                raise ValueError("Local installation is disabled.")
            metadata = current()
            installer.install(metadata["app"], args.destination, lambda value: verify_local(value, metadata))
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError,
            plistlib.InvalidFileException, zipfile.BadZipFile):
        # A command's raw diagnostics may contain a local path or account name.
        print("[AIMeter] Local operation failed; existing artifacts were preserved.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
