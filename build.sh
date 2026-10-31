#!/bin/zsh
# Build Google Remote Voice.app from source. Requires Xcode Command Line Tools.
#   xcode-select --install
set -e
cd "$(dirname "$0")"

mkdir -p build
STAGE="$(mktemp -d build/candidate.XXXXXX)"
APP="$STAGE/Google Remote Voice.app"
if [ -n "${GOOGLE_REMOTE_SIGNING_IDENTITY:-}" ]; then
  SIGNING_IDENTITY="$GOOGLE_REMOTE_SIGNING_IDENTITY"
elif [ -f .local-signing-identity ]; then
  read -r SIGNING_IDENTITY < .local-signing-identity
else
  SIGNING_IDENTITY="-"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Apple Silicon build, minimum macOS 14. Intel builds are not validated.
swiftc -O \
  -target arm64-apple-macos14.0 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/GoogleRemoteVoice"

swiftc -O -target arm64-apple-macos14.0 \
  Sources/GoogleCaptureCore.swift Helpers/main.swift \
  -o "$APP/Contents/MacOS/GoogleRemoteCapture"

# Ad-hoc sign so it runs locally (first launch: right-click > Open).
xattr -cr "$APP" 2>/dev/null || true
codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/GoogleRemoteCapture"
codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
if [ -d "build/Google Remote Voice.app" ]; then
  mv "build/Google Remote Voice.app" "build/Google Remote Voice.previous.$(date +%s).app"
fi
mv "$APP" "build/Google Remote Voice.app"
rmdir "$STAGE"
APP="build/Google Remote Voice.app"

echo "✅ Built: $APP"
echo "   打开：open \"$APP\"   （首次右键→打开）"
