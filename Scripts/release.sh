#!/usr/bin/env bash
#
# release.sh — one-command release packager: verify → test → bundle → sign for
# distribution (if possible) → package into a DMG → notarize + staple (if
# possible) → checksum → summary.
#
# There is currently NO Apple Developer ID certificate and NO paid Apple
# Developer Program membership on any machine building Skylark. That is a
# separate, not-yet-made decision. So every distribution-signing and
# notarization step here DETECTS whether the prerequisites exist and degrades
# to a clearly-labeled local-only artifact rather than failing the release.
# Once a Developer ID identity and notarytool credentials exist, this same
# script produces a fully signed, notarized, Gatekeeper-clean DMG with no
# changes required.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Skylark"
DEV_ID_PATTERN="Developer ID Application"
ENTITLEMENTS="Resources/Skylark.entitlements"
DIST="dist"
APP="$DIST/$APP_NAME.app"

SKIP_TESTS=0
ALLOW_DIRTY=0

fail() {
    echo ""
    echo "✗ $1" >&2
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --skip-tests)
            SKIP_TESTS=1
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            ;;
        -h|--help)
            cat <<EOF
Usage: Scripts/release.sh [--skip-tests] [--allow-dirty]

Builds, signs (if possible), packages, and notarizes (if possible) a Skylark
release DMG at dist/Skylark-<version>.dmg.

  --skip-tests   Skip 'make test'. Loud warning — never do this for a real
                 release; it means shipping without proof the suite passes.
  --allow-dirty  Proceed with uncommitted changes / not on main. Bad idea for
                 a real release: the artifact would not correspond to any
                 commit you (or anyone else) can point to later, so a bug
                 report against it can't be reproduced or bisected.
EOF
            exit 0
            ;;
        *)
            fail "Unknown argument: '$arg'. Run with --help for usage."
            ;;
    esac
done

echo "→ Checking machine and working tree…"

# --- Apple Silicon macOS -----------------------------------------------
ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
    fail "Releases must be built on Apple Silicon (arm64). This machine reports '$ARCH'."
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "Releases must be built on macOS. This machine reports '$(uname -s)'."
fi
echo "  ✓ Apple Silicon macOS ($ARCH)"

# --- Clean tree on main --------------------------------------------------
CURRENT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
DIRTY="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || echo "")"

if [[ -z "$CURRENT_BRANCH" ]]; then
    fail "Not a git checkout — can't verify branch/cleanliness. Releases must be built from a git clone of this repo."
fi

if [[ "$CURRENT_BRANCH" != "main" || -n "$DIRTY" ]]; then
    if [[ "$ALLOW_DIRTY" -eq 1 ]]; then
        echo "  ⚠️  Proceeding despite branch='$CURRENT_BRANCH' / uncommitted changes (--allow-dirty)."
        echo "  ⚠️  This artifact will not correspond to a reproducible commit — anyone who hits a"
        echo "  ⚠️  bug in it (including future-you) has no exact source to bisect against."
    else
        if [[ "$CURRENT_BRANCH" != "main" ]]; then
            fail "Not on 'main' (currently on '$CURRENT_BRANCH'). Releases are cut from main so the
artifact corresponds to a commit that's actually on the public history.
Switch to main, or pass --allow-dirty to override (not recommended)."
        fi
        fail "Working tree has uncommitted changes:
$DIRTY

A release built from an unclean tree can't be reproduced later — there's no
commit that matches what actually shipped. Commit or stash your changes, or
pass --allow-dirty to override (not recommended)."
    fi
else
    echo "  ✓ On main, working tree clean"
fi

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

# --- Version + changelog -------------------------------------------------
echo ""
echo "→ Reading version…"
PLISTBUDDY="/usr/libexec/PlistBuddy"
INFO_PLIST="Resources/Info.plist"

VERSION="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
BUILD_NUMBER="$("$PLISTBUDDY" -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"

[[ -n "$VERSION" ]] || fail "Could not read CFBundleShortVersionString from $INFO_PLIST."
[[ -n "$BUILD_NUMBER" ]] || fail "Could not read CFBundleVersion from $INFO_PLIST."
echo "  ✓ Version $VERSION (build $BUILD_NUMBER)"

