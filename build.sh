#!/bin/zsh
# Builds Mouser.app into ./build
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Mouser.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Mouser "$APP/Contents/MacOS/Mouser"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mouser</string>
  <key>CFBundleIdentifier</key><string>local.mouser.app</string>
  <key>CFBundleExecutable</key><string>Mouser</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
