"""Explicit local installation with verified staging and retained rollback.

No overlay copy, deletion of an old app, or credential/user-data access occurs.
The caller supplies the previously verified manifest and signature verifier.
"""
import os
import importlib.util
from pathlib import Path
import plistlib
import signal
import stat
import subprocess
import tempfile
import time
import shutil
import sys

sys.dont_write_bytecode = True
_bundle_spec = importlib.util.spec_from_file_location("aimeter_install_bundle", Path(__file__).resolve().with_name("app_bundle.py"))
bundle_tools = importlib.util.module_from_spec(_bundle_spec)
_bundle_spec.loader.exec_module(bundle_tools)


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True).stdout


def process_ids(app, runner=run, *, include_widget=True):
    paths = {str(Path(app) / "Contents/MacOS/AIMeter")}
    if include_widget:
        paths.add(str(Path(app) / "Contents/PlugIns/AIMeterWidget.appex/Contents/MacOS/AIMeterWidgetExtension"))
    result = []
    for line in runner("/bin/ps", "-axo", "pid=,comm=").splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and int(fields[0]) > 0 and fields[1] in paths:
            result.append(int(fields[0]))
    return result


def stop(app):
    for pid in process_ids(app):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for _ in range(100):
        if not process_ids(app):
            return
        time.sleep(0.1)
    raise ValueError("The current app did not stop; installation was not started.")


def register(app):
    run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", app)
    run("/usr/bin/pluginkit", "-a", Path(app) / "Contents/PlugIns/AIMeterWidget.appex")


def launch(app, runner=run, sleeper=time.sleep):
    runner("/usr/bin/open", "-n", app)
    for _ in range(100):
        started = set(process_ids(app, runner, include_widget=False))
        if started:
            # WidgetKit can independently revive the extension. Only the same
            # main executable staying alive establishes a successful launch.
            for _ in range(10):
                sleeper(0.1)
                if not started.intersection(process_ids(app, runner, include_widget=False)):
                    raise ValueError("The updated main app exited during launch verification.")
            return
        sleeper(0.1)
    raise ValueError("The updated app did not start.")


def copy_bundle(source, destination):
    # A link introduced after the initial check must remain a link so staging
    # validation rejects it, rather than dereferencing a private source file.
    return shutil.copytree(source, destination, symlinks=True)


def verify_previous(app, runner=run):
    """An old version needs its own identity/payload/signature validation.

    Its version, source SHA and bytes intentionally differ from the candidate.
    Preserving an unknown old bundle is not permission to auto-launch it.
    """
    app = Path(app)
    bundle_tools.structure(app, signed=True)
    for bundle, identifier, executable in (
        (app, bundle_tools.APP_ID, "AIMeter"),
        (bundle_tools.bundles(app)[0], bundle_tools.WIDGET_ID, "AIMeterWidgetExtension")):
        with (bundle / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleIdentifier") != identifier or info.get("CFBundleExecutable") != executable:
            raise ValueError("Previous app identity is not an approved rollback target.")
        runner("/usr/bin/codesign", "--verify", "--strict", bundle)
    runner("/usr/bin/codesign", "--verify", "--deep", "--strict", app)


def install(app, destination, verify, *, stop_app=stop, register_app=register,
            launch_app=launch, copy_app=copy_bundle, rename=os.rename,
            verify_previous_app=verify_previous):
    app, destination = Path(app), Path(destination)
    if destination.name != "AIMeter.app" or not destination.is_absolute():
        raise ValueError("Select an absolute AIMeter.app installation target.")
    if destination.is_symlink() or destination.parent.is_symlink():
        raise ValueError("Installation target must not be a symlink.")
    if not stat.S_ISDIR(destination.parent.lstat().st_mode):
        raise ValueError("Installation parent must be a directory.")
    verify(app)
    previous_exists = destination.exists()
    if previous_exists:
        if not stat.S_ISDIR(destination.lstat().st_mode):
            raise ValueError("Existing installation is not an app directory.")
        with (destination / "Contents/Info.plist").open("rb") as stream:
            if plistlib.load(stream).get("CFBundleIdentifier") != "com.local.AIMeter":
                raise ValueError("Existing installation has a different identity.")
        verify_previous_app(destination)
    # mkdtemp reserves a non-shared directory on the destination volume. Both
    # renames therefore switch complete directories rather than copy in place.
    retained = Path(tempfile.mkdtemp(prefix=".AIMeter-retained-", dir=destination.parent))
    candidate = retained / "candidate.app"
    previous = retained / "previous.app"
    copy_app(app, candidate)
    verify(candidate)
    stop_app(destination)
    old_moved = False
    new_moved = False
    try:
        if previous_exists:
            rename(destination, previous)
            old_moved = True
        rename(candidate, destination)
        new_moved = True
        verify(destination)
        register_app(destination)
        launch_app(destination)
    except Exception as original:
        # Preserve the failed candidate too. Never recover by overlaying files,
        # deleting the old bundle, or restoring user preferences/credentials.
        try:
            if new_moved:
                stop_app(destination)
                rename(destination, candidate)
            if old_moved:
                verify_previous_app(previous)
                rename(previous, destination)
                register_app(destination)
                launch_app(destination)
        except Exception as recovery:
            raise ValueError("Installation failed and automatic recovery is incomplete; retained bundles are preserved.") from recovery
        raise ValueError("Installation failed; the previous installation state was restored.") from original
    return previous if old_moved else None
