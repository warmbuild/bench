#!/usr/bin/env bash
# The DerivedData snapshot experiment of the bench: does Xcode build incrementally on a fresh
# runner from another runner's DerivedData, when the checkout is at the same path and its files get
# their old modification times back?
#   bench-snapshot.sh save <checkout dir> <DerivedData dir> <snapshot dir>
#   bench-snapshot.sh restore <checkout dir> <DerivedData dir> <snapshot dir>
set -euo pipefail
action="$1"
checkout="$2"
derived="$3"
snapshot="$4"
here="$(cd "$(dirname "$0")" && pwd)"
archive="$snapshot/derived.tar.zst"

# A restored file has another inode than the one the build recorded; without this Xcode takes
# every such file as changed.
defaults write com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges -bool YES

start=$SECONDS
if [ "$action" = save ]; then
  mkdir -p "$snapshot"
  python3 "$here/bench-mtimes.py" save "$checkout" "$snapshot/mtimes.json"
  # pax keeps modification times to the nanosecond, which Xcode compares.
  tar --format pax -C "$derived" -cf - . | zstd -T0 -3 -q -o "$archive"
else
  python3 "$here/bench-mtimes.py" restore "$checkout" "$snapshot/mtimes.json"
  mkdir -p "$derived"
  zstd -dc "$archive" | tar -xpf - -C "$derived"
fi
size=$(du -m "$archive" | cut -f 1)
echo "$action: $((SECONDS - start))s, archive ${size} MB"
echo "Snapshot $action: $((SECONDS - start))s, archive ${size} MB" >> "$GITHUB_STEP_SUMMARY"
