#!/bin/bash
# Builds "Claude Usage.app" into ./build. Pass "install" to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Claude Usage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target "$(uname -m)-apple-macos14.0" Sources/*.swift -o "$APP/Contents/MacOS/ClaudeUsage"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x ClaudeUsage || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Claude Usage.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"Claude Usage.app"
  echo "Installed to ~/Applications/Claude Usage.app"
fi