# Every release must have a matching CHANGELOG entry (project hard rule: any
# behavior/UI change bumps the version AND adds a changelog entry in the same
# commit). Match "## <version>" at the start of a line, followed by whitespace
# or end-of-line, so "## 0.21.0" matches but doesn't false-positive on
# "## 0.21.0-beta" being confused with "## 0.21.0" — anchor tightly.
VERSION_ESCAPED="$(printf '%s' "$VERSION" | sed 's/[.[\*^$/]/\\&/g')"
if ! grep -qE "^## ${VERSION_ESCAPED}([[:space:]]|\$)" CHANGELOG.md; then
    fail "CHANGELOG.md has no '## $VERSION' section.

Every release needs a changelog entry for the version it ships (this
project's hard rule). Add a '## $VERSION' section to CHANGELOG.md describing
what changed, then re-run this script."
fi
echo "  ✓ CHANGELOG.md has a '## $VERSION' section"

# --- Tests -----------------------------------------------------------------
echo ""
if [[ "$SKIP_TESTS" -eq 1 ]]; then
    echo "⚠️  ⚠️  ⚠️  --skip-tests passed — SKIPPING THE TEST SUITE.  ⚠️  ⚠️  ⚠️"
    echo "⚠️  This release artifact has NOT been verified against the unit suite."
    echo "⚠️  Do not ship this to anyone else without a good reason for this flag."
else
    echo "→ make test"
    make test || fail "Tests failed. Fix the failure above, or pass --skip-tests to override
(not recommended — that means shipping without proof the suite passes)."
    echo "  ✓ Tests passed"
fi

# --- Build the app bundle ---------------------------------------------------
echo ""
echo "→ Building the app bundle (./Scripts/bundle.sh)…"
./Scripts/bundle.sh
[[ -d "$APP" ]] || fail "bundle.sh reported success but $APP is missing."

# --- Sign for distribution, if possible -------------------------------------
echo ""
echo "→ Signing for distribution…"

DEV_ID_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep "$DEV_ID_PATTERN" || true)"
# find-identity output looks like: '  1) HASH "Developer ID Application: Name (TEAMID)"'
DEV_ID_IDENTITY="$(printf '%s\n' "$DEV_ID_LINE" | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"

SIGNED_FOR_DISTRIBUTION=0

