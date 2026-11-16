#!/usr/bin/env bash
set -euo pipefail
# Called before bundle_macho so service/helper dependencies are relocated too.
build=$1
app=$2
service="io.github.trufae.Parla.Webxdc"
contents="$app/Contents/XPCServices/$service.xpc/Contents"
mkdir -p "$contents/MacOS"
cp "$build/parla-webxdc-launcher" "$contents/MacOS/launcher"
cp "$build/parla-webxdc" "$contents/MacOS/parla-webxdc"
cat > "$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$service</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>XPCService</key><dict>
    <key>ServiceType</key><string>Application</string>
    <key>JoinExistingSession</key><true/>
  </dict>
</dict></plist>
EOF
