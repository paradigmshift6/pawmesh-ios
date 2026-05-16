#!/usr/bin/env bash
# Install the MapLibre device-framework dSYM into an .xcarchive so App Store
# Connect doesn't reject the upload with "missing dSYM" warnings.
#
# MapLibre ships as a binary xcframework via SPM and (unlike a source-built
# framework) its dSYM doesn't end up in the archive automatically. We
# reconstruct it: read the resolved version from Package.resolved, download
# the matching dSYM zip from the maplibre-native release, verify the UUID
# against the framework binary in the archive, and drop it into dSYMs/ with
# the naming Apple expects.
#
# Usage: tools/install_maplibre_dsym.sh <path-to-xcarchive>
#   or:  tools/install_maplibre_dsym.sh   (defaults to build/*.xcarchive)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" ]]; then
  ARCHIVE="$(ls -td "$ROOT"/build/*.xcarchive 2>/dev/null | head -1 || true)"
  if [[ -z "$ARCHIVE" ]]; then
    echo "Usage: $0 <path-to-xcarchive>" >&2
    echo "Or place an archive in build/ first." >&2
    exit 1
  fi
fi
if [[ ! -d "$ARCHIVE" ]]; then
  echo "Not an xcarchive: $ARCHIVE" >&2
  exit 1
fi

# Resolve the version from the xcworkspace's Package.resolved
PACKAGE_RESOLVED="$ROOT/DogTracker.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [[ ! -f "$PACKAGE_RESOLVED" ]]; then
  echo "Package.resolved not found at $PACKAGE_RESOLVED — run tools/regen.sh first" >&2
  exit 1
fi

VERSION="$(/usr/bin/python3 - "$PACKAGE_RESOLVED" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for pin in data.get("pins", []):
    if pin.get("identity") == "maplibre-gl-native-distribution":
        print(pin["state"]["version"])
        break
PY
)"
if [[ -z "$VERSION" ]]; then
  echo "Could not find maplibre-gl-native-distribution in Package.resolved" >&2
  exit 1
fi
echo "MapLibre version: $VERSION"

FRAMEWORK_BIN="$ARCHIVE/Products/Applications/DogTracker.app/Frameworks/MapLibre.framework/MapLibre"
if [[ ! -f "$FRAMEWORK_BIN" ]]; then
  # Fallback for tools that put frameworks in a non-standard spot
  FRAMEWORK_BIN="$(find "$ARCHIVE/Products" -name MapLibre -path '*/MapLibre.framework/*' -type f | head -1)"
fi
if [[ ! -f "$FRAMEWORK_BIN" ]]; then
  echo "MapLibre framework binary not found inside archive" >&2
  exit 1
fi
EXPECTED_UUID="$(dwarfdump --uuid "$FRAMEWORK_BIN" | awk '{print $2; exit}')"
echo "Framework UUID: $EXPECTED_UUID"

# Idempotency: skip if we already installed a matching dSYM
DEST="$ARCHIVE/dSYMs/MapLibre.framework.dSYM"
DEST_DWARF="$DEST/Contents/Resources/DWARF/MapLibre"
if [[ -f "$DEST_DWARF" ]]; then
  EXISTING_UUID="$(dwarfdump --uuid "$DEST_DWARF" | awk '{print $2; exit}')"
  if [[ "$EXISTING_UUID" == "$EXPECTED_UUID" ]]; then
    echo "dSYM already present and UUID matches — nothing to do."
    exit 0
  fi
  echo "Existing dSYM UUID $EXISTING_UUID does not match — replacing."
  rm -rf "$DEST"
fi

# Download the device dSYM matching the resolved version
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
URL="https://github.com/maplibre/maplibre-native/releases/download/ios-v${VERSION}/MapLibre_ios_device.framework.dSYM.zip"
echo "Downloading $URL"
curl -fSL -o "$WORK/dsym.zip" "$URL"
unzip -q "$WORK/dsym.zip" -d "$WORK"

SRC_DSYM="$WORK/MapLibre_ios_device.framework.dSYM"
SRC_DWARF="$SRC_DSYM/Contents/Resources/DWARF/MapLibre_ios_device"
if [[ ! -f "$SRC_DWARF" ]]; then
  echo "Downloaded archive doesn't contain the expected DWARF binary" >&2
  exit 1
fi
DOWNLOADED_UUID="$(dwarfdump --uuid "$SRC_DWARF" | awk '{print $2; exit}')"
if [[ "$DOWNLOADED_UUID" != "$EXPECTED_UUID" ]]; then
  echo "Downloaded dSYM UUID $DOWNLOADED_UUID does not match archive framework UUID $EXPECTED_UUID" >&2
  echo "MapLibre may have re-rolled the binary for v$VERSION without bumping the tag." >&2
  exit 1
fi

# Install with the names Apple expects: MapLibre.framework.dSYM, DWARF/MapLibre
mkdir -p "$ARCHIVE/dSYMs"
cp -R "$SRC_DSYM" "$DEST"
mv "$DEST/Contents/Resources/DWARF/MapLibre_ios_device" "$DEST_DWARF"

PLIST="$DEST/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.apple.xcode.dsym.MapLibre" "$PLIST" >/dev/null
plutil -replace CFBundleName       -string "MapLibre" "$PLIST" >/dev/null
plutil -replace CFBundleExecutable -string "MapLibre" "$PLIST" >/dev/null

echo "Installed dSYM at $DEST"
echo "UUID: $(dwarfdump --uuid "$DEST_DWARF")"
