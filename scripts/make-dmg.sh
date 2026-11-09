#!/usr/bin/env bash
#
#  Builds Simple Clipboard for Release and packages it into a laid-out .dmg:
#  custom background, volume icon, app on the left, /Applications on the right.
#
#  Usage:
#    scripts/make-dmg.sh                # clean Release build, then package
#    scripts/make-dmg.sh --skip-build   # package whatever is already in build/
#
#  Output: dist/Simple-Clipboard-<version>.dmg (+ .sha256)
#
set -euo pipefail

APP_NAME="Simple Clipboard"
BUNDLE="${APP_NAME}.app"
SCHEME="Simple Clipboard"
PROJECT="Simple Clipboard.xcodeproj"
VOLUME_NAME="Simple Clipboard"

# Must match the geometry in scripts/dmg-background.swift.
WINDOW_WIDTH=660
WINDOW_HEIGHT=400
ICON_SIZE=128
APP_ICON_X=172
APP_ICON_Y=196
APPLICATIONS_ICON_X=488
APPLICATIONS_ICON_Y=196

# Finder's `bounds` is the window's *outer* frame, but the background image and
# the icon coordinates are both anchored to the content area below the title
# bar. Grow the frame by the title bar so all WINDOW_HEIGHT points of artwork
# are actually visible. Measured on macOS 26.
TITLE_BAR_HEIGHT=32

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGE="$BUILD_DIR/dmg-stage"
DIST="$ROOT/dist"
APP="$DERIVED_DATA/Build/Products/Release/$BUNDLE"

# Finder is the only thing that can write a volume's icon layout, and driving it
# needs Automation permission. The layout it produces is deterministic, so the
# first successful run caches it here and every later run (or a CI box with no
# Finder access) just copies it back in. Checked in without the leading dot so
# .gitignore does not swallow it.
LAYOUT_CACHE="$ROOT/scripts/dmg-assets/DS_Store"

SKIP_BUILD=0
for argument in "$@"; do
    case "$argument" in
        --skip-build) SKIP_BUILD=1 ;;
        *) echo "unknown option: $argument" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$1" >&2; }

# ---------------------------------------------------------------- build

if [ "$SKIP_BUILD" -eq 0 ]; then
    step "Building $APP_NAME (Release, universal)"
    # 'generic/platform=macOS' + explicit ARCHS so the binary runs on Apple
    # silicon and on the Intel Macs that still take macOS 26.
    xcodebuild \
        -project "$ROOT/$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        ARCHS="arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        clean build
fi

[ -d "$APP" ] || { echo "no app bundle at $APP" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$DIST/Simple-Clipboard-$VERSION.dmg"

step "Packaging version $VERSION (build $BUILD_NUMBER)"
codesign --verify --strict "$APP" || warn "the app bundle failed signature verification"
lipo -archs "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/    architectures: /'

# ---------------------------------------------------------------- stage

step "Staging disk-image contents"
rm -rf "$STAGE"
mkdir -p "$STAGE/.background" "$DIST"

ditto "$APP" "$STAGE/$BUNDLE"
xattr -cr "$STAGE/$BUNDLE"            # strip quarantine / provenance from the copy
# Don't `SetFile -a E` the bundle to hide ".app" in the label: that Finder info
# on the bundle root fails `codesign --verify --strict` ("detritus not allowed").
ln -s /Applications "$STAGE/Applications"

swift "$ROOT/scripts/dmg-background.swift" "$BUILD_DIR/background.png" "$BUILD_DIR/background@2x.png" "$VERSION"
# One TIFF holding both representations, so the window is crisp on Retina.
tiffutil -cathidpicheck "$BUILD_DIR/background.png" "$BUILD_DIR/background@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null

# Built outside the staging folder on purpose: it is copied onto the volume
# only after Finder has run (see the layout step for why).
ICONSET="$BUILD_DIR/VolumeIcon.iconset"
VOLUME_ICON="$BUILD_DIR/VolumeIcon.icns"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp "$ROOT/Simple Clipboard/Resources/Assets.xcassets/AppIcon.appiconset/"icon_*.png "$ICONSET/"
iconutil --convert icns "$ICONSET" --output "$VOLUME_ICON"

# ---------------------------------------------------------------- writable image

step "Creating writable image"
READWRITE="$BUILD_DIR/rw.dmg"
rm -f "$READWRITE"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 32 ))

hdiutil create \
    -srcfolder "$STAGE" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size "${SIZE_MB}m" \
    "$READWRITE" >/dev/null

if [ -d "/Volumes/$VOLUME_NAME" ]; then
    hdiutil detach "/Volumes/$VOLUME_NAME" -force >/dev/null 2>&1 || true
fi

DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$READWRITE" \
    | grep -Eo '^/dev/disk[0-9]+s[0-9]+' | tail -1)"
MOUNT="/Volumes/$VOLUME_NAME"
trap 'hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true' EXIT

[ -d "$MOUNT" ] || { echo "volume did not mount at $MOUNT" >&2; exit 1; }

# ---------------------------------------------------------------- layout

step "Applying window layout"

# Finder writes the icon positions, background and view options into the
# volume's .DS_Store. If it cannot be driven, fall back to the cached layout;
# without either, the image is still valid, just unstyled.
if osascript <<APPLESCRIPT
with timeout of 120 seconds
    tell application "Finder"
        tell disk "$VOLUME_NAME"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, $((200 + WINDOW_WIDTH)), $((120 + WINDOW_HEIGHT + TITLE_BAR_HEIGHT))}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to $ICON_SIZE
            set text size of viewOptions to 12
            set background picture of viewOptions to file ".background:background.tiff"
            set position of item "$BUNDLE" of container window to {$APP_ICON_X, $APP_ICON_Y}
            set position of item "Applications" of container window to {$APPLICATIONS_ICON_X, $APPLICATIONS_ICON_Y}
            close
            open
            update without registering applications
            delay 1
        end tell
    end tell
end timeout
APPLESCRIPT
then
    sync
    if [ -f "$MOUNT/.DS_Store" ]; then
        mkdir -p "$(dirname "$LAYOUT_CACHE")"
        cp "$MOUNT/.DS_Store" "$LAYOUT_CACHE"
        printf '    cached layout → %s\n' "${LAYOUT_CACHE#"$ROOT"/}"
    fi
elif [ -f "$LAYOUT_CACHE" ]; then
    warn "could not drive Finder — reusing the cached layout."
    cp "$LAYOUT_CACHE" "$MOUNT/.DS_Store"
else
    warn "could not drive Finder and no cached layout exists — the image will be unstyled."
    warn "Grant your terminal Automation access to Finder (System Settings › Privacy & Security › Automation) and re-run."
fi

# Strictly after the Finder step: opening a *writable* volume makes Finder
# consume .VolumeIcon.icns — it deletes the file and clears the custom-icon
# bit. Installing the icon last survives, because the shipped image is read-only.
cp "$VOLUME_ICON" "$MOUNT/.VolumeIcon.icns"
SetFile -c icnC "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"

# Housekeeping Finder leaves on the volume; no reason to ship it.
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" 2>/dev/null || true

chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync

# ---------------------------------------------------------------- compress

step "Compressing"
hdiutil detach "$DEVICE" >/dev/null
trap - EXIT

rm -f "$DMG"
hdiutil convert "$READWRITE" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$READWRITE"

( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

step "Done"
printf '    %s (%s)\n' "$DMG" "$(du -h "$DMG" | cut -f1)"
printf '    %s\n' "$(cat "$DMG.sha256")"
