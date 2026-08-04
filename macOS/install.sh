#!/bin/sh
# Builds Markdown Viewer, installs it into /Applications, and makes it the default Markdown app.
#
# Installing from a folder that gets rebuilt is what breaks the Finder association: Launch Services
# keeps registrations for every copy of the bundle it has ever seen, and the stale one in
# macOS/build/ competes with the installed one. This replaces the installed copy, drops the stale
# registrations, re-registers exactly one bundle, and sets the handler.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DESTINATION=${1:-/Applications}
INSTALLED="$DESTINATION/Markdown Viewer.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

BUILT=$("$SCRIPT_DIR/build.sh")
BUILT_EXTENSION="$BUILT/Contents/PlugIns/MDViewerQuickLook.appex"
INSTALLED_EXTENSION="$INSTALLED/Contents/PlugIns/MDViewerQuickLook.appex"

osascript -e 'tell application "System Events" to if exists (process "Markdown Viewer") then tell application "Markdown Viewer" to quit' >/dev/null 2>&1 || true
pkill -x MDViewerQuickLook >/dev/null 2>&1 || true

# Launch Services and PlugInKit keep separate registries. Remove both extension paths before either
# app bundle is replaced; otherwise Finder can retain a dead build-folder copy with the same bundle
# identifier and report that app.mdviewer.quicklook cannot be found.
pluginkit -r "$BUILT_EXTENSION" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true
if [ -d "$INSTALLED" ]; then
  pluginkit -r "$INSTALLED_EXTENSION" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$INSTALLED" >/dev/null 2>&1 || true
  rm -rf "$INSTALLED"
fi

mkdir -p "$DESTINATION"
cp -R "$BUILT" "$INSTALLED"
"$LSREGISTER" -f "$INSTALLED"
pluginkit -a "$INSTALLED_EXTENSION"
pluginkit -e use -i app.mdviewer.quicklook

# Fail the install instead of leaving an app whose Finder preview is silently unavailable.
QUICKLOOK_REGISTRATION=$(pluginkit -m -D -v -i app.mdviewer.quicklook 2>/dev/null || true)
case "$QUICKLOOK_REGISTRATION" in
  *"$INSTALLED_EXTENSION"*) ;;
  *)
    echo "Could not register $INSTALLED_EXTENSION" >&2
    exit 1
    ;;
esac
qlmanage -r cache >/dev/null 2>&1 || true

# Finder caches the extension's generated XPC service name in memory. This matters when a local
# build has ever used a different bundle identifier: PlugInKit may point at the new bundle while
# Finder continues connecting to the old "<bundle-id>.apple-extension-service" until it relaunches.
# Finder restarts automatically and restores its windows.
killall Finder >/dev/null 2>&1 || true

# Claim the Markdown types for the installed copy. Doing it here (rather than only from the app's
# "Set as Default Markdown App…" menu item) means a fresh machine needs no extra clicks.
swift - "$INSTALLED" <<'SWIFT'
import AppKit
import UniformTypeIdentifiers

let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1])
var types = [UTType]()
if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
for fileExtension in ["md", "markdown", "mdown", "mkd"] {
    if let type = UTType(filenameExtension: fileExtension), !types.contains(type) { types.append(type) }
}

let group = DispatchGroup()
var failure: Error?
for type in types {
    group.enter()
    NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: type) { error in
        if failure == nil { failure = error }
        group.leave()
    }
}
group.notify(queue: .main) {
    if let failure {
        FileHandle.standardError.write("Could not set the default handler: \(failure.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    print("Default Markdown app: \(bundleURL.path)")
    exit(0)
}
RunLoop.main.run()
SWIFT

echo "Installed $INSTALLED"
