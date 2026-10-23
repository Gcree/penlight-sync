#!/bin/zsh
# Regenerates icon/AppIcon.icns (macOS), icon/AppIcon.ico (Windows) and icon/AppIcon.png from make_icon.swift.
set -euo pipefail
cd -- "${0:A:h}"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
args=()
for size in 16 32 128 256 512; do
    args+=($size "$iconset/icon_${size}x${size}.png" $((size * 2)) "$iconset/icon_${size}x${size}@2x.png")
done
swift make_icon.swift mac "${args[@]}" 1024 AppIcon.png
iconutil --convert icns --output AppIcon.icns "$iconset"

ico_sizes=(16 24 32 48 64 128 256)
args=()
for size in $ico_sizes; do
    args+=($size "$work/ico-$size.png")
done
swift make_icon.swift full "${args[@]}"
# An .ico may hold PNG images directly (Windows Vista and later).
python3 - "$work" AppIcon.ico $ico_sizes <<'EOF'
import pathlib, struct, sys
work, out, sizes = pathlib.Path(sys.argv[1]), sys.argv[2], [int(s) for s in sys.argv[3:]]
images = [(work / f"ico-{s}.png").read_bytes() for s in sizes]
header = struct.pack("<HHH", 0, 1, len(images))
offset = len(header) + 16 * len(images)
entries = b""
for size, data in zip(sizes, images):
    entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
pathlib.Path(out).write_bytes(header + entries + b"".join(images))
EOF
print "Wrote AppIcon.icns, AppIcon.ico, AppIcon.png"
