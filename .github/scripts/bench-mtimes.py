#!/usr/bin/env python3
"""Modification times of a checkout, for the DerivedData snapshot experiment of the bench.

  bench-mtimes.py save <checkout> <manifest>     record every file's content hash and time
  bench-mtimes.py restore <checkout> <manifest>  give a file its recorded time when its content
                                                 is the same

git gives every file of a fresh clone the time of the clone, and Xcode's incremental build compares
times, so a restored DerivedData is only up to date for files that get their old times back.
"""
import hashlib
import json
import os
import sys

DIRECTORY = "directory"


def content_hash(path):
    if os.path.islink(path):
        return "link:" + os.readlink(path)
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def entries(checkout):
    for folder, folders, files in os.walk(checkout):
        folders[:] = [name for name in folders if name != ".git"]
        yield folder, DIRECTORY
        for name in files:
            if name != ".git":
                path = os.path.join(folder, name)
                yield path, content_hash(path)


def save(checkout, manifest):
    recorded = {}
    for path, kind in entries(checkout):
        time = os.lstat(path).st_mtime_ns
        recorded[os.path.relpath(path, checkout)] = [kind, time]
    with open(manifest, "w") as file:
        json.dump(recorded, file)
    print(f"recorded {len(recorded)} paths")


def restore(checkout, manifest):
    with open(manifest) as file:
        recorded = json.load(file)
    current = {os.path.relpath(path, checkout): kind for path, kind in entries(checkout)}
    restored = 0
    for relative, (kind, time) in recorded.items():
        if current.get(relative) == kind:
            path = os.path.join(checkout, relative)
            os.utime(path, ns=(time, time), follow_symlinks=False)
            restored += 1
    changed = sorted(set(current) - {r for r, (k, _) in recorded.items() if current.get(r) == k})
    print(f"restored {restored} of {len(recorded)} times; {len(changed)} paths are new or changed")
    for relative in changed[:40]:
        print(f"  changed: {relative}")


if __name__ == "__main__":
    {"save": save, "restore": restore}[sys.argv[1]](sys.argv[2], sys.argv[3])
