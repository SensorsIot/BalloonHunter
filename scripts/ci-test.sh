#!/usr/bin/env bash
set -euo pipefail

# CI helper to run unit + UI tests on a simulator.
# Defaults can be overridden via flags or env vars.

PROJECT=${PROJECT:-BalloonHunter.xcodeproj}
SCHEME=${SCHEME:-BalloonHunter-Tests}
DEVICE=${DEVICE:-iPhone 15}
OS_VERSION=${OS_VERSION:-}
BOOT_SIM=${BOOT_SIM:-false}

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  -p, --project <path>     Xcode project (default: $PROJECT)
  -s, --scheme <name>      Scheme to test (default: $SCHEME)
  -d, --device <name>      Simulator device name (default: $DEVICE)
  -o, --os <version>       iOS version (e.g., 17.5). Optional.
  -b, --boot               Attempt to boot the simulator before testing.
  -h, --help               Show this help.

Env overrides: PROJECT, SCHEME, DEVICE, OS_VERSION, BOOT_SIM=true

Examples:
  DEVICE="iPhone 15" $(basename "$0")
  $(basename "$0") -d "iPhone 15 Pro" -o 17.5 -b
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT="$2"; shift 2;;
    -s|--scheme)  SCHEME="$2"; shift 2;;
    -d|--device)  DEVICE="$2"; shift 2;;
    -o|--os)      OS_VERSION="$2"; shift 2;;
    -b|--boot)    BOOT_SIM=true; shift;;
    -h|--help)    usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild not found. Install Xcode and run: sudo xcode-select --switch /Applications/Xcode.app" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "xcrun not found. Install Xcode." >&2; exit 1; }

DEST="platform=iOS Simulator,name=${DEVICE}"
if [[ -n "${OS_VERSION}" ]]; then
  DEST=",OS=${OS_VERSION},${DEST}"
  # Correct order is platform first, but xcodebuild accepts any order in the comma list.
  DEST="platform=iOS Simulator,name=${DEVICE},OS=${OS_VERSION}"
fi

if [[ "$BOOT_SIM" == "true" ]]; then
  # Try to boot the first available UDID matching the device name (and OS if provided)
  # Falls back silently if parsing fails; xcodebuild can still launch a sim.
  if command -v plutil >/dev/null 2>&1; then
    # Prefer JSON for easier parsing when available
    if xcrun simctl list devices available -j >/dev/null 2>&1; then
      JSON=$(xcrun simctl list devices available -j)
      # Very light parsing using Python for robustness (macOS ships Python3 in recent versions)
      if command -v python3 >/dev/null 2>&1; then
        UDID=$(python3 - <<PY
import json,sys,os
j=json.loads(os.environ['JSON'])
name=os.environ['DEVICE']
want=os.environ.get('OS_VERSION','')
for runtime, devs in j.get('devices',{}).items():
    for d in devs:
        if not d.get('isAvailable'): continue
        if d.get('name')!=name: continue
        if want and want not in runtime: continue
        print(d.get('udid')); sys.exit(0)
sys.exit(1)
PY
        ) || true
        if [[ -n "${UDID:-}" ]]; then
          xcrun simctl bootstatus "$UDID" || xcrun simctl boot "$UDID" || true
        fi
      fi
    fi
  fi
fi

set -x
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  -enableCodeCoverage YES \
  test

