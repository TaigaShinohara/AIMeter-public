#!/usr/bin/env python3
"""Control only one explicitly named synthetic QA fixture; never deletes data."""
import argparse
import ctypes
import os
import re
import stat
import sys

PREFIX = "aimeter-store-sandbox-qa-"
FIXTURE_MARKER = b"AIMETER_SANDBOX_QA_FIXTURE_V1\n"
INSIDE = b"AIMETER_INSIDE_SYNTHETIC\n"
OUTSIDE = b"AIMETER_OUTSIDE_SYNTHETIC\n"
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
# macOS <sys/stdio.h>: do not replace an existing destination.
RENAME_EXCL = 0x00000004


def checked_root_path(path):
    if not isinstance(path, str) or not re.fullmatch(
        r"/private/tmp/aimeter-store-sandbox-qa-[a-f0-9]{32}", path
    ):
        raise ValueError("fixture root must be an explicit, uniquely named /private/tmp child")
    return path


def write_new(directory_fd, name, data):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                 0o600, dir_fd=directory_fd)
    try:
        remaining = memoryview(data)
        while remaining:
            count = os.write(fd, remaining)
            if count <= 0:
                raise OSError("fixture write failed")
            remaining = remaining[count:]
    finally:
        os.close(fd)


def open_dir(parent_fd, name):
    return os.open(name, DIR_FLAGS, dir_fd=parent_fd)


def verify_root_entry(parent_fd, name, expected):
    current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (not stat.S_ISDIR(current.st_mode) or current.st_uid != os.geteuid()
            or stat.S_IMODE(current.st_mode) != 0o700
            or (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino)):
        raise ValueError("fixture root changed or has invalid ownership or permissions")


def open_root(path, create=False):
    name = os.path.basename(checked_root_path(path))
    parent_info = os.stat("/private/tmp", follow_symlinks=False)
    parent = os.open("/private/tmp", DIR_FLAGS)
    root = None
    try:
        opened_parent = os.fstat(parent)
        if (not stat.S_ISDIR(parent_info.st_mode)
                or (opened_parent.st_dev, opened_parent.st_ino) != (parent_info.st_dev, parent_info.st_ino)):
            raise ValueError("fixture parent changed")
        if create:
            # A new directory is required; never reuse an existing root.
            os.mkdir(name, 0o700, dir_fd=parent)
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (not stat.S_ISDIR(before.st_mode) or before.st_uid != os.geteuid()
                or stat.S_IMODE(before.st_mode) != 0o700):
            raise ValueError("fixture root has invalid ownership or permissions")
        root = open_dir(parent, name)
        opened_root = os.fstat(root)
        if ((opened_root.st_dev, opened_root.st_ino) != (before.st_dev, before.st_ino)
                or not stat.S_ISDIR(opened_root.st_mode) or opened_root.st_uid != os.geteuid()
                or stat.S_IMODE(opened_root.st_mode) != 0o700):
            raise ValueError("fixture root changed during open")
        verify_root_entry(parent, name, opened_root)
        return parent, root, name, opened_root
    except BaseException:
        if root is not None:
            os.close(root)
        os.close(parent)
        raise


def rename_exclusive_function():
    """Fail closed if macOS cannot provide atomic non-replacing rename."""
    try:
        rename = ctypes.CDLL(None, use_errno=True).renameatx_np
    except AttributeError as error:
        raise OSError("exclusive rename unavailable") from error
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    return rename


def rename_exclusive(rename, source_fd, source_name, dest_fd, dest_name):
    if rename(source_fd, os.fsencode(source_name), dest_fd, os.fsencode(dest_name), RENAME_EXCL) != 0:
        error = ctypes.get_errno()
        raise OSError(error, "exclusive rename failed")


def create_fixture(path):
    parent, root, name, root_info = open_root(path, create=True)
    try:
        write_new(root, ".fixture", FIXTURE_MARKER)
        os.mkdir("base", 0o700, dir_fd=root)
        os.mkdir("outside", 0o700, dir_fd=root)
        base = open_dir(root, "base")
        outside = open_dir(root, "outside")
        try:
            os.mkdir("selected", 0o700, dir_fd=base)
            os.mkdir("selected", 0o700, dir_fd=outside)
            selected = open_dir(base, "selected")
            other = open_dir(outside, "selected")
            try:
                write_new(selected, "marker.txt", INSIDE)
                write_new(other, "marker.txt", OUTSIDE)
            finally:
                os.close(other)
                os.close(selected)
        finally:
            os.close(outside)
            os.close(base)
        verify_root_entry(parent, name, root_info)
    finally:
        os.close(root)
        os.close(parent)


def checked_root(path):
    parent, fd, name, root_info = open_root(path)
    try:
        marker = os.open(".fixture", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
        try:
            metadata = os.fstat(marker)
            if not stat.S_ISREG(metadata.st_mode) or os.read(marker, 128) != FIXTURE_MARKER:
                raise ValueError("fixture marker is invalid")
        finally:
            os.close(marker)
        verify_root_entry(parent, name, root_info)
        return parent, fd, name, root_info
    except BaseException:
        os.close(fd)
        os.close(parent)
        raise


def replace(path, which):
    # Resolve the OS primitive before making the first change. There is no
    # non-atomic fallback on filesystems without RENAME_EXCL support.
    rename = rename_exclusive_function()
    parent, root, name, root_info = checked_root(path)
    try:
        outside = open_dir(root, "outside")
        try:
            other = open_dir(outside, "selected")
            os.close(other)
        finally:
            os.close(outside)
        base = open_dir(root, "base")
        try:
            selected = open_dir(base, "selected")
            os.close(selected)
            verify_root_entry(parent, name, root_info)
            if which == "root":
                rename_exclusive(rename, base, "selected", base, "kept-selected")
                os.symlink("../outside/selected", "selected", dir_fd=base)
            elif which == "directory":
                other_parent = open_dir(root, "outside")
                try:
                    rename_exclusive(rename, base, "selected", base, "kept-selected")
                    rename_exclusive(rename, other_parent, "selected", base, "selected")
                finally:
                    os.close(other_parent)
            else:
                rename_exclusive(rename, root, "base", root, "kept-base")
                os.symlink("outside", "base", dir_fd=root)
        finally:
            os.close(base)
        verify_root_entry(parent, name, root_info)
    finally:
        os.close(root)
        os.close(parent)


def main():
    parser = argparse.ArgumentParser(description="Synthetic sandbox QA fixture controller")
    parser.add_argument("operation", choices=["init", "replace-root", "replace-parent", "replace-directory"])
    parser.add_argument("root", help="explicit /private/tmp fixture root")
    args = parser.parse_args()
    try:
        if args.operation == "init":
            create_fixture(args.root)
        else:
            replace(args.root, {"replace-root": "root", "replace-parent": "parent",
                                "replace-directory": "directory"}[args.operation])
        print("FIXTURE_OPERATION_OK")
    except (OSError, ValueError):
        # Do not print filesystem paths or exception strings.
        print("FIXTURE_OPERATION_FAILED", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
