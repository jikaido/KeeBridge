#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
DERIVED="$PROJECT_DIR/build/DerivedData"
APP_NAME="KeeBridge.app"
APP_DIR="$PROJECT_DIR/$APP_NAME"
# Sign with the local Apple Development identity when present, ad hoc otherwise.
# xcodebuild does the signing so the generated sandbox entitlements reach the extension.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ { print $2; exit }')
LOG="$PROJECT_DIR/build/xcodebuild.log"
mkdir -p build
if ! xcodebuild -project "xcode/KeeBridge/KeeBridge.xcodeproj" \
    -scheme KeeBridge -configuration Release -derivedDataPath "$DERIVED" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${IDENTITY:--}" PROVISIONING_PROFILE_SPECIFIER= \
    build >"$LOG" 2>&1; then
    grep -E 'error:' "$LOG" | sort -u || true
    print -u2 "Build failed, see $LOG"
    exit 1
fi
BUILT="$DERIVED/Build/Products/Release/$APP_NAME"
pkill -f "$APP_DIR/Contents/MacOS" || true
rm -rf "$APP_DIR"
ditto "$BUILT" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
# Safari lists one extension per registered copy, so register only the root copy.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$APP_DIR"
print "Built $APP_DIR"
