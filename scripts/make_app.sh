#!/bin/zsh
# Builds build/KeysightDMM.app from the SwiftPM executable.
#   scripts/make_app.sh [debug|release]     (default: release)
# The bundle is what gives the app its Info.plist: the local-network usage string and
# the Bonjour service list macOS requires before it lets the app browse for instruments.
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-release}
swift build -c $config --product KeysightDMMApp
bin=$(swift build -c $config --show-bin-path)
app=build/KeysightDMM.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp $bin/KeysightDMMApp $app/Contents/MacOS/KeysightDMM
# SwiftPM resource bundles (DMMKit's command catalogue). DMMKit looks here first.
for bundle in $bin/*.bundle(N); do cp -R $bundle $app/Contents/Resources/; done
cat > $app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Keysight DMM</string>
    <key>CFBundleDisplayName</key><string>Keysight DMM</string>
    <key>CFBundleIdentifier</key><string>local.keysight-dmm</string>
    <key>CFBundleExecutable</key><string>KeysightDMM</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Keysight DMM finds and controls your multimeter on the local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_scpi-raw._tcp</string></array>
</dict>
</plist>
PLIST
codesign --force --sign - $app
echo "Built $app"
