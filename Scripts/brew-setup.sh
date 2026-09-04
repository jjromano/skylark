#!/usr/bin/env bash
#
# brew-setup.sh — finish a Homebrew install of Skylark.
#
# WHY THIS EXISTS AS A SEPARATE STEP. `brew install` cannot do the whole job,
# for one specific reason: Skylark needs a stable code-signing identity, and
# creating it writes to the System keychain, which needs root. Homebrew refuses
# to run as root and should never prompt for a password mid-install, so the
# privileged half lives here and the user runs it once, deliberately.
#
# The signing identity is not ceremony. macOS ties permission grants
# (Microphone, Accessibility, Input Monitoring) to the app's signature, so an
# ad-hoc signed build looks like a brand-new app after every upgrade and makes
# you re-grant all three. With the identity in place, `brew upgrade` keeps your
# permissions.
#
# Safe to re-run; that is in fact how you finish an upgrade.

set -euo pipefail

APP_NAME="Skylark"
BUNDLE_ID="com.jjromano.skylark"
IDENTITY="Skylark Dev Signing"
INSTALLED_APP="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

fail() { echo "" >&2; echo "✗ $1" >&2; exit 1; }

# The app Homebrew built. `--prefix skylark` resolves to the stable opt path, so
# this keeps working across upgrades without knowing the version number.
if [[ $# -ge 1 ]]; then
    SOURCE_APP="$1"
else
    command -v brew >/dev/null 2>&1 || fail "Homebrew not found, and no app path was given.

Usage when running by hand:
    $0 /path/to/Skylark.app"
    BREW_OPT="$(brew --prefix skylark 2>/dev/null || true)"
    [[ -n "$BREW_OPT" ]] || fail "Skylark doesn't look installed via Homebrew. Run:
    brew install --HEAD jjromano/skylark/skylark"
    SOURCE_APP="$BREW_OPT/$APP_NAME.app"
fi

[[ -d "$SOURCE_APP" ]] || fail "No app bundle at $SOURCE_APP. Try reinstalling:
    brew reinstall --HEAD jjromano/skylark/skylark"

echo "→ Finishing the Skylark install"
echo "  source: $SOURCE_APP"

# --- 1. Signing identity ---------------------------------------------------
echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "→ Signing identity '$IDENTITY' already present."
else
    cat <<EOF
→ Creating the local "$IDENTITY" certificate (one time).

This is a self-signed certificate used only to sign your own copy of Skylark.
It is not sent anywhere and it grants nothing beyond signing this app. macOS
needs your password to add it to the System keychain as trusted for signing.

Without it, every upgrade would look like a different app to macOS and you'd
re-grant Microphone, Accessibility and Input Monitoring each time.

EOF
    CERT_SCRIPT="$(dirname "$SOURCE_APP")/libexec/make-cert.sh"
    [[ -f "$CERT_SCRIPT" ]] || CERT_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/make-cert.sh"
    [[ -f "$CERT_SCRIPT" ]] || fail "Could not find make-cert.sh next to this script or in the Homebrew prefix."
    sudo "$CERT_SCRIPT" || fail "Could not create the signing certificate. See the error above."
fi

# --- 2. Re-sign the built bundle ------------------------------------------
# Homebrew builds in a sandbox where the System-keychain identity may not have
# existed yet (first install signs ad-hoc). Re-signing here is what actually
# makes permissions survive the next upgrade.
echo ""
echo "→ Signing $APP_NAME with '$IDENTITY'…"
codesign --force --deep --sign "$IDENTITY" "$SOURCE_APP" 2>/dev/null \
    || fail "Signing failed. If the certificate was just created, open a new terminal and re-run."
echo "  ✓ Signed"

# --- 3. Install to /Applications -------------------------------------------
# A menu-bar app is expected in /Applications: Spotlight, Launchpad and the
# Login Items pane all look there. The Cellar path is version-scoped and not
# somewhere a person should be pointed.
echo ""
if pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "→ Quitting the running ${APP_NAME}…"
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 25); do
        pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || break
        sleep 0.2
    done
fi

rm -rf "$INSTALLED_APP"
cp -R "$SOURCE_APP" "$INSTALLED_APP" \
    || fail "Could not copy to $INSTALLED_APP. Check permissions on /Applications."
echo "  ✓ Installed to $INSTALLED_APP"

# Register the fresh copy so `open` and Launchpad find it immediately rather
# than waiting for macOS to rescan. Deliberately NOT `lsregister -gc`, which
# garbage-collects the entire system database and is far too blunt here.
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true
fi

# --- 4. Launch -------------------------------------------------------------
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
echo ""
echo "→ Launching ${APP_NAME} ${VERSION}…"
open "$INSTALLED_APP" 2>/dev/null || true

for _ in $(seq 1 75); do
    pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 && break
    sleep 0.2
done

cat <<EOF

════════════════════════════════════════════════════════════════════════
  Skylark $VERSION is installed.
════════════════════════════════════════════════════════════════════════

  It is a MENU-BAR app — look for the bird near the clock, not in the Dock.

  On first launch macOS will ask for three permissions. Grant all three:
    • Microphone          — to hear you
    • Accessibility       — to type text where your cursor is
    • Input Monitoring    — to notice the Fn key being held

  Then hold Fn, speak, and release.

  To update later:
      brew upgrade skylark && skylark-setup

════════════════════════════════════════════════════════════════════════
EOF
