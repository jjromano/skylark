#!/usr/bin/env bash
#
# bundle.sh — build release and assemble dist/Skylark.app, then codesign with
# the "Skylark Dev Signing" identity (falls back to ad-hoc with a loud warning).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Skylark"
IDENTITY="Skylark Dev Signing"
BUILD_DIR=".build/release"
DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "→ swift build -c release --product Skylark"
# Build only the app product so the shipping bundle never pulls in the test
# targets (and their swift-testing dependency).
swift build -c release --product Skylark

echo "→ Assembling $APP"
# Keep dist/ out of the Spotlight index. This build artifact shares the installed
# copy's bundle ID (com.jjromano.skylark); on macOS 26 the Applications view /
# Spotlight is what would show it as a second "Skylark", and this marker excludes
# dist/ from that index. (The install path in install.sh goes further and deletes
# dist/ outright after copying it to /Applications.) Cheap belt-and-braces.
mkdir -p "$DIST"
touch "$DIST/.metadata_never_index"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BUILD_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$CONTENTS/Info.plist"

echo "→ Stamping build metadata"
PLIST="$CONTENTS/Info.plist"
PLISTBUDDY="/usr/libexec/PlistBuddy"

# Sets String key $2 to value $3 in $PLIST, adding it if absent (Info.plist is
# freshly copied above, but Delete-then-Add keeps this safe to re-run).
stamp_plist() {
    local key="$1" value="$2"
    "$PLISTBUDDY" -c "Delete :$key" "$PLIST" >/dev/null 2>&1 || true
    "$PLISTBUDDY" -c "Add :$key string $value" "$PLIST"
}

if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BUILD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$BUILD_COMMIT" ]]; then
        stamp_plist "SkylarkBuildCommit" "$BUILD_COMMIT"
        echo "  • SkylarkBuildCommit = $BUILD_COMMIT"
    fi

    RAW_REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$RAW_REMOTE" ]]; then
        # Normalize both `git@github.com:owner/repo.git` and
        # `https://github.com/owner/repo(.git)` to `https://github.com/owner/repo`.
        NORMALIZED_REMOTE="$RAW_REMOTE"
        if [[ "$NORMALIZED_REMOTE" =~ ^git@([^:]+):(.+)$ ]]; then
            NORMALIZED_REMOTE="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        fi
        NORMALIZED_REMOTE="${NORMALIZED_REMOTE%.git}"
        stamp_plist "SkylarkRepoRemote" "$NORMALIZED_REMOTE"
        echo "  • SkylarkRepoRemote = $NORMALIZED_REMOTE"
    fi
else
    echo "  (not a git checkout — omitting SkylarkBuildCommit/SkylarkRepoRemote)"
fi

BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
stamp_plist "SkylarkBuildDate" "$BUILD_DATE"
stamp_plist "SkylarkRepoPath" "$REPO_ROOT"
echo "  • SkylarkBuildDate = $BUILD_DATE"
echo "  • SkylarkRepoPath = $REPO_ROOT"

if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
else
    echo "⚠️  Resources/AppIcon.icns not found — run 'swift Scripts/make-icon.swift' to generate it."
fi

# Copy any SwiftPM resource bundles (<Pkg>_<Target>.bundle) next to the binary.
# (Phase 0 ships none, but be forward-compatible.)
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
    echo "  • bundling resource: $(basename "$bundle")"
    cp -R "$bundle" "$CONTENTS/Resources/"
done
shopt -u nullglob

# Embed binary frameworks SwiftPM linked against (currently llama.xcframework —
# the local Qwen cleanup engine). SwiftPM copies the framework next to the
# product in .build and links it as @rpath with only `@loader_path` on the rpath,
# so an unembedded bundle would launch fine until the first local cleanup and
# then fail to dlopen. Copy it to the conventional Contents/Frameworks and add
# the matching rpath (install_name_tool runs BEFORE codesigning below).
shopt -s nullglob
FRAMEWORKS=("$BUILD_DIR"/*.framework)
if (( ${#FRAMEWORKS[@]} )); then
    mkdir -p "$CONTENTS/Frameworks"
    for framework in "${FRAMEWORKS[@]}"; do
        echo "  • embedding framework: $(basename "$framework")"
        cp -R "$framework" "$CONTENTS/Frameworks/"
    done
    if ! otool -l "$CONTENTS/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/$APP_NAME"
    fi
fi
shopt -u nullglob

# PkgInfo (harmless, expected by some tooling).
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "→ Codesigning"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    # No hardened runtime (--options runtime): this is a locally self-signed
    # build that is never notarized, so hardened runtime buys nothing — but it
    # WOULD require a com.apple.security.device.audio-input entitlement or macOS
    # blocks the microphone (AVAuthorizationStatus.restricted → shows "denied"
    # and the app never appears in Privacy → Microphone).
    codesign --force --deep \
        --sign "$IDENTITY" "$APP"
    echo "✓ Signed with '$IDENTITY'"
else
    echo "⚠️  WARNING: identity '$IDENTITY' not found — signing ad-hoc (--sign -)."
    echo "⚠️  TCC permission grants (Mic/Accessibility/Input Monitoring) will NOT"
    echo "⚠️  survive rebuilds. Run 'make cert' (with sudo) to fix this."
    codesign --force --deep --sign - "$APP"
fi

echo "→ codesign -dv:"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'

# Keeping this build artifact from surfacing as a second "Skylark" in the
# Applications view / Spotlight (it shares the installed copy's bundle id,
# com.jjromano.skylark) is handled by the `.metadata_never_index` marker written
# at the top: on macOS 26 the app browser is Spotlight-driven, so excluding
# dist/ from the Spotlight index keeps it out of what the user actually sees.
#
# We deliberately do NOT try to `lsregister -u` this bundle here: codesigning it
# makes `lsd` register it asynchronously a beat later, so an unregister loses that
# race and can even re-add it — chasing the raw Launch Services database is
# whack-a-mole and, since that database isn't the user-visible surface, pointless.
# The install path (install.sh) additionally deletes dist/ after copying it to
# /Applications, which removes the bundle outright.
echo "  • dist/ excluded from the Spotlight index (.metadata_never_index)"

echo "✓ Built $APP"
