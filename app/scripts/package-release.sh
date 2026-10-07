#!/usr/bin/env bash
# Builds Hushdeck.app and packages it for a GitHub release / Homebrew cask:
#
#   dist/Hushdeck-<version>.zip          the zipped, ad-hoc signed app (ditto, keeps the signature)
#   dist/Hushdeck-<version>.zip.sha256   "<sha256>  Hushdeck-<version>.zip"
#   dist/hushdeck.rb                     packaging/homebrew/hushdeck.rb with version and sha filled in
#
#   scripts/package-release.sh                     # version 0.1.0
#   HUSHDECK_VERSION=0.2.0 scripts/package-release.sh
#   HUSHDECK_SKIP_BUILD=1 scripts/package-release.sh   # package an existing dist/Hushdeck.app
#   HUSHDECK_REPOSITORY_URL=https://github.com/you/Hushdeck  # also fills the cask's URLs
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/.." && pwd)"
export HUSHDECK_VERSION="${HUSHDECK_VERSION:-0.1.0}"
VERSION="$HUSHDECK_VERSION"
DIST="$APP_ROOT/dist"
APP="$DIST/Hushdeck.app"
ZIP_NAME="Hushdeck-$VERSION.zip"
ZIP="$DIST/$ZIP_NAME"
CASK_TEMPLATE="$REPO_ROOT/packaging/homebrew/hushdeck.rb"

step() { printf '\033[1m==> %s\033[0m\n' "$*"; }

if [[ "${HUSHDECK_SKIP_BUILD:-0}" != "1" ]]; then
    "$APP_ROOT/scripts/build-app.sh"
fi
[[ -d "$APP" ]] || { echo "error: $APP not found" >&2; exit 1; }

built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$built_version" != "$VERSION" ]]; then
    echo "error: $APP is version $built_version, expected $VERSION" >&2
    exit 1
fi

step "Zipping $ZIP_NAME"
rm -f "$ZIP" "$ZIP.sha256"
# ditto keeps the code signature, extended attributes and symlinks intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
SHA256="$(cut -d ' ' -f 1 "$ZIP.sha256")"

step "Verifying the archive"
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/Hushdeck.app"
if [[ -x "$CHECK/Hushdeck.app/Contents/Resources/headsetcontrol" ]]; then
    "$CHECK/Hushdeck.app/Contents/Resources/headsetcontrol" --version >/dev/null
fi

if [[ -f "$CASK_TEMPLATE" ]]; then
    step "Rendering the Homebrew cask"
    python3 - "$CASK_TEMPLATE" "$DIST/hushdeck.rb" "$VERSION" "$SHA256" "${HUSHDECK_REPOSITORY_URL:-}" <<'PY'
import re, sys
template, out, version, sha, repo = sys.argv[1:]
text = open(template).read()
text = re.sub(r'version "[^"]*"', f'version "{version}"', text, count=1)
text = re.sub(r'sha256 "[^"]*"', f'sha256 "{sha}"', text, count=1)
if repo:
    text = text.replace("https://github.com/eYdr1en/Hushdeck", repo.rstrip("/"))
open(out, "w").write(text)
PY
fi

step "Done"
echo "    $ZIP"
echo "    $ZIP.sha256  ($SHA256)"
[[ -f "$DIST/hushdeck.rb" ]] && echo "    $DIST/hushdeck.rb"
