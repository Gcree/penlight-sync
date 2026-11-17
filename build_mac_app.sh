#!/bin/zsh
# Builds dist/PenlightSync.app (universal, ad-hoc signed) from the shared Swift sources.
set -euo pipefail
cd -- "${0:A:h}"

# CommandLineTools macOS 27+ SDK lacks the SwiftUIMacros plugin; fall back to MacOSX26.sdk when Xcode.app is absent.
if [[ -z "${SDKROOT:-}" ]] && [[ "$(xcode-select -p 2>/dev/null)" == "/Library/Developer/CommandLineTools" ]]; then
    if [[ ! -e /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib ]] && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
    fi
fi

app="dist/PenlightSync.app"
build="$(mktemp -d)"
trap 'rm -rf -- "$build"' EXIT

sources=(ScreenColor.swift PenlightProtocol.swift PenlightApp/LightEngine.swift PenlightApp/SiteLight.swift PenlightApp/SiteLink.swift PenlightApp/BeatDetector.swift PenlightApp/SystemAudioMonitor.swift PenlightApp/Localization.swift PenlightApp/SettingsStore.swift PenlightApp/RegionSelector.swift PenlightApp/ScreenStream.swift PenlightApp/PenlightController.swift PenlightApp/UpdateChecker.swift PenlightApp/PenlightApp.swift)
for arch in arm64 x86_64; do
    swiftc -parse-as-library -O -target "$arch-apple-macos14.0" "${sources[@]}" -o "$build/PenlightSync-$arch"
done

rm -rf -- "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "$build/PenlightSync-arm64" "$build/PenlightSync-x86_64" -output "$app/Contents/MacOS/PenlightSync"
cp PenlightApp/Info.plist "$app/Contents/Info.plist"
cp icon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$app"
print "Built $app"
