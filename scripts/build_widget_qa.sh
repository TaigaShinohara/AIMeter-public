#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRATCH_PATH="${AIMETER_WIDGET_QA_SCRATCH_PATH:-${WORKSPACE_DIR}/.build/widget-qa-build}"
OUTPUT_DIR="${WORKSPACE_DIR}/.build/widget-qa"
APP_DIR="${OUTPUT_DIR}/AIMeterWidgetQA.app"
EXTENSION_DIR="${APP_DIR}/Contents/PlugIns/AIMeterWidgetQA.appex"
QA_ENTITLEMENTS="${SCRIPT_DIR}/AIMeterWidgetQA.entitlements"
QA_BUILD_NUMBER="${AIMETER_WIDGET_QA_BUILD_NUMBER:-4}"

case "${QA_BUILD_NUMBER}" in
    ''|*[!0-9]*) echo "[AIMeter QA] Build number must be a positive integer." >&2; exit 1 ;;
esac
if [ "${QA_BUILD_NUMBER}" -eq 0 ]; then
    echo "[AIMeter QA] Build number must be a positive integer." >&2
    exit 1
fi

cd "${WORKSPACE_DIR}"

# Keep this local QA build separate from other build/test processes.
if pgrep -x swift-build >/dev/null || pgrep -x swift-test >/dev/null || pgrep -x xcodebuild >/dev/null; then
    echo "[AIMeter QA] A build or test is running. Wait for it to finish before building QA." >&2
    exit 1
fi
mkdir -p "${SCRATCH_PATH}" "${OUTPUT_DIR}"
echo "[AIMeter QA] Build resource check:"
/usr/bin/memory_pressure -Q
df -h "${SCRATCH_PATH}" "${OUTPUT_DIR}"

swift build --configuration release --jobs 2 --scratch-path "${SCRATCH_PATH}" --product AIMeterWidgetQAHost
swift build --configuration release --jobs 2 --scratch-path "${SCRATCH_PATH}" --product AIMeterWidgetQAExtension
BIN_DIR="$(swift build --configuration release --scratch-path "${SCRATCH_PATH}" --show-bin-path)"

mkdir -p "${APP_DIR}/Contents/MacOS" "${EXTENSION_DIR}/Contents/MacOS"
install -m 755 "${BIN_DIR}/AIMeterWidgetQAHost" "${APP_DIR}/Contents/MacOS/AIMeterWidgetQAHost"
install -m 755 "${BIN_DIR}/AIMeterWidgetQAExtension" "${EXTENSION_DIR}/Contents/MacOS/AIMeterWidgetQAExtension"

cat > "${APP_DIR}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AIMeterWidgetQAHost</string>
    <key>CFBundleIdentifier</key><string>com.local.AIMeterWidgetQA</string>
    <key>CFBundleName</key><string>AIMeter Widget QA</string>
    <key>CFBundleDisplayName</key><string>AIMeter Widget QA</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>com.local.AIMeterWidgetQA</string>
        <key>CFBundleURLSchemes</key><array><string>aimeter-widget-qa</string></array>
    </dict></array>
</dict>
</plist>
EOF

cat > "${EXTENSION_DIR}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AIMeterWidgetQAExtension</string>
    <key>CFBundleIdentifier</key><string>com.local.AIMeterWidgetQA.widget</string>
    <key>CFBundleName</key><string>AIMeter QA</string>
    <key>CFBundleDisplayName</key><string>AIMeter QA</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSExtension</key><dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
EOF

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${QA_BUILD_NUMBER}" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${QA_BUILD_NUMBER}" "${EXTENSION_DIR}/Contents/Info.plist"
plutil -lint "${APP_DIR}/Contents/Info.plist" "${EXTENSION_DIR}/Contents/Info.plist" "${QA_ENTITLEMENTS}"
SIGN_IDENTITY="${AIMETER_WIDGET_QA_SIGN_IDENTITY:-}"
if [ -z "${SIGN_IDENTITY}" ]; then
    # A certificate name may be duplicated in Keychain; its SHA-1 identity is
    # unambiguous and does not reveal any private key material.
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}' || true)"
fi
if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY="-"
fi
codesign --force --options runtime --sign "${SIGN_IDENTITY}" --entitlements "${QA_ENTITLEMENTS}" "${EXTENSION_DIR}"
codesign --force --options runtime --sign "${SIGN_IDENTITY}" --entitlements "${QA_ENTITLEMENTS}" "${APP_DIR}"
codesign --verify --strict "${EXTENSION_DIR}"
codesign --verify --deep --strict "${APP_DIR}"
PYTHONDONTWRITEBYTECODE=1 python3 "${SCRIPT_DIR}/local_build.py" verify-qa "${APP_DIR}"

echo "[AIMeter QA] Synthetic QA bundle ready: ${APP_DIR}"
echo "[AIMeter QA] Installation and Widget gallery registration are separate QA steps."
