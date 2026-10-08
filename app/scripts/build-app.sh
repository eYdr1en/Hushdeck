#!/usr/bin/env bash
# Builds dist/Hushdeck.app: release build, Info.plist (LSUIElement), bundled
# headsetcontrol CLI (plus any Homebrew dylibs it needs), code signature (ad-hoc unless
# HUSHDECK_SIGN_IDENTITY is set).
#
#   scripts/build-app.sh                       # version 0.1.0
#   HUSHDECK_VERSION=0.2.0 scripts/build-app.sh
#   HEADSETCONTROL_BIN=/path/to/headsetcontrol scripts/build-app.sh
#   HUSHDECK_BUNDLE_CLI=0 scripts/build-app.sh  # don't bundle the CLI
#   HUSHDECK_REPOSITORY_URL=https://github.com/you/Hushdeck scripts/build-app.sh
#                                              # enables the Website / Report an Issue links in About
#   HUSHDECK_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-app.sh
#                                              # Developer ID + hardened runtime (needed for notarisation)
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${HUSHDECK_VERSION:-0.1.0}"
BUILD_NUMBER="${HUSHDECK_BUILD_NUMBER:-$(git -C "$APP_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
REPOSITORY_URL="${HUSHDECK_REPOSITORY_URL:-}"
COPYRIGHT="${HUSHDECK_COPYRIGHT:-© $(date +%Y) Adrián Horváth}"
BUNDLE_ID="com.adrianhorvath.hushdeck"
DIST="$APP_ROOT/dist"
APP="$DIST/Hushdeck.app"

step() { printf '\033[1m==> %s\033[0m\n' "$*"; }

step "Building release binary"
cd "$APP_ROOT"
swift build -c release --arch arm64 --product Hushdeck
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Hushdeck" "$APP/Contents/MacOS/Hushdeck"

# Localisations: SwiftPM compiles Localizable.xcstrings into <lang>.lproj inside the
# target's resource bundle. SwiftUI looks strings up in the main bundle, so the
# .lproj folders go straight into Contents/Resources. English is the source language
# (the keys are the English text), so en.lproj only needs to exist.
RESOURCE_BUNDLE="$BIN_DIR/Hushdeck_Hushdeck.bundle"
while IFS= read -r lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
done < <(find "$RESOURCE_BUNDLE" -maxdepth 3 -type d -name '*.lproj')
mkdir -p "$APP/Contents/Resources/en.lproj"
LOCALIZATIONS="$(cd "$APP/Contents/Resources" && ls -d *.lproj | sed 's/\.lproj$//' | sort)"
LOCALIZATIONS_XML="$(for l in $LOCALIZATIONS; do printf '        <string>%s</string>\n' "$l"; done)"
echo "    localisations: $(echo $LOCALIZATIONS)"

# App icon, drawn by scripts/make-icon.swift.
ICON_WORK="$(mktemp -d)"
swift "$APP_ROOT/scripts/make-icon.swift" "$ICON_WORK/AppIcon.iconset"
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_WORK"

REPOSITORY_XML=""
if [[ -n "$REPOSITORY_URL" ]]; then
    REPOSITORY_XML="    <key>HushdeckRepositoryURL</key>
    <string>${REPOSITORY_URL}</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Hushdeck</string>
    <key>CFBundleExecutable</key>
    <string>Hushdeck</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleLocalizations</key>
    <array>
${LOCALIZATIONS_XML}
    </array>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Hushdeck</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>${COPYRIGHT}</string>
${REPOSITORY_XML}
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# --- Bundle the HeadsetControl CLI -------------------------------------------
find_cli() {
    local candidate
    for candidate in \
        "${HEADSETCONTROL_BIN:-}" \
        /opt/homebrew/bin/headsetcontrol \
        /usr/local/bin/headsetcontrol \
        "$HOME/coding/HeadsetControl/build/headsetcontrol"; do
        if [[ -n "$candidate" && -x "$candidate" && ! -d "$candidate" ]]; then
            # Resolve Homebrew symlinks so we copy the real file.
            python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$candidate"
            return 0
        fi
    done
    return 1
}

