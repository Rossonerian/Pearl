#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Pearl V2 - Release Packaging, Code Signing & Notarization Harness
# ==============================================================================
# Compiles Pearl.app and pearl-cli, performs inside-out hardened runtime signing,
# runs Gatekeeper verification, notarizes with Apple notarytool, staples, and
# packages distributable .dmg and .zip bundles.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
APP_NAME="Pearl"
BUNDLE_ID="ai.pearl.Pearl"
VERSION="3.2.0"
ENTITLEMENTS="${REPO_ROOT}/App/Pearl.entitlements"

# Defaults
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
PACKAGE_FORMAT="dmg" # "dmg", "zip", or "both"
ADHOC=false

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --sign <identity>        Code signing identity (e.g. "Developer ID Application: Team (XYZ)")
  --adhoc                  Perform ad-hoc signing (-) for local testing without certs
  --notary-profile <prof>  Keychain profile name for xcrun notarytool
  --dmg                    Package as .dmg (default)
  --zip                    Package as .zip
  --all-formats            Package both .dmg and .zip
  -h, --help               Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --adhoc)
            ADHOC=true
            SIGN_IDENTITY="-"
            shift
            ;;
        --notary-profile)
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --dmg)
            PACKAGE_FORMAT="dmg"
            shift
            ;;
        --zip)
            PACKAGE_FORMAT="zip"
            shift
            ;;
        --all-formats)
            PACKAGE_FORMAT="both"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

if [[ -z "${SIGN_IDENTITY}" && "${ADHOC}" == "false" ]]; then
    echo "Notice: No signing identity specified. Defaulting to ad-hoc signing (-)."
    echo "To sign with Apple Developer ID, pass --sign \"Developer ID Application: ...\""
    SIGN_IDENTITY="-"
    ADHOC=true
fi

echo "=============================================================================="
echo " Building Pearl v${VERSION} in Release Configuration"
echo "=============================================================================="
cd "${REPO_ROOT}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
echo "→ Using DEVELOPER_DIR: ${DEVELOPER_DIR}"

echo "→ Compiling release binaries via SwiftPM..."
DEVELOPER_DIR="${DEVELOPER_DIR}" swift build -c release

RELEASE_BIN_DIR="${REPO_ROOT}/.build/release"
PEARL_BIN="${RELEASE_BIN_DIR}/Pearl"
CLI_BIN="${RELEASE_BIN_DIR}/pearl-cli"

if [[ ! -f "${PEARL_BIN}" ]]; then
    echo "Error: Pearl binary not found at ${PEARL_BIN}"
    exit 1
fi

if [[ ! -f "${CLI_BIN}" ]]; then
    echo "Error: pearl-cli binary not found at ${CLI_BIN}"
    exit 1
fi

echo "=============================================================================="
echo " Assembling ${APP_NAME}.app Bundle"
echo "=============================================================================="
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}/${APP_NAME}.app/Contents/MacOS"
mkdir -p "${DIST_DIR}/${APP_NAME}.app/Contents/Helpers"
mkdir -p "${DIST_DIR}/${APP_NAME}.app/Contents/Resources"

# Copy executables
cp "${PEARL_BIN}" "${DIST_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
cp "${CLI_BIN}" "${DIST_DIR}/${APP_NAME}.app/Contents/Helpers/pearl-cli"
chmod +x "${DIST_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
chmod +x "${DIST_DIR}/${APP_NAME}.app/Contents/Helpers/pearl-cli"

# Create Info.plist
cat > "${DIST_DIR}/${APP_NAME}.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Pearl AI. Zero telemetry, Apache 2.0 / MIT.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Pearl requires microphone access for low-latency push-to-talk voice interaction.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Pearl requires Speech Recognition to understand voice commands on device.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Pearl requires Apple Events authorization to automate desktop applications safely.</string>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/rossonerian/Pearl/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>c2hhMjU2X2VkMjU1MTlfcHVibGljX2tleV9wbGFjZWhvbGRlcl9wZWFybHYyCg==</string>
    <key>SUEnableSystemProfiling</key>
    <false/>
    <key>SUAutomaticallyChecksForUpdates</key>
    <true/>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "${DIST_DIR}/${APP_NAME}.app/Contents/PkgInfo"

