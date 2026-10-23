#!/bin/zsh
# Builds dist/PenlightSync.app (universal, ad-hoc signed) from the shared Swift sources.
set -euo pipefail
cd -- "${0:A:h}"

app="dist/PenlightSync.app"
build="$(mktemp -d)"
trap 'rm -rf -- "$build"' EXIT

sources=(ScreenColor.swift PenlightProtocol.swift PenlightApp/LightEngine.swift PenlightApp/BeatDetector.swift PenlightApp/SystemAudioMonitor.swift PenlightApp/RegionSelector.swift PenlightApp/ScreenStream.swift PenlightApp/PenlightController.swift PenlightApp/UpdateChecker.swift PenlightApp/PenlightApp.swift)
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
