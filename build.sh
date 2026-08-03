#!/bin/bash
# Builds MacHancer.app from the Swift package.
#   ./build.sh                    release build -> ./MacHancer.app
#   ./build.sh debug              debug build
#   ./build.sh --create-identity  create the stable signing certificate, once
set -euo pipefail

cd "$(dirname "$0")"

APP="MacHancer.app"
IDENTITY_NAME="${MACHANCER_IDENTITY:-MacHancer Dev}"
# The certificate predates the rename; keep using it rather than forcing a new
# one, since a changed signing identity means re-granting Accessibility again.
LEGACY_IDENTITY="Mouse Enhancer Dev"

# Creates a self-signed code-signing certificate in the login keychain.
#
# This is the permanent fix for the Accessibility grant evaporating on every rebuild.
# An ad-hoc signature has no certificate, so TCC has nothing stable to key the grant
# to and falls back to the cdhash — which changes with every compile. A certificate,
# even a self-signed one, gives the grant a designated requirement that survives.
create_identity() {
  if security find-identity -v -p codesigning | grep -qF "$IDENTITY_NAME"; then
    echo "==> Identity '$IDENTITY_NAME' already exists — nothing to do."
    return 0
  fi

  local dir keychain p12pass
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  keychain="$HOME/Library/Keychains/login.keychain-db"

  # The PKCS#12 container needs a real password. macOS's importer rejects an
  # empty-password bundle outright — "MAC verification failed during PKCS12 import" —
  # whatever LibreSSL thinks of it. This password exists only for the moment between
  # export and import, and dies with the temp directory.
  p12pass="$(openssl rand -hex 16)"

  echo "==> Creating self-signed code-signing certificate '$IDENTITY_NAME'…"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" \
    -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

  openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -out "$dir/identity.p12" -passout "pass:$p12pass"

  # -T authorises codesign to use the key. macOS still asks once, on first use, unless
  # the key's partition list is updated — which needs the login keychain password.
  # Choosing "Always Allow" on that single dialog is equivalent.
  security import "$dir/identity.p12" -k "$keychain" -P "$p12pass" -T /usr/bin/codesign

  # Trust is not optional. An imported but untrusted certificate is reported by
  # find-identity as CSSMERR_TP_NOT_TRUSTED, and codesign refuses it outright with
  # "no identity found" — it will not sign with a certificate it cannot build a chain
  # to. The trust is scoped to the code-signing policy rather than granted wholesale,
  # so this root can vouch for nothing else.
  echo
  echo "==> Trusting it for code signing…"
  echo "    macOS will ask for your login password — that prompt is this step."
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$dir/cert.pem"

  if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY_NAME"; then
    echo
    echo "    WARNING: '$IDENTITY_NAME' still is not listed as a valid signing identity."
    echo "    Builds will fall back to ad-hoc signing. Check Keychain Access -> login,"
    echo "    and set this certificate's Code Signing trust to \"Always Trust\"."
    return 1
  fi

  echo
  echo "    Done. Rebuild — the first build shows one keychain prompt for this key;"
  echo "    choose \"Always Allow\"."
  echo
  echo "        ./build.sh"
  echo
  echo "    Then use Repair Permission… in Settings -> General once more. After that"
  echo "    the Accessibility grant survives every rebuild."
}

if [ "${1:-}" = "--create-identity" ]; then
  create_identity
  exit 0
fi

CONFIG="${1:-release}"

# Build outside the source tree. This project lives in iCloud Drive, and letting
# SwiftPM keep its ~300 MB of intermediates in ./.build there makes every compile
# fight the sync daemon for each object file — measured at over ten minutes for a
# full rebuild, versus about 50 seconds to local disk. Override with SCRATCH_PATH.
SCRATCH="${SCRATCH_PATH:-${TMPDIR:-/tmp}/MacHancer-build}"

echo "==> Compiling ($CONFIG) in $SCRATCH…"
swift build -c "$CONFIG" --disable-sandbox --scratch-path "$SCRATCH"

BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)/MacHancer"

# Assemble and sign on local disk, never in place.
#
# This project lives in iCloud Drive, whose file provider stamps com.apple.FinderInfo
# and com.apple.fileprovider.* onto the bundle continuously. codesign rejects those
# outright — "resource fork, Finder information, or similar detritus not allowed" — and
# stripping them first does not help: the daemon re-applies them in the window between
# the strip and the signature, so the build fails intermittently and leaves a
# half-signed bundle behind. Staging outside iCloud removes the race rather than
# trying to win it.
STAGE="$SCRATCH/stage/$APP"

echo "==> Assembling $APP…"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/MacHancer"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"

# Stamp the build number from the git commit count, so the version shown in the About
# section identifies the exact source it was built from. Falls back to a timestamp
# outside a repository.
if BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null)" && [ -n "$BUILD_NUMBER" ]; then
  COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  BUILD_NUMBER="$BUILD_NUMBER-$COMMIT"
else
  BUILD_NUMBER="$(date +%Y%m%d%H%M)"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
  "$STAGE/Contents/Info.plist" 2>/dev/null || true
# App icon, referenced by CFBundleIconFile.
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
xattr -cr "$STAGE"

# Signature. TCC keys an Accessibility grant to a code requirement. For an ad-hoc
# signature that requirement is the cdhash, which moves on essentially every rebuild —
# so the grant silently stops applying while the checkbox in System Settings stays
# ticked. tccd logs it as "Failed to match existing code requirement" and the app just
# looks broken: it appears authorised and every binding is inert.
#
# A certificate — even a self-signed one — gives the grant something stable to match,
# so it survives rebuilds. Use the identity automatically if it exists; create it with
# ./build.sh --create-identity.
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
  IDENTITY="$IDENTITY_NAME"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$LEGACY_IDENTITY"; then
  IDENTITY="$LEGACY_IDENTITY"
  echo "==> Signing as '$IDENTITY'…"
else
  IDENTITY="-"
  echo "==> Signing (ad-hoc — Accessibility must be re-granted after each rebuild)…"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$STAGE"

# Verify while still on local disk, where the result is meaningful. Once the bundle is
# back in iCloud the file provider will re-stamp the root and --strict will object to
# that alone, which says nothing about whether the signature is sound.
codesign --verify --deep --strict "$STAGE"

# Install. --noextattr keeps iCloud's markers off the copy for as long as possible;
# the daemon re-adds them to the bundle root in its own time, which does not affect the
# sealed contents or the designated requirement.
echo "==> Installing to $(pwd)/$APP…"
rm -rf "$APP"
ditto --noextattr --norsrc "$STAGE" "$APP"

# CDHash is only reported at verbose=4, and codesign writes it to stderr.
NEW_HASH="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F'=' '/^CDHash=/{print $2}')"

echo "==> Done: $(pwd)/$APP"
echo "    cdhash: ${NEW_HASH:-unknown}"
echo
if [ "$IDENTITY" = "-" ]; then
  cat <<'NOTE'
    IMPORTANT — this build is ad-hoc signed, so macOS treats it as a new binary and the
    existing Accessibility grant will NOT apply to it. Bindings will do nothing until it
    is re-granted, and the checkbox in System Settings will keep claiming otherwise.

    Fix this build:      open MacHancer.app, then Settings -> General ->
                         "Repair Permission…"

    Fix it permanently:  ./build.sh --create-identity && ./build.sh

    Check Settings -> Diagnostics afterwards: "Event tap installed" must read
    "attached and enabled", otherwise nothing will fire.
NOTE
else
  echo "    Run with: open $APP"
fi