echo "=============================================================================="
echo " Code Signing (Inside-Out Hardened Runtime)"
echo "=============================================================================="
APP_PATH="${DIST_DIR}/${APP_NAME}.app"
CLI_PATH="${APP_PATH}/Contents/Helpers/pearl-cli"
MACOS_BIN="${APP_PATH}/Contents/MacOS/${APP_NAME}"

SIGN_ARGS=("--force")
if [[ "${ADHOC}" == "true" ]]; then
    SIGN_ARGS+=("--sign" "-")
    echo "→ Signing ad-hoc (-)"
else
    SIGN_ARGS+=("--sign" "${SIGN_IDENTITY}" "--options" "runtime" "--timestamp")
    echo "→ Signing with Developer ID: ${SIGN_IDENTITY}"
fi

# 1. Sign helper binary (inside-out)
echo "→ [1/3] Signing helper pearl-cli..."
codesign "${SIGN_ARGS[@]}" "${CLI_PATH}"

# 2. Sign main binary with entitlements
echo "→ [2/3] Signing main binary with entitlements..."
codesign "${SIGN_ARGS[@]}" --entitlements "${ENTITLEMENTS}" "${MACOS_BIN}"

# 3. Sign outer application bundle
echo "→ [3/3] Signing outer ${APP_NAME}.app bundle..."
codesign "${SIGN_ARGS[@]}" --entitlements "${ENTITLEMENTS}" "${APP_PATH}"

echo "→ Verifying bundle code signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "=============================================================================="
echo " Gatekeeper Assessment (spctl)"
echo "=============================================================================="
if [[ "${ADHOC}" == "true" ]]; then
    echo "→ Ad-hoc build: running spctl verification (may report rejected without Developer ID):"
    spctl -a -vv "${APP_PATH}" 2>&1 || true
else
    echo "→ Validating Developer ID signature with Gatekeeper:"
    spctl -a -vv "${APP_PATH}"
    echo "✓ Gatekeeper assessment passed!"
fi

echo "=============================================================================="
echo " Packaging Release Artifacts"
echo "=============================================================================="
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"

if [[ "${PACKAGE_FORMAT}" == "dmg" || "${PACKAGE_FORMAT}" == "both" ]]; then
    echo "→ Creating standalone DMG: ${DMG_PATH}"
    hdiutil create -volname "${APP_NAME}" \
                   -srcfolder "${APP_PATH}" \
                   -ov \
                   -format UDZO \
                   "${DMG_PATH}"
    echo "✓ DMG created successfully ($(du -h "${DMG_PATH}" | cut -f1))"
fi

if [[ "${PACKAGE_FORMAT}" == "zip" || "${PACKAGE_FORMAT}" == "both" ]]; then
    echo "→ Creating standalone ZIP: ${ZIP_PATH}"
    ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
    echo "✓ ZIP created successfully ($(du -h "${ZIP_PATH}" | cut -f1))"
fi

echo "=============================================================================="
echo " Apple Notarization & Stapling"
echo "=============================================================================="
if [[ -n "${NOTARY_PROFILE}" && "${ADHOC}" == "false" ]]; then
    TARGET_PACKAGE="${DMG_PATH}"
    if [[ ! -f "${TARGET_PACKAGE}" ]]; then
        TARGET_PACKAGE="${ZIP_PATH}"
    fi

    echo "→ Submitting ${TARGET_PACKAGE} to Apple Notary Service..."
    xcrun notarytool submit "${TARGET_PACKAGE}" --keychain-profile "${NOTARY_PROFILE}" --wait
    
    echo "→ Stapling ticket to bundle..."
    xcrun stapler staple "${APP_PATH}"
    
    if [[ -f "${DMG_PATH}" ]]; then
        echo "→ Stapling ticket to DMG..."
        xcrun stapler staple "${DMG_PATH}"
    fi
    
    echo "→ Final Gatekeeper verification after stapling:"
    spctl -a -vv -t install "${APP_PATH}"
    echo "✓ Notarization & stapling complete!"
else
    echo "Notice: Skipping notarization (no --notary-profile provided or --adhoc specified)."
    echo "To notarize, supply credentials via --notary-profile <KEYCHAIN_PROFILE>"
fi

echo "=============================================================================="
echo " Release Build Complete!"
echo " Location: ${DIST_DIR}"
ls -lh "${DIST_DIR}"
echo "=============================================================================="
