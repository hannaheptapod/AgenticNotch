#!/usr/bin/env bash
#
# Build AgenticNotch and swap it into /Applications, keeping the TCC grants.
#
# The project signs ad-hoc ("-") by default, which makes the designated
# requirement a bare cdhash. That hash changes on every build, so macOS treats
# each rebuild as a brand new app and every privacy permission has to be granted
# again. Signing with a real certificate instead pins the requirement to
# identifier + leaf certificate, which survives rebuilds.
#
# Override the identity with CODESIGN_IDENTITY / DEVELOPMENT_TEAM if the
# auto-detected one isn't the one you want.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AgenticNotch"
CONFIG="${CONFIG:-Release}"
DERIVED="${DERIVED:-build}"
BUILT_APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
INSTALLED="/Applications/$APP_NAME.app"

# Prefer Apple Development; fall back to Apple Distribution. Either is fine —
# what matters is that it's the same certificate every time.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY=$(security find-identity -v -p codesigning \
    | grep -m1 -E '"Apple Development:' \
    | sed -E 's/.*"(.*)"/\1/') || true
fi

if [[ -z "$CODESIGN_IDENTITY" ]]; then
  echo "No code signing identity found. Falling back to ad-hoc signing —" >&2
  echo "permissions WILL reset on every install." >&2
  SIGN_ARGS=()
else
  if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    # The team ID is the OU field of the certificate subject.
    DEVELOPMENT_TEAM=$(security find-certificate -c "$CODESIGN_IDENTITY" -p \
      | openssl x509 -noout -subject \
      | sed -E 's/.*OU *= *([A-Z0-9]+).*/\1/')
  fi
  echo "Signing as: $CODESIGN_IDENTITY (team $DEVELOPMENT_TEAM)"
  SIGN_ARGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY"
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    PROVISIONING_PROFILE_SPECIFIER=""
  )
fi

echo "Building ($CONFIG)…"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch \
  -configuration "$CONFIG" -derivedDataPath "$DERIVED" \
  "${SIGN_ARGS[@]}" build

[[ -d "$BUILT_APP" ]] || { echo "Build produced no app at $BUILT_APP" >&2; exit 1; }

echo "Requirement: $(codesign -d -r - "$BUILT_APP" 2>&1 | sed -n 's/^designated => //p')"

if pgrep -f "$INSTALLED/Contents/MacOS/$APP_NAME" >/dev/null; then
  echo "Quitting the running $APP_NAME…"
  osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -f "$INSTALLED/Contents/MacOS/$APP_NAME" >/dev/null || break
    sleep 0.25
  done
  pkill -f "$INSTALLED/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

echo "Installing to $INSTALLED…"
rm -rf "$INSTALLED"
ditto "$BUILT_APP" "$INSTALLED"

open "$INSTALLED"
echo "Done."
