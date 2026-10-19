#!/usr/bin/env bash
# Generate the iOS Runner project on a machine that has Flutter installed.
# The Dart source, assets and icon are already in this repository.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter is not installed (or not on PATH)." >&2
  echo "Install Flutter, then run this script again." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> creating iOS scaffold in $TMP"
flutter create \
  --platforms=ios \
  --org com.flm \
  --project-name flm \
  "$TMP/scaffold" >/dev/null

echo "==> copying ios/ into the project"
rm -rf "$ROOT/ios"
cp -R "$TMP/scaffold/ios" "$ROOT/ios"
cp "$TMP/scaffold/.metadata" "$ROOT/.metadata" 2>/dev/null || true

# Remove paths generated against the temporary scaffold. Flutter regenerates
# these with the real project path during pub get / config-only.
rm -rf "$ROOT/ios/Pods" "$ROOT/ios/.symlinks" "$ROOT/ios/Podfile.lock"
rm -f "$ROOT/ios/Flutter/Generated.xcconfig" \
      "$ROOT/ios/Flutter/flutter_export_environment.sh"

echo "==> applying flm Info.plist"
cp "$ROOT/tool/ios_overlay/Info.plist" "$ROOT/ios/Runner/Info.plist"

echo "==> applying flm app icon"
rm -rf "$ROOT/ios/Runner/Assets.xcassets/AppIcon.appiconset"
cp -R "$ROOT/tool/ios_overlay/AppIcon.appiconset" \
      "$ROOT/ios/Runner/Assets.xcassets/AppIcon.appiconset"

echo "==> setting bundle id to com.flm.music and iOS 14 deployment target"
if command -v perl >/dev/null 2>&1; then
  perl -pi -e 's/com\.flm\.flm/com.flm.music/g' "$ROOT/ios/Runner.xcodeproj/project.pbxproj"
  perl -pi -e 's/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = 14.0;/g' \
    "$ROOT/ios/Runner.xcodeproj/project.pbxproj"
  if [ -f "$ROOT/ios/Podfile" ]; then
    perl -pi -e "s/#?\\s*platform :ios, '[0-9.]+'/platform :ios, '14.0'/" "$ROOT/ios/Podfile"
    if ! grep -qE '^platform :ios' "$ROOT/ios/Podfile"; then
      printf "\nplatform :ios, '14.0'\n" >> "$ROOT/ios/Podfile"
    fi
  fi
  if [ -f "$ROOT/ios/Flutter/AppFrameworkInfo.plist" ]; then
    /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion 14.0" \
      "$ROOT/ios/Flutter/AppFrameworkInfo.plist" 2>/dev/null || true
  fi
fi

echo "==> flutter pub get"
flutter pub get

cat <<'EOF'

Done.

Next steps:
  1. open ios/Runner.xcworkspace
  2. Xcode -> Runner target -> Signing & Capabilities
     - choose your Team
     - keep "Background Modes -> Audio" enabled
  3. run on a device or simulator

Notes:
  - The app uses a hidden WKWebView to run the original LX music-source
    logic and user source scripts.
  - NSAllowsArbitraryLoads is enabled because the music sources use HTTP.
  - Online playback needs a user source .js file:
       我的 -> 自定义源 -> 导入
EOF
