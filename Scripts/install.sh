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
BUNDLE_ID="com.jjromano.skylark"
DIST_APP="$REPO_ROOT/dist/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

fail() {
    echo ""
    echo "✗ $1" >&2
    exit 1
}

# PIDs of any running Skylark build (installed copy or a dist/ dev build).
skylark_pids() {
    pgrep -f "$APP_NAME\.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
}

# True while the *installed* copy has a live process.
installed_running() {
    pgrep -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1
}

# `open` on a bundle whose process is already running just foregrounds that
# process — it does NOT relaunch against the new binary on disk. So installing
# over a running Skylark would silently leave the old build running. Quit it
# first, and via AppleScript rather than a kill so the app's own shutdown path
# runs (clipboard restore, pending state flushed).
quit_running_skylark() {
    [[ -n "$(skylark_pids)" ]] || return 0

    echo "→ Quitting the running Skylark…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

    # AppleScript returns as soon as the quit event is accepted, not when the
    # process is gone — poll for the real exit (10s).
    for _ in $(seq 1 50); do
        if [[ -z "$(skylark_pids)" ]]; then
            echo "  ✓ Skylark quit"
            return 0
        fi
        sleep 0.2
    done

    fail "Skylark is still running and wouldn't quit on its own (waited 10s).
Overwriting a running app would leave you on the old build, so nothing was changed.

Quit Skylark from its menu bar icon, then re-run this script.
If macOS asked whether Terminal may control Skylark and you chose Don't Allow,
re-enable it in System Settings → Privacy & Security → Automation."
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
            ;;  # removal happens below, after the running app has quit

        *)
            echo "  Skipped install — leaving the existing $INSTALLED_APP in place."
            echo "  Your new build is still available at $DIST_APP."
            exit 0
            ;;
    esac
fi

# Quit before touching the bundle — also covers the case where /Applications is
# empty but a dist/ dev build is running under the same bundle ID (LaunchServices
# would activate that one instead of launching the new install).
quit_running_skylark
rm -rf "$INSTALLED_APP"

cp -R "$DIST_APP" "$INSTALLED_APP" || fail "Could not copy $DIST_APP to /Applications. Check disk space and permissions on /Applications."
echo "  ✓ Installed to $INSTALLED_APP"

# Make sure Launch Services knows about the freshly-installed copy before we try
# to launch it. Both this and the dist/ build carry the same bundle ID
# (com.jjromano.skylark); if the only registration LS holds points at dist/ (or
# at nothing), `open` below has nothing to launch and the app is missing from
# Launchpad/Spotlight until macOS rescans /Applications on its own schedule.
# Registering the installed copy here closes that window.
#
# The dist/ duplicate is dropped later, at the very end of the script — not here.
# Deliberately NOT using `lsregister -gc`: it garbage-collects the entire
# system-wide Launch Services database, which is far too blunt for an installer
# and was what left the app unlaunchable and missing from Launchpad in v0.7.3.
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true
    echo "  ✓ Registered $INSTALLED_APP with Launch Services"
fi

# --- Launch ------------------------------------------------------------
echo ""
echo "→ Launching Skylark…"

INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || echo "?")"
INSTALLED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || echo "?")"

# `open` must be status-checked: unchecked under `set -e` a failure aborts the
# script instantly, skipping both the confirmation below and the first-run
# checklist — so a failed launch would look like a silent success.
if ! open "$INSTALLED_APP" 2>/dev/null; then
    echo "  … first launch attempt failed; re-registering and retrying"
    [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null 2>&1 || true
    open "$INSTALLED_APP" 2>/dev/null || true
fi

# Confirm the new build actually came up, and say which version it is — after an
# update the whole question is "did it take?", and the version number answers it.
# 15s: a cold launch of the release binary is well under that, but a 5s budget
# false-alarmed on slower starts.
for _ in $(seq 1 75); do
    installed_running && break
    sleep 0.2
done
if installed_running; then
    echo "  ✓ Skylark $INSTALLED_VERSION (build $INSTALLED_BUILD) is now running"
else
    echo ""
    echo "  ⚠️  Skylark $INSTALLED_VERSION (build $INSTALLED_BUILD) is installed at"
    echo "     $INSTALLED_APP but did not launch. Open it from Finder → Applications."
    echo "     (Skylark is a menu-bar app — look for the mic icon, not a Dock icon.)"
fi

# The dist/ build copy has now been copied to /Applications and that copy is
# running, so the one under dist/ is redundant — and as long as a signed
# Skylark.app physically sits there, `lsd` keeps re-registering it (codesigning
# it during the build triggers an async registration that no amount of
# `lsregister -u` can reliably outrun — that whack-a-mole is what produced the
# duplicate "Skylark" in Launchpad and Spotlight). So delete the bundle instead
# of fighting to unregister it: with nothing on disk there, the duplicate can't
# come back. `make run` / `make app` rebuild it on demand, so nothing is lost.
# Best-effort — a leftover build artifact must never fail an otherwise-good install.
if [[ -d "$DIST_APP" ]]; then
    rm -rf "$DIST_APP" 2>/dev/null || true
    [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$DIST_APP" >/dev/null 2>&1 || true
    echo "  ✓ Cleaned up the redundant dist/ build copy (no duplicate Launchpad icon)"
fi

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