if [[ "${HUSHDECK_BUNDLE_CLI:-1}" != "0" ]] && CLI="$(find_cli)"; then
    step "Bundling headsetcontrol from $CLI"
    DEST="$APP/Contents/Resources/headsetcontrol"
    cp "$CLI" "$DEST"
    chmod 755 "$DEST"

    # HeadsetControl is GPL-3.0: ship its licence next to it. It is run as a separate
    # process and never linked into Hushdeck.
    for license in "$(dirname "$CLI")/../license" "$(dirname "$CLI")/../LICENSE" \
                   "$(dirname "$CLI")/../share/doc/headsetcontrol/license" \
                   "$(brew --prefix headsetcontrol 2>/dev/null || echo /nonexistent)/license"; do
        if [[ -f "$license" ]]; then
            cp "$license" "$APP/Contents/Resources/headsetcontrol-LICENSE.txt"
            break
        fi
    done

    # Copy non-system dylibs (e.g. Homebrew's libhidapi) into Frameworks and
    # repoint the CLI at them, so the bundle works without Homebrew.
    while read -r dylib; do
        [[ -z "$dylib" ]] && continue
        name="$(basename "$dylib")"
        real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dylib")"
        echo "    embedding $name"
        # HIDAPI's BSD-style option requires shipping its notice with binaries.
        if [[ "$name" == libhidapi* ]]; then
            hidapi_prefix="$(cd "$(dirname "$real")/.." && pwd)"
            if [[ -f "$hidapi_prefix/LICENSE.txt" ]]; then
                { cat "$hidapi_prefix/LICENSE.txt"
                  for extra in LICENSE-bsd.txt LICENSE-orig.txt; do
                      if [[ -f "$hidapi_prefix/$extra" ]]; then
                          printf '\n\n==== %s ====\n\n' "$extra"
                          cat "$hidapi_prefix/$extra"
                      fi
                  done
                } > "$APP/Contents/Resources/hidapi-LICENSE.txt"
            else
                echo "warning: no HIDAPI licence found next to $real" >&2
            fi
        fi
        cp "$real" "$APP/Contents/Frameworks/$name"
        chmod 644 "$APP/Contents/Frameworks/$name"
        install_name_tool -id "@rpath/$name" "$APP/Contents/Frameworks/$name" 2>/dev/null
        install_name_tool -change "$dylib" "@loader_path/../Frameworks/$name" "$DEST" 2>/dev/null
    done < <(otool -L "$DEST" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/homebrew|/usr/local)/' || true)
else
    echo "warning: headsetcontrol not bundled; Hushdeck will look for it at runtime." >&2
fi
rmdir "$APP/Contents/Frameworks" 2>/dev/null || true

# --- Sign ---------------------------------------------------------------------
# Nested code first (dylibs, then the CLI that loads them), the app last.
SIGN_IDENTITY="${HUSHDECK_SIGN_IDENTITY:-}"
if [[ -n "$SIGN_IDENTITY" ]]; then
    step "Signing with $SIGN_IDENTITY (hardened runtime)"
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp --options runtime)
else
    step "Ad-hoc signing"
    SIGN_ARGS=(--force --sign - --timestamp=none)
fi
if [[ -d "$APP/Contents/Frameworks" ]]; then
    for lib in "$APP/Contents/Frameworks"/*; do
        codesign "${SIGN_ARGS[@]}" "$lib"
    done
fi
if [[ -f "$APP/Contents/Resources/headsetcontrol" ]]; then
    codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/headsetcontrol"
fi
codesign "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

if [[ -f "$APP/Contents/Resources/headsetcontrol" ]]; then
    "$APP/Contents/Resources/headsetcontrol" --version >/dev/null
fi

# Launch Services caches the bundle's icon per path. A rebuilt bundle at the same path can
# keep a stale (icon-less) registration, which Notification Center then shows as a blank
# square, so register the fresh bundle explicitly.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$LSREGISTER" ]]; then
    step "Registering with Launch Services"
    "$LSREGISTER" -f "$APP" || true
fi

step "Done: $APP ($VERSION, build $BUILD_NUMBER)"
