#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
if [[ -d /opt/homebrew/opt/libssh2 ]]; then BREW_PREFIX=/opt/homebrew; else BREW_PREFIX=/usr/local; fi
SSH_PREFIX="${CYBERGOOSE_SSH2_PREFIX:-$BREW_PREFIX/opt/libssh2}"
SSL_PREFIX="${CYBERGOOSE_OPENSSL_PREFIX:-$BREW_PREFIX/opt/openssl@3}"
export CYBERGOOSE_SSH2_PREFIX="$SSH_PREFIX"
[[ -f "$SSH_PREFIX/include/libssh2.h" ]] || { print -u2 'Install libssh2 and openssl@3, or set CYBERGOOSE_SSH2_PREFIX / CYBERGOOSE_OPENSSL_PREFIX'; exit 1; }
swift build --disable-sandbox --cache-path "$PWD/.build/spm-cache" -c release
STAGING=$(mktemp -d "$PWD/.build/app-bundle.XXXXXX")
APP="$STAGING/Cybergoose.app"
FRAMEWORKS="$APP/Contents/Frameworks"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$FRAMEWORKS" "$RESOURCES/Licenses"
./scripts/build-icon.sh "$RESOURCES/AppIcon.icns"
cp .build/release/Cybergoose "$APP/Contents/MacOS/Cybergoose"
cp -L "$SSH_PREFIX/lib/libssh2.1.dylib" "$FRAMEWORKS/"
cp -L "$SSL_PREFIX/lib/libssl.3.dylib" "$SSL_PREFIX/lib/libcrypto.3.dylib" "$FRAMEWORKS/"
cp "$SSH_PREFIX/COPYING" "$RESOURCES/Licenses/libssh2.txt"
cp "$SSL_PREFIX/LICENSE.txt" "$RESOURCES/Licenses/OpenSSL.txt"
chmod -R u+w "$APP"
# Rewrite all non-system dependencies to bundled libraries, including Cellar paths.
for binary in "$APP/Contents/MacOS/Cybergoose" "$FRAMEWORKS/"*.dylib; do
    while read -r dependency; do
        case "$dependency" in
            */libssh2.1.dylib|*/libssl.3.dylib|*/libcrypto.3.dylib)
                name="${dependency:t}"
                if [[ "$binary" == "$APP/Contents/MacOS/Cybergoose" ]]; then replacement="@executable_path/../Frameworks/$name"; else replacement="@loader_path/$name"; fi
                install_name_tool -change "$dependency" "$replacement" "$binary"
                ;;
        esac
    done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
    if [[ "$binary" == *.dylib ]]; then install_name_tool -id "@rpath/${binary:t}" "$binary"; fi
done
# Advertise the actual runtime minimum of the bundled Homebrew builds, not just Swift's target.
MINIMUM=$(python3 - "$FRAMEWORKS" <<'PY'
import pathlib, re, subprocess, sys
versions = [(14, 0)]
for lib in pathlib.Path(sys.argv[1]).glob('*.dylib'):
    text = subprocess.check_output(['otool', '-l', str(lib)], text=True)
    for value in re.findall(r'\bminos\s+(\d+(?:\.\d+)+)', text):
        versions.append(tuple(map(int, value.split('.'))))
print('.'.join(map(str, max(versions))))
PY
)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Cybergoose</string>
<key>CFBundleIdentifier</key><string>app.cybergoose.mac</string>
<key>CFBundleName</key><string>Cybergoose</string>
<key>CFBundleDisplayName</key><string>Cybergoose</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.3</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
for library in "$FRAMEWORKS/"*.dylib; do codesign --force --sign - "$library"; done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p dist
if [[ -e dist/Cybergoose.app ]]; then
    PREVIOUS=$(mktemp -d "$PWD/.build/previous-app.XXXXXX")
    mv dist/Cybergoose.app "$PREVIOUS/"
fi
mv "$APP" dist/Cybergoose.app
rmdir "$STAGING"
printf 'Built %s (runtime macOS %s+)\n' "$PWD/dist/Cybergoose.app" "$MINIMUM"
