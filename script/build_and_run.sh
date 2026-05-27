#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TheSoftwareFactory"
BUNDLE_ID="local.softwarefactory.TheSoftwareFactory"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_DIR="$ROOT_DIR/apps/mac"
DIST_DIR="${SOFTWARE_FACTORY_APP_DIST_DIR:-${MULTIAGENT_APP_DIST_DIR:-$HOME/Library/Application Support/The Software Factory/Build}}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS="$ROOT_DIR/apps/mac/TheSoftwareFactory.entitlements"
DAEMON_BUNDLE_DIR="$DIST_DIR/Daemon"
DAEMON_ENTRY="$DAEMON_BUNDLE_DIR/nodeMain.cjs"
DAEMON_WORKFLOWS_DIR="$DAEMON_BUNDLE_DIR/workflows"
LEGACY_APP_BUNDLE="$ROOT_DIR/dist/MultiAgentDesktop.app"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "MultiAgentDesktop" >/dev/null 2>&1 || true
pkill -f "$ROOT_DIR/node_modules/.bin/tsx.*$ROOT_DIR/apps/daemon/src/nodeMain.ts" >/dev/null 2>&1 || true
pkill -f "node_modules/.bin/tsx.*apps/daemon/src/nodeMain.ts" >/dev/null 2>&1 || true
pkill -f "tsx/dist/loader.*apps/daemon/src/nodeMain.ts" >/dev/null 2>&1 || true
pkill -f "apps/daemon/src/nodeMain.ts" >/dev/null 2>&1 || true
pkill -f "$DAEMON_ENTRY" >/dev/null 2>&1 || true
rm -rf "$LEGACY_APP_BUNDLE"

swift build --package-path "$MAC_DIR"
BUILD_BINARY="$(swift build --package-path "$MAC_DIR" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE" "$DAEMON_BUNDLE_DIR"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

mkdir -p "$DAEMON_WORKFLOWS_DIR"
"$ROOT_DIR/node_modules/.bin/esbuild" "$ROOT_DIR/apps/daemon/src/nodeMain.ts" \
  --bundle \
  --platform=node \
  --format=cjs \
  --outfile="$DAEMON_ENTRY" \
  --log-level=warning
cp -R "$ROOT_DIR/apps/daemon/src/workflows/." "$DAEMON_WORKFLOWS_DIR/"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>The Software Factory</string>
  <key>CFBundleDisplayName</key>
  <string>The Software Factory</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>SoftwareFactoryDaemonEntry</key>
  <string>$DAEMON_ENTRY</string>
  <key>SoftwareFactoryBuiltinWorkflowsDir</key>
  <string>$DAEMON_WORKFLOWS_DIR</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

find_codesign_identity() {
  if [[ -n "${MULTIAGENT_CODESIGN_IDENTITY:-}" ]]; then
    echo "$MULTIAGENT_CODESIGN_IDENTITY"
    return
  fi
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/"Apple Development:|Developer ID Application:|Mac Developer:/{ print $2; exit }'
}

sign_app() {
  local identity
  identity="$(find_codesign_identity)"
  if [[ -n "$identity" ]]; then
    if /usr/bin/codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$identity" "$APP_BUNDLE"; then
      return
    fi
    echo "warning: codesign identity '$identity' failed; falling back to ad-hoc signing" >&2
  fi
  /usr/bin/codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP_BUNDLE"
}

sign_app

open_app() {
  /usr/bin/open -n -g "$APP_BUNDLE"
}

open_mockup_fixture() {
  /usr/bin/open -n -g "$APP_BUNDLE" --args --software-factory-mockup-fixture
}

case "$MODE" in
  run)
    open_app
    ;;
  --mockup-fixture|mockup-fixture)
    open_mockup_fixture
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--mockup-fixture|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
