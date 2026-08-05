#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SDK=$(xcrun --sdk macosx --show-sdk-path)
TEST_OUTPUT=$(mktemp -d)
trap 'rm -rf "$TEST_OUTPUT"' EXIT HUP INT TERM

swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$SDK" \
  -framework AppKit -framework JavaScriptCore -framework QuickLookUI -framework WebKit \
  "$SCRIPT_DIR/App/DocumentViewController.swift" \
  "$SCRIPT_DIR/QuickLook/PreviewViewController.swift" \
  "$SCRIPT_DIR/Shared/MarkdownPreviewView.swift" \
  "$SCRIPT_DIR/Shared/ThemeSync.swift" \
  "$SCRIPT_DIR/Tests/main.swift" \
  -o "$TEST_OUTPUT/native-editor-smoke"

mkdir -p "$TEST_OUTPUT/Web"
cp "$SCRIPT_DIR/../markdown.js" \
  "$SCRIPT_DIR/../math.js" \
  "$SCRIPT_DIR/Resources/Web/native-preview.css" \
  "$SCRIPT_DIR/Resources/Web/native-theme-overrides.css" \
  "$SCRIPT_DIR/Resources/Web/native-preview.js" \
  "$SCRIPT_DIR/Resources/Web/preview.html" \
  "$TEST_OUTPUT/Web/"
cp -R "$SCRIPT_DIR/../vendor/mathjax" "$TEST_OUTPUT/Web/mathjax"
"$TEST_OUTPUT/native-editor-smoke" "$SCRIPT_DIR/../README.md"
