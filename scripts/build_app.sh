#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${WORKSPACE_DIR}"

echo "[AIMeter] Building release binaries in ${WORKSPACE_DIR}..."
swift build -c release

APP_DIR="${WORKSPACE_DIR}/AIMeter.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PLUGINS_DIR="${CONTENTS_DIR}/PlugIns"
WIDGET_APPEX_DIR="${PLUGINS_DIR}/AIMeterWidget.appex"
WIDGET_CONTENTS_DIR="${WIDGET_APPEX_DIR}/Contents"
WIDGET_MACOS_DIR="${WIDGET_CONTENTS_DIR}/MacOS"
WIDGET_RESOURCES_DIR="${WIDGET_CONTENTS_DIR}/Resources"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${WIDGET_MACOS_DIR}" "${WIDGET_RESOURCES_DIR}"
rm -f "${MACOS_DIR}/AIMeter"
cp ".build/release/AIMeter" "${MACOS_DIR}/AIMeter"
chmod +x "${MACOS_DIR}/AIMeter"

# WidgetKit Extension
echo "[AIMeter] Packaging WidgetKit Extension (.appex)..."
rm -f "${WIDGET_MACOS_DIR}/AIMeterWidgetExtension"
cp ".build/release/AIMeterWidgetExtension" "${WIDGET_MACOS_DIR}/AIMeterWidgetExtension"
chmod +x "${WIDGET_MACOS_DIR}/AIMeterWidgetExtension"

# Resources (Icon)
if [ -f "${WORKSPACE_DIR}/Sources/AIMeter/Resources/AppIcon.icns" ]; then
    cp "${WORKSPACE_DIR}/Sources/AIMeter/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
    cp "${WORKSPACE_DIR}/Sources/AIMeter/Resources/AppIcon.icns" "${WIDGET_RESOURCES_DIR}/AppIcon.icns"
fi
rm -f "${RESOURCES_DIR}/update_usage.py"

cat > "${WIDGET_CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AIMeterWidgetExtension</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.AIMeter.widget</string>
    <key>CFBundleName</key>
    <string>AIMeterWidget</string>
    <key>CFBundleDisplayName</key>
    <string>AI Meter</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
EOF

cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AIMeter</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.AIMeter</string>
    <key>CFBundleName</key>
    <string>AIMeter</string>
    <key>CFBundleDisplayName</key>
    <string>AI Meter</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.local.AIMeter</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>aimeter</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

# Auto-detect Apple Development code-signing identity if available
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}' || true)
if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY="-"
    echo "[AIMeter] Using ad-hoc signature (-)..."
else
    echo "[AIMeter] Using developer identity: ${SIGN_IDENTITY}..."
fi

echo "[AIMeter] Signing widget extension bundle..."
codesign --force --options runtime --sign "${SIGN_IDENTITY}" --entitlements "${WORKSPACE_DIR}/scripts/AIMeterWidgetExtension.entitlements" "${WIDGET_APPEX_DIR}"

echo "[AIMeter] Signing app bundle..."
codesign --force --options runtime --sign "${SIGN_IDENTITY}" --entitlements "${WORKSPACE_DIR}/scripts/AIMeter.entitlements" "${APP_DIR}"

# Sync to /Applications if accessible so macOS chronod / WidgetKit will surface the widget
APPLICATIONS_APP="/Applications/AIMeter.app"
if [ "${AIMETER_INSTALL_TO_APPLICATIONS:-1}" = "1" ] && [ -d "/Applications" ] && [ -w "/Applications" ]; then
    echo "[AIMeter] Syncing to ${APPLICATIONS_APP}..."
    ditto "${APP_DIR}" "${APPLICATIONS_APP}"
    codesign --force --options runtime --sign "${SIGN_IDENTITY}" --entitlements "${WORKSPACE_DIR}/scripts/AIMeterWidgetExtension.entitlements" "${APPLICATIONS_APP}/Contents/PlugIns/AIMeterWidget.appex"
    codesign --force --options runtime --sign "${SIGN_IDENTITY}" --entitlements "${WORKSPACE_DIR}/scripts/AIMeter.entitlements" "${APPLICATIONS_APP}"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APPLICATIONS_APP}" 2>/dev/null || true
    pluginkit -a "${APPLICATIONS_APP}/Contents/PlugIns/AIMeterWidget.appex" 2>/dev/null || true
    pluginkit -e use -i com.local.AIMeter.widget 2>/dev/null || true
fi

ZIP_NAME="AIMeter-macos-universal.zip"
echo "[AIMeter] Creating distribution archive: ${ZIP_NAME}..."
rm -f "${WORKSPACE_DIR}/${ZIP_NAME}"
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${WORKSPACE_DIR}/${ZIP_NAME}"

echo "[AIMeter] Successfully built ${APP_DIR} and created ${WORKSPACE_DIR}/${ZIP_NAME}"