if [[ -n "$DEV_ID_IDENTITY" ]]; then
    echo "  → Found Developer ID identity: $DEV_ID_IDENTITY"

    # bundle.sh already signed the bundle with the local self-signed dev
    # identity (or ad-hoc) — re-sign with --force to replace that signature
    # with a proper distribution one. --options runtime enables the hardened
    # runtime, which notarization REQUIRES. --timestamp adds a secure
    # timestamp, also required for notarization.
    # SIGN INSIDE-OUT, AND DO NOT USE --deep.
    #
    # `--deep --entitlements X` applies the APP's entitlements to every nested
    # binary it signs, including llama.xcframework. Apple documents --deep as
    # unsuitable for distribution signing for exactly this reason: a framework
    # carrying the app's microphone and Apple Events entitlements is not what
    # was intended, and the notary service can reject it. The supported order is
    # nested code first (no entitlements), then the outer bundle (with them).
    NESTED_ARGS=(--force --options runtime --timestamp --sign "$DEV_ID_IDENTITY")
    if [[ -d "$APP/Contents/Frameworks" ]]; then
        for nested in "$APP/Contents/Frameworks"/*; do
            [[ -e "$nested" ]] || continue
            echo "  → signing nested: $(basename "$nested")"
            codesign "${NESTED_ARGS[@]}" "$nested"
        done
    fi

    # --options runtime enables the hardened runtime, which notarization
    # REQUIRES. --timestamp adds a secure timestamp, also required.
    CODESIGN_ARGS=(--force --options runtime --timestamp --sign "$DEV_ID_IDENTITY")
    if [[ -f "$ENTITLEMENTS" ]]; then
        echo "  → Using entitlements: $ENTITLEMENTS"
        CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
    else
        # This is now a hard stop rather than a warning. Under the hardened
        # runtime a build with no entitlements notarizes fine and then cannot
        # hear the user — a failure that reads as a dictation bug and costs a
        # whole notarization round trip to diagnose.
        fail "No entitlements file at $ENTITLEMENTS.

The hardened runtime (required for notarization) denies microphone access and
Apple Events unless they are requested there. Shipping without it produces an
app that installs cleanly and then cannot hear anything.

This file is checked into the repo — if it is missing, restore it:
    git checkout -- $ENTITLEMENTS"
    fi

    codesign "${CODESIGN_ARGS[@]}" "$APP"
    echo "  ✓ Signed with '$DEV_ID_IDENTITY' (hardened runtime, timestamped)"

    # Prove the entitlements actually made it into the signature. A typo in the
    # plist silently yields a signed app with no exceptions at all.
    echo "  → entitlements now on the binary:"
    codesign -d --entitlements - --xml "$APP" 2>/dev/null \
        | plutil -convert xml1 -o - - 2>/dev/null \
        | grep -E "com\.apple\.security" | sed 's/^/      /' \
        || echo "      (none readable — investigate before shipping)"
    echo "  → codesign -dv --verbose=4:"
    codesign -dv --verbose=4 "$APP" 2>&1 | sed 's/^/      /'
    SIGNED_FOR_DISTRIBUTION=1
else
    cat <<EOF

  ┌──────────────────────────────────────────────────────────────────────┐
  │  NO DEVELOPER ID CERTIFICATE — THIS WILL BE A LOCAL-ONLY BUILD       │
  ├──────────────────────────────────────────────────────────────────────┤
  │  No "$DEV_ID_PATTERN" signing identity was found in       │
  │  the keychain. The app is still signed with the local self-signed    │
  │  "Skylark Dev Signing" identity (or ad-hoc) from bundle.sh, which    │
  │  is fine for running it on THIS Mac — but Gatekeeper will refuse     │
  │  to open it on anyone else's Mac ("Apple cannot check it for         │
  │  malicious software"), and it cannot be notarized.                   │
  │                                                                        │
  │  To produce a real distributable build, you need:                    │
  │    1. A paid Apple Developer Program membership (\$99/year).          │
  │    2. A "Developer ID Application" certificate, issued from that     │
  │       membership via developer.apple.com or Xcode → Settings →       │
  │       Accounts → Manage Certificates.                                │
  │  Once that certificate is in this Mac's keychain, re-run this        │
  │  script — no other changes needed.                                   │
  └──────────────────────────────────────────────────────────────────────┘

EOF
fi

# --- Package into a DMG ------------------------------------------------------
echo ""
echo "→ Packaging DMG…"

mkdir -p "$DIST"
DMG_PATH="$DIST/$APP_NAME-$VERSION.dmg"
VOLUME_NAME="$APP_NAME $VERSION"
DMG_STAGING="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGING"' EXIT

cp -R "$APP" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

# Safe to re-run: remove any DMG left over from a previous attempt at this
# exact version before hdiutil tries to create it again.
rm -f "$DMG_PATH"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

[[ -f "$DMG_PATH" ]] || fail "hdiutil reported success but $DMG_PATH is missing."
echo "  ✓ Created $DMG_PATH"

# --- Notarize + staple, if possible -----------------------------------------
echo ""
echo "→ Notarization…"

NOTARIZED=0

if [[ "$SIGNED_FOR_DISTRIBUTION" -ne 1 ]]; then
    echo "  ⚠️  Skipping — the app isn't signed with a Developer ID certificate."
    echo "  ⚠️  Apple's notary service only accepts Developer ID-signed binaries."
elif [[ -z "${NOTARY_KEYCHAIN_PROFILE:-}" && ( -z "${AC_API_KEY_ID:-}" || -z "${AC_API_ISSUER_ID:-}" || -z "${AC_API_KEY_PATH:-}" ) ]]; then
    cat <<EOF
  ⚠️  Skipping — no notarization credentials configured.

  Set up ONE of these before re-running:

  Option A (preferred) — a stored notarytool keychain profile:
      xcrun notarytool store-credentials "skylark-notary" \\
          --apple-id "<your Apple ID email>" \\
          --team-id "<your Team ID>" \\
          --password "<an app-specific password from appleid.apple.com>"
      export NOTARY_KEYCHAIN_PROFILE="skylark-notary"

  Option B — App Store Connect API key:
      export AC_API_KEY_ID="<key ID>"
      export AC_API_ISSUER_ID="<issuer ID>"
      export AC_API_KEY_PATH="<path to the .p8 private key file>"

  Both require the paid Apple Developer Program membership mentioned above.
EOF
else
    echo "  → Submitting $DMG_PATH to Apple's notary service (this can take a few minutes)…"

    NOTARIZE_ARGS=(notarytool submit "$DMG_PATH" --wait)
    if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
        NOTARIZE_ARGS+=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
        echo "  → Using keychain profile: $NOTARY_KEYCHAIN_PROFILE"
    else
        NOTARIZE_ARGS+=(--key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")
        echo "  → Using App Store Connect API key: $AC_API_KEY_ID"
    fi

    if xcrun "${NOTARIZE_ARGS[@]}"; then
        echo "  ✓ Notarization accepted"
        echo "  → Stapling ticket to ${DMG_PATH}…"
        if xcrun stapler staple "$DMG_PATH"; then
            echo "  ✓ Stapled"
            echo "  → Verifying with spctl…"
            if SPCTL_OUT="$(spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1)"; then
                echo "$SPCTL_OUT" | sed 's/^/      /'
                echo "  ✓ Gatekeeper accepts this artifact"
                NOTARIZED=1
            else
                echo "$SPCTL_OUT" | sed 's/^/      /'
                echo "  ✗ spctl did NOT accept this artifact — see output above."
            fi
        else
            echo "  ✗ Stapling failed — see output above. The DMG is notarized but unstapled;"
            echo "     it will still pass Gatekeeper as long as the Mac opening it can reach"
            echo "     Apple's notarization servers to check online."
        fi
    else
        fail "Notarization submission failed. Run with the credentials above and check
'xcrun notarytool log <submission-id>' for Apple's rejection reason (a
common one is a missing entitlement or an unsigned nested binary)."
    fi
fi

# --- Checksum + summary ------------------------------------------------------
echo ""
echo "→ Writing checksum…"
SHA256_PATH="$DMG_PATH.sha256"
( cd "$DIST" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$SHA256_PATH")" )
echo "  ✓ $SHA256_PATH"

DMG_SIZE_BYTES="$(stat -f%z "$DMG_PATH")"
DMG_SIZE_HUMAN="$(du -h "$DMG_PATH" | cut -f1 | sed 's/[[:space:]]*$//')"

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "  Release summary"
echo "════════════════════════════════════════════════════════════════════════"
echo "  Artifact:    $DMG_PATH"
echo "  Checksum:    $SHA256_PATH"
echo "  Size:        $DMG_SIZE_HUMAN ($DMG_SIZE_BYTES bytes)"
echo "  Version:     $VERSION (build $BUILD_NUMBER)"
echo "  Git commit:  $GIT_SHA"
if [[ "$SIGNED_FOR_DISTRIBUTION" -eq 1 ]]; then
    echo "  Signed:      yes — Developer ID ($DEV_ID_IDENTITY)"
else
    echo "  Signed:      no — local dev/ad-hoc signature only"
fi
if [[ "$NOTARIZED" -eq 1 ]]; then
    echo "  Notarized:   yes — stapled and spctl-verified"
else
    echo "  Notarized:   no"
fi
echo ""
if [[ "$SIGNED_FOR_DISTRIBUTION" -eq 1 && "$NOTARIZED" -eq 1 ]]; then
    echo "  → Can this open on someone else's Mac?  YES. Signed, notarized, and"
    echo "    stapled — Gatekeeper will accept it with no warnings, offline included."
elif [[ "$SIGNED_FOR_DISTRIBUTION" -eq 1 ]]; then
    echo "  → Can this open on someone else's Mac?  PROBABLY, WITH A WARNING."
    echo "    Signed with a Developer ID but not notarized — Gatekeeper will show a"
    echo "    warning dialog ('cannot verify...') unless the other Mac can reach"
    echo "    Apple to check notarization status online."
else
    echo "  → Can this open on someone else's Mac?  NO. This is a local-only build,"
    echo "    signed with Skylark's self-signed dev identity (or ad-hoc). Gatekeeper"
    echo "    will refuse it on any other Mac with 'Apple cannot check it for"
    echo "    malicious software.' See the box above for what's needed to fix this."
fi
echo "════════════════════════════════════════════════════════════════════════"
