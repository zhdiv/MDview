#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR=${1:-"$SCRIPT_DIR/build"}
APP="$OUTPUT_DIR/Markdown Viewer.app"
APP_CONTENTS="$APP/Contents"
EXTENSION="$APP_CONTENTS/PlugIns/MDViewerQuickLook.appex"
EXTENSION_CONTENTS="$EXTENSION/Contents"
SDK=$(xcrun --sdk macosx --show-sdk-path)
INTERMEDIATES="$OUTPUT_DIR/.native-build"
ICON_SOURCE="$PROJECT_DIR/assets/mdviewer-icon.svg"
ICON_RASTER="$INTERMEDIATES/AppIcon-1024.png"
ICONSET="$INTERMEDIATES/AppIcon.iconset"

rm -rf "$APP" "$INTERMEDIATES"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources/Web" "$EXTENSION_CONTENTS/MacOS" "$EXTENSION_CONTENTS/Resources/Web" "$ICONSET"

for BUILD_ARCH in arm64 x86_64; do
  swiftc -module-name MDViewer -target "$BUILD_ARCH-apple-macos13.0" -sdk "$SDK" \
    -framework AppKit -framework WebKit \
    "$SCRIPT_DIR/App/AppDelegate.swift" \
    "$SCRIPT_DIR/App/DocumentViewController.swift" \
    "$SCRIPT_DIR/Shared/MarkdownPreviewView.swift" \
    "$SCRIPT_DIR/Shared/ThemeSync.swift" \
    "$SCRIPT_DIR/App/main.swift" \
    -o "$INTERMEDIATES/MDViewer-$BUILD_ARCH"

  swiftc -parse-as-library -module-name MDViewerQuickLook -target "$BUILD_ARCH-apple-macos13.0" -sdk "$SDK" \
    -framework JavaScriptCore -framework QuickLookUI \
    -Xlinker -e -Xlinker _NSExtensionMain \
    "$SCRIPT_DIR/QuickLook/PreviewViewController.swift" \
    "$SCRIPT_DIR/Shared/ThemeSync.swift" \
    -o "$INTERMEDIATES/MDViewerQuickLook-$BUILD_ARCH"
done
lipo -create "$INTERMEDIATES/MDViewer-arm64" "$INTERMEDIATES/MDViewer-x86_64" -output "$APP_CONTENTS/MacOS/MDViewer"
lipo -create "$INTERMEDIATES/MDViewerQuickLook-arm64" "$INTERMEDIATES/MDViewerQuickLook-x86_64" -output "$EXTENSION_CONTENTS/MacOS/MDViewerQuickLook"

cp "$SCRIPT_DIR/Resources/App-Info.plist" "$APP_CONTENTS/Info.plist"
cp "$SCRIPT_DIR/Resources/QuickLook-Info.plist" "$EXTENSION_CONTENTS/Info.plist"
cp "$PROJECT_DIR/markdown.js" "$SCRIPT_DIR/Resources/Web/preview.html" \
  "$SCRIPT_DIR/Resources/Web/native-preview.js" "$SCRIPT_DIR/Resources/Web/native-preview.css" \
  "$SCRIPT_DIR/Resources/Web/native-theme-overrides.css" \
  "$APP_CONTENTS/Resources/Web/"
cp "$PROJECT_DIR/markdown.js" "$SCRIPT_DIR/Resources/Web/native-preview.css" \
  "$SCRIPT_DIR/Resources/Web/native-theme-overrides.css" \
  "$EXTENSION_CONTENTS/Resources/Web/"

# Keep the tiny SVG as the source of truth. macOS app bundles still require raster icon renditions.
# AppKit preserves the SVG's alpha channel; Quick Look's thumbnail renderer must not be used here
# because it flattens transparent corners onto opaque white and Icon Services displays a blank icon.
swift "$SCRIPT_DIR/Tools/RasterizeSVG.swift" "$ICON_SOURCE" "$ICON_RASTER" 1024
sips -z 16 16 "$ICON_RASTER" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_RASTER" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_RASTER" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_RASTER" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_RASTER" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_RASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_RASTER" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_RASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_RASTER" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$ICON_RASTER" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP_CONTENTS/Resources/AppIcon.icns"

# App Group theme sharing requires a real signing identity + a provisioning profile that includes
# group.app.mdviewer. The default ad-hoc build (CODESIGN_IDENTITY unset or "-") instead gives the
# Quick Look extension read-only access to the main app's preference domain.
#
# The ad-hoc path pins an explicit designated requirement. An ad-hoc signature's default DR is
# `cdhash H"…"`, which changes on every single build — Launch Services then treats each rebuild as a
# different application and silently drops the "always open with Markdown Viewer" association. An
# identifier-based DR is stable across rebuilds, so the Finder association survives. (The trade-off:
# any bundle claiming the same identifier satisfies it, which is inherent to unsigned local builds.)
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - --identifier app.mdviewer.quicklook \
    -r='designated => identifier "app.mdviewer.quicklook"' \
    --entitlements "$SCRIPT_DIR/Resources/QuickLook.entitlements" "$EXTENSION"
  codesign --force --sign - --identifier app.mdviewer \
    -r='designated => identifier "app.mdviewer"' "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --entitlements "$SCRIPT_DIR/Resources/QuickLook.appgroup.entitlements" "$EXTENSION"
  codesign --force --sign "$SIGN_IDENTITY" --entitlements "$SCRIPT_DIR/Resources/App.appgroup.entitlements" "$APP"
fi
codesign --verify --deep --strict "$APP"
rm -rf "$INTERMEDIATES"
echo "$APP"
