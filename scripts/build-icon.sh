#!/bin/zsh
set -eu
cd "${0:A:h:h}"
OUTPUT="${1:-$PWD/.build/AppIcon.icns}"
ICONSET="$PWD/.build/AppIcon.iconset"
mkdir -p "$ICONSET" "${OUTPUT:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swiftc scripts/prepare-icon.swift -o .build/prepare-icon
.build/prepare-icon Icon.png .build/Icon-rounded.png
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" .build/Icon-rounded.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" .build/Icon-rounded.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
if ! iconutil -c icns "$ICONSET" -o "$OUTPUT" 2>/dev/null; then
    # Some restricted CLT environments cannot use the ICNS ImageIO encoder.
    # ICNS accepts the PNG renditions directly; assemble its length-prefixed container.
    python3 - "$ICONSET" "$OUTPUT" <<'PYICON'
import pathlib, struct, sys
folder = pathlib.Path(sys.argv[1])
renditions = [
    ('icp4', 'icon_16x16.png'), ('icp5', 'icon_32x32.png'),
    ('icp6', 'icon_32x32@2x.png'), ('ic07', 'icon_128x128.png'),
    ('ic08', 'icon_256x256.png'), ('ic09', 'icon_512x512.png'),
    ('ic10', 'icon_512x512@2x.png'), ('ic11', 'icon_16x16@2x.png'),
    ('ic12', 'icon_32x32@2x.png'), ('ic13', 'icon_128x128@2x.png'),
    ('ic14', 'icon_256x256@2x.png'),
]
chunks = []
for kind, name in renditions:
    png = (folder / name).read_bytes()
    assert png.startswith(b'\x89PNG\r\n\x1a\n')
    chunks.append(kind.encode('ascii') + struct.pack('>I', len(png) + 8) + png)
payload = b''.join(chunks)
pathlib.Path(sys.argv[2]).write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
PYICON
fi
