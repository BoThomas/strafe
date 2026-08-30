#!/bin/bash
# release.sh — build, Developer ID sign, notarize, staple, and zip a strafe
# release. Runs LOCALLY on the owner's machine only (signing identity and the
# notary credential live in the local keychain — never in CI).
#
# One-time setup (stores an App Store Connect API key / app-specific password in
# the keychain under the profile name "strafe-notary"):
#
#     xcrun notarytool store-credentials strafe-notary
#
# Then just run:  ./Scripts/release.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="strafe"
BUNDLE_ID="com.rileycx.strafe"
BIN_NAME="strafe"

SIGN_IDENTITY="Developer ID Application: Riley Hennigh (5N6662JF83)"
NOTARY_PROFILE="strafe-notary"

BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

if [[ ! -f "$ROOT_DIR/VERSION" ]]; then
  echo "error: VERSION file not found at $ROOT_DIR/VERSION" >&2
  exit 1
fi
VERSION="$(tr -d ' \t\n\r' < "$ROOT_DIR/VERSION")"
YEAR="$(date +%Y)"
ZIP_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.zip"

# --- Preflight: notary credential must exist ------------------------------
# Fail loudly and early if the keychain profile is missing, with the exact
# one-time setup command.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
error: notary keychain profile "$NOTARY_PROFILE" not found (or not usable).

Set it up once with:

    xcrun notarytool store-credentials $NOTARY_PROFILE

You will be prompted for your Apple ID / Team ID and an app-specific password
(or an App Store Connect API key). This stores the credential in your keychain
so notarization can run non-interactively. Then re-run ./Scripts/release.sh.
EOF
  exit 1
fi

# --- Build (release, arm64, size-optimized) -------------------------------
RELEASE_FLAGS=(-c release --arch arm64 -Xswiftc -Osize -Xlinker -dead_strip)

echo "==> Building release (arm64, -Osize, dead-strip)…"
swift build "${RELEASE_FLAGS[@]}"

BIN_PATH="$(swift build "${RELEASE_FLAGS[@]}" --show-bin-path)/$BIN_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

# --- Assemble the bundle --------------------------------------------------
echo "==> Assembling $APP_NAME.app (version $VERSION)…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$BIN_NAME"

echo "==> Stripping symbols from shipped binary…"
strip -rSTx "$MACOS_DIR/$BIN_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © $YEAR Riley Hennigh. All rights reserved.</string>
</dict>
</plist>
PLIST

# --- Developer ID sign with hardened runtime ------------------------------
echo "==> Signing with Developer ID (hardened runtime, secure timestamp)…"
codesign --force --sign "$SIGN_IDENTITY" \
  --options runtime --timestamp \
  "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"

# --- Zip for notarization -------------------------------------------------
echo "==> Zipping for notarization…"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

# --- Notarize + staple ----------------------------------------------------
echo "==> Submitting to notary service (this waits for the result)…"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling the notarization ticket…"
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

# --- Re-zip the stapled app for distribution ------------------------------
echo "==> Re-zipping stapled app for release…"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo ""
echo "Release built: $ZIP_PATH"
echo "  version:   $VERSION"
echo "  signed by: $SIGN_IDENTITY"
echo "  notarized: yes (stapled)"
