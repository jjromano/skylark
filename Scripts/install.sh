#!/usr/bin/env bash
#
# install.sh — build Skylark from source and install it to /Applications.
#
# Intended for a second, non-technical user (per PRD §4) running this after
# `git clone`. Every failure exits with a clear, actionable message.
# Idempotent: safe to re-run after pulling updates.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Skylark"
IDENTITY="Skylark Dev Signing"
DIST_APP="dist/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"

fail() {
    echo ""
    echo "✗ $1" >&2
    exit 1
}

echo "→ Checking system requirements…"

# --- Apple Silicon -----------------------------------------------------
ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
    fail "Skylark requires an Apple Silicon Mac (arm64). This machine reports '$ARCH'."
fi
echo "  ✓ Apple Silicon ($ARCH)"

# --- macOS version -------------------------------------------------------
OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
if [[ "$OS_MAJOR" -lt 26 ]]; then
    fail "Skylark requires macOS 26 or later. This machine is running macOS $OS_VERSION.
Update via System Settings → General → Software Update, then re-run this script."
fi
echo "  ✓ macOS $OS_VERSION"

# --- Command Line Tools (no Xcode needed) --------------------------------
if ! xcode-select -p >/dev/null 2>&1; then
    echo ""
    echo "✗ Command Line Tools are not installed."
    echo ""
    echo "Run:"
    echo "    xcode-select --install"
    echo ""
    echo "A dialog will prompt you to install them (a few minutes, no Xcode"
    echo "required). Re-run this script once that finishes."
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    fail "Command Line Tools are present but 'swift' isn't on PATH. Try opening a new terminal, or run 'xcode-select --install' again."
fi
echo "  ✓ Command Line Tools ($(xcode-select -p))"
echo "  ✓ $(swift --version 2>&1 | head -1)"

# The Package.swift manifest requires Swift tools 6.2+. Command Line Tools that
# predate that fail deep in the build with an opaque "tools version" error, so
# catch it here with an actionable message instead.
REQUIRED_SWIFT="6.2"
SWIFT_VER="$(swift --version 2>&1 | grep -oE 'Swift version [0-9]+\.[0-9]+' | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
if [[ -n "$SWIFT_VER" && "$(printf '%s\n%s\n' "$REQUIRED_SWIFT" "$SWIFT_VER" | sort -V | head -1)" != "$REQUIRED_SWIFT" ]]; then
    fail "Skylark needs Swift $REQUIRED_SWIFT or newer to build, but this machine has Swift $SWIFT_VER.
Your Command Line Tools are out of date. Update them, then re-run this script:

    softwareupdate --list
    sudo softwareupdate --install \"<newest 'Command Line Tools for Xcode 26.x' shown>\"

Or reinstall the latest outright:
    sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select --install"
fi

# --- Signing certificate --------------------------------------------------
echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "→ Signing identity '$IDENTITY' already present — skipping cert setup."
else
    cat <<EOF
→ Creating the local "$IDENTITY" signing certificate.

This is a ONE-TIME, self-signed certificate used only to sign your own copy
of Skylark. macOS ties permission grants (Microphone, Accessibility, Input
Monitoring) to the app's signing identity, so without a stable identity
every rebuild would look like a brand-new app and you'd have to re-grant
all three permissions each time. This step needs your password to add the
certificate to the System keychain as trusted for code signing.

EOF
    sudo "$REPO_ROOT/Scripts/make-cert.sh" || fail "Could not create the signing certificate. See the error above."
fi

# --- Build -----------------------------------------------------------------
echo ""
echo "→ Building Skylark (this can take a few minutes on first build)…"
make app || fail "Build failed. See the error above — 'swift build' output is included."

[[ -d "$DIST_APP" ]] || fail "Build reported success but $DIST_APP is missing. Something went wrong assembling the bundle."
echo "  ✓ Built $DIST_APP"

# --- Install to /Applications ----------------------------------------------
echo ""
if [[ -d "$INSTALLED_APP" ]]; then
    read -r -p "→ $INSTALLED_APP already exists — overwrite it? [y/N] " REPLY
    case "$REPLY" in
        [yY]|[yY][eE][sS])
            rm -rf "$INSTALLED_APP"
            ;;
        *)
            echo "  Skipped install — leaving the existing $INSTALLED_APP in place."
            echo "  Your new build is still available at $REPO_ROOT/$DIST_APP."
            exit 0
            ;;
    esac
fi

cp -R "$DIST_APP" "$INSTALLED_APP" || fail "Could not copy $DIST_APP to /Applications. Check disk space and permissions on /Applications."
echo "  ✓ Installed to $INSTALLED_APP"

# --- Launch ------------------------------------------------------------
echo ""
echo "→ Launching Skylark…"
open "$INSTALLED_APP"

cat <<'EOF'

════════════════════════════════════════════════════════════════════════
  Skylark is installed and launching. First-run checklist:
════════════════════════════════════════════════════════════════════════

  1. macOS will ask for three permissions — grant all three:
       • Microphone         (to hear you)
       • Accessibility      (to insert text at your cursor)
       • Input Monitoring   (to detect the global Fn hotkey)

  2. Skylark suppresses the system Globe/Fn action on its own while
     running, so no System Settings change is required. If you'd rather
     make that explicit, set:
       System Settings → Keyboard → Press 🌐 key to: Do Nothing

  3. On first dictation, Skylark downloads the local speech model
     (~483 MB) in the background — progress shows in the menu bar.

  4. Hold Fn to talk, release to paste. Double-tap Fn for hands-free.
     Esc cancels. Click the mic icon in the menu bar for Settings.

  See README.md for full usage, cloud setup, and troubleshooting.
════════════════════════════════════════════════════════════════════════
EOF
