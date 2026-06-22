#!/bin/bash
# Build QmouseFix and assemble a runnable menu-bar .app bundle (ad-hoc signed).
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
SWIFT="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

APP_NAME="QmouseFix"
BUNDLE_ID="com.qmousefix.app"
VERSION="0.1.0"
OUT="build/${APP_NAME}.app"

echo "==> swift build -c release"
"$SWIFT" build -c release
BIN="$("$SWIFT" build -c release --show-bin-path)/${APP_NAME}"

echo "==> assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/${APP_NAME}"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>QmouseFix</string>
</dict>
</plist>
PLIST

# Sign with the stable local identity if present (run tools/setup-signing-cert.sh once).
# A fixed cert keeps the designated requirement constant across rebuilds, so Accessibility
# is granted ONCE and survives every rebuild. Fall back to ad-hoc if the cert isn't set up.
SIGN_HASH="$(security find-identity "$HOME/Library/Keychains/login.keychain-db" \
    | awk '/QmouseFix Local Signing/ {print $2; exit}')"
if [ -n "$SIGN_HASH" ]; then
    echo "==> signing with stable identity ($SIGN_HASH)"
    codesign --force --sign "$SIGN_HASH" --timestamp=none "$OUT" >/dev/null 2>&1
else
    echo "==> ad-hoc signing (run tools/setup-signing-cert.sh for a stable signature)"
    codesign --force --sign - --timestamp=none "$OUT" >/dev/null 2>&1
fi

echo "==> done: $(cd "$(dirname "$OUT")" && pwd)/${APP_NAME}.app"
