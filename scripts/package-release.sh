#!/bin/zsh
# Packages dist/KeeBridge-<version>.zip from committed source and checks it for personal data.
#
# The release is signed ad hoc, so nothing in it names the person who built it. Developer ID
# signing and notarization (codesign with a Developer ID Application identity and
# --timestamp, then notarytool submit and stapler staple) would replace the ad hoc step later.
#
# Personal strings are never written into this script. They are derived at run time from this
# Mac (user name, full name, home folder, host names and every code signing certificate in the
# keychain). Add more with KEEBRIDGE_PRIVATE_PATTERNS="one two".
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
PBXPROJ="xcode/KeeBridge/KeeBridge.xcodeproj/project.pbxproj"

if [[ -n "$(git status --porcelain)" ]]; then
    git status --short >&2
    print -u2 "Working tree is dirty. Commit first so the release matches committed source."
    exit 1
fi
VERSIONS=(${(u)${(f)"$(sed -nE 's/.*MARKETING_VERSION = "?([^";]+)"?;.*/\1/p' "$PBXPROJ")"}})
if (( ${#VERSIONS} != 1 )); then
    print -u2 "Expected one MARKETING_VERSION in $PBXPROJ, found: ${VERSIONS:-none}"
    exit 1
fi
VERSION=$VERSIONS[1]
ZIP="$PROJECT_DIR/dist/KeeBridge-$VERSION.zip"

# Build from a neutral path. Compilers embed source and DerivedData paths in binaries, so
# building inside the repo would put the builder's home folder into the release.
WORK=/tmp/keebridge-release
SRC="$WORK/src"
DERIVED="$WORK/DerivedData"
STAGE="$WORK/stage"
CHECK="$WORK/check"
LOG="$PROJECT_DIR/build/package-release.log"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# xcodebuild registers the built app with Launch Services, and Safari lists one extension per
# registered copy, so unregister every temporary copy before deleting it.
cleanup() {
    local app
    for app in "$DERIVED/Build/Products/Release/KeeBridge.app" "$STAGE/KeeBridge.app" "$CHECK/KeeBridge.app"; do
        if [[ -d "$app" ]]; then "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true; fi
    done
    rm -rf "$WORK"
}
cleanup
trap cleanup EXIT
mkdir -p "$SRC" "$STAGE" "$CHECK" "$PROJECT_DIR/build" "$PROJECT_DIR/dist"
git archive HEAD | tar -x -C "$SRC"
print "Packaging KeeBridge $VERSION from $(git rev-parse --short HEAD)"

# Ad hoc signing with no team. CODE_SIGN_INJECT_BASE_ENTITLEMENTS must stay YES: Xcode adds the
# extension's app-sandbox and network.client entitlements (ENABLE_APP_SANDBOX and
# ENABLE_OUTGOING_NETWORK_CONNECTIONS) only through the injected base entitlements.
build() {
    ( cd "$SRC" && xcodebuild -project "$PBXPROJ:h" \
        -scheme KeeBridge -configuration Release -derivedDataPath "$DERIVED" \
        ARCHS="$1" ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES \
        clean build ) >"$LOG" 2>&1
}
ARCHS_BUILT="arm64 x86_64"
if ! build "$ARCHS_BUILT"; then
    grep -E 'error:' "$LOG" | sort -u || true
    print "WARNING: the universal build failed, falling back to arm64 only"
    ARCHS_BUILT="arm64"
    if ! build "$ARCHS_BUILT"; then
        grep -E 'error:' "$LOG" | sort -u || true
        print -u2 "Build failed, see $LOG"
        exit 1
    fi
fi

APP="$STAGE/KeeBridge.app"
APPEX="$APP/Contents/PlugIns/KeeBridge Extension.appex"
ditto --norsrc --noextattr --noqtn --noacl "$DERIVED/Build/Products/Release/KeeBridge.app" "$APP"

# The injected base entitlements also add get-task-allow, which a release must not carry.
# Re-sign inside out with the same entitlements minus get-task-allow, keeping the hardened runtime.
resign() {
    local plist="$WORK/${1:t:r}.entitlements"
    codesign -d --entitlements - --xml "$1" >"$plist" 2>/dev/null
    [[ -s "$plist" ]] || print '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' >"$plist"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$plist" >/dev/null 2>&1 || true
    codesign --force --sign - --options runtime --timestamp=none --entitlements "$plist" "$1"
}
resign "$APPEX"
resign "$APP"
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$ZIP"
# The zip root holds the app, the license and a pointer to the corresponding source (GPL).
cp "$SRC/COPYING" "$STAGE/COPYING"
print -r -- "KeeBridge $VERSION, Safari bridge for KeePassXC. Unofficial, not affiliated with KeePassXC.
Source, install steps and license: https://github.com/jikaido/KeeBridge
Built from commit $(git -C "$PROJECT_DIR" rev-parse --short HEAD). Licensed under the GNU GPL version 3, see COPYING." > "$STAGE/README.txt"
ditto -c -k --norsrc --noextattr --noqtn --noacl "$STAGE" "$ZIP"

# Privacy checks run on what was actually zipped. ditto restores xattrs and quarantine flags if
# the zip carried any, so the extracted copy shows them.
ditto -x -k "$ZIP" "$CHECK"
SHIPPED="$CHECK/KeeBridge.app"
SHIPPED_APPEX="$SHIPPED/Contents/PlugIns/KeeBridge Extension.appex"
FAILURES=0
pass() { print "PASS $1" }
fail() { print "FAIL $1"; FAILURES=$((FAILURES + 1)) }
indent() { sed 's/^/    /' }

# Tokens that identify this Mac or its owner. Certificate fields fail anywhere. Name and host
# tokens are whole words that can be ordinary words too (in a translation, say), so a hit in a file
# that is a byte for byte copy of committed source is reported but allowed.
typeset -aU STRICT WORDS
STRICT=("/Users/" "$HOME" "Apple Development" ${=KEEBRIDGE_PRIVATE_PATTERNS:-})
WORDS=("$USER" "$(id -F 2>/dev/null || true)" "$(scutil --get ComputerName 2>/dev/null || true)" \
    "$(scutil --get LocalHostName 2>/dev/null || true)")
# Only certificates with a private key (code signing identities) belong to the person building.
IDENTITY_HASHES=(${(u)${(f)"$(security find-identity -p codesigning 2>/dev/null | awk '$2 ~ /^[0-9A-F]{40}$/ { print $2 }')"}})
security find-certificate -a -Z -p 2>/dev/null \
    | awk -v dir="$WORK" '/^SHA-1 hash:/ { n++; hash = $3; next } n { print > (dir "/cert-" hash ".pem") }'
for hash in $IDENTITY_HASHES; do
    pem="$WORK/cert-$hash.pem"
    [[ -f "$pem" ]] || continue
    subject=$(openssl x509 -noout -subject -in "$pem" 2>/dev/null || true)
    for key in OU UID O; do
        value=$(print -r -- "$subject" | sed -nE "s/.*(=|, )$key=([^,]+).*/\\2/p")
        if [[ -n "$value" ]]; then STRICT+=("$value"); fi
    done
    cn=$(print -r -- "$subject" | sed -nE 's/.*CN=([^,]+).*/\1/p')
    if [[ "$cn" =~ '\(([A-Z0-9]+)\)' ]]; then STRICT+=("$match[1]"); fi
    if [[ "$cn" =~ '([^ :]+)@([^ ]+)\.[A-Za-z]+' ]]; then STRICT+=("$match[1]@$match[2]" "$match[2]"); fi
done
rm -f "$WORK"/cert-*.pem(N)
WORDS=(${WORDS:#})
STRICT=(${STRICT:#})
EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
print "Checking for ${#STRICT} certificate, path and identity tokens and ${#WORDS} name and host words (values not printed)"

for target in "$SHIPPED" "$SHIPPED_APPEX"; do
    name="${target:t}"
    info=$(codesign -dvv "$target" 2>&1)
    print -r -- "$info" | grep -E '^(Identifier|Format|CodeDirectory|Signature|Authority|TeamIdentifier)' | indent
    if print -r -- "$info" | grep -qx 'Signature=adhoc' \
        && print -r -- "$info" | grep -qx 'TeamIdentifier=not set' \
        && ! print -r -- "$info" | grep -q '^Authority='; then
        pass "$name is ad hoc signed with no team and no certificate authority"
    else
        fail "$name is not ad hoc signed, or carries a team or certificate"
    fi
done

ENTITLEMENTS_APPEX="$WORK/shipped-extension.entitlements"
ENTITLEMENTS_APP="$WORK/shipped-app.entitlements"
codesign -d --entitlements - --xml "$SHIPPED_APPEX" >"$ENTITLEMENTS_APPEX" 2>/dev/null || true
codesign -d --entitlements - --xml "$SHIPPED" >"$ENTITLEMENTS_APP" 2>/dev/null || true
has_true() { [[ "$(/usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null)" == true ]] }
if has_true "$ENTITLEMENTS_APPEX" com.apple.security.app-sandbox \
    && has_true "$ENTITLEMENTS_APPEX" com.apple.security.network.client; then
    pass "extension has app-sandbox and network.client entitlements"
else
    fail "extension is missing app-sandbox or network.client, Safari will not load it"
fi
if has_true "$ENTITLEMENTS_APP" com.apple.security.app-sandbox; then
    fail "app is sandboxed, it cannot run keepassxc-proxy"
else
    pass "app is not sandboxed"
fi
if has_true "$ENTITLEMENTS_APPEX" com.apple.security.get-task-allow \
    || has_true "$ENTITLEMENTS_APP" com.apple.security.get-task-allow; then
    fail "get-task-allow is present"
else
    pass "no get-task-allow entitlement"
fi

# Signature details and entitlements must not name a person, a team or a certificate.
SIGNATURE_TEXT=$(for t in "$SHIPPED" "$SHIPPED_APPEX"; do
    codesign -dvvvv "$t" 2>&1 | grep -v -E '^(Executable|Identifier)='
    codesign -d --entitlements - --xml "$t" 2>/dev/null
    print
done)
sig_hits=$(print -r -- "$SIGNATURE_TEXT" | grep -c -i -F -f <(print -rl -- $STRICT) || true)
sig_words=$(print -r -- "$SIGNATURE_TEXT" | grep -c -i -w -F -f <(print -rl -- $WORDS) || true)
sig_mail=$(print -r -- "$SIGNATURE_TEXT" | grep -c -E "$EMAIL" || true)
if (( sig_hits + sig_words + sig_mail == 0 )); then
    pass "signatures and entitlements contain no Apple Development identity, email, team ID or personal name"
else
    fail "signatures or entitlements contain personal data ($sig_hits token, $sig_words word, $sig_mail email lines)"
fi

# Every file in the bundle, Mach-O files with strings across all architectures.
typeset -A SOURCE_HASHES
while read -r hash _; do SOURCE_HASHES[$hash]=1; done < <(find "$SRC" -type f -exec shasum -a 256 {} + )
scan_hits=0
allowed_hits=0
MACHO_COUNT=0
FILE_COUNT=0
while IFS= read -r -d '' file; do
    FILE_COUNT=$((FILE_COUNT + 1))
    rel="${file#$CHECK/}"
    if file -b "$file" | grep -q 'Mach-O'; then
        MACHO_COUNT=$((MACHO_COUNT + 1))
        text=$( { strings -a -arch all "$file"; strings -a "$file"; } 2>/dev/null)
    else
        text=$(strings -a "$file" 2>/dev/null)
    fi
    hits=$(print -r -- "$text" | grep -i -F -f <(print -rl -- $STRICT) | sort -u || true)
    soft=$( { print -r -- "$text" | grep -i -w -F -f <(print -rl -- $WORDS);
              print -r -- "$text" | grep -o -E "$EMAIL"; } | sort -u || true)
    if [[ -n "$hits" ]]; then
        print "    $rel"
        print -r -- "$hits" | cut -c1-160 | indent | indent
        scan_hits=$((scan_hits + 1))
    fi
    if [[ -n "$soft" ]]; then
        if [[ -n "${SOURCE_HASHES[$(shasum -a 256 "$file" | cut -d' ' -f1)]:-}" ]]; then
            print "    allowed, copied unchanged from committed source: $rel ($(print -r -- "$soft" | wc -l | tr -d ' ') lines)"
            allowed_hits=$((allowed_hits + 1))
        else
            print "    $rel"
            print -r -- "$soft" | cut -c1-160 | indent | indent
            scan_hits=$((scan_hits + 1))
        fi
    fi
done < <(find "$SHIPPED" -type f -print0)
if (( scan_hits == 0 )); then
    pass "strings in $FILE_COUNT files ($MACHO_COUNT Mach-O) contain no home path, user or host name, team ID, certificate data or email ($allowed_hits allowed source files)"
else
    fail "personal strings found in $scan_hits files (listed above)"
fi

LISTING=$(unzip -l "$ZIP")
ZIPINFO=$(zipinfo "$ZIP")
bad_names=$(print -r -- "$LISTING"$'\n'"$ZIPINFO" | grep -E '\.DS_Store|__MACOSX|(^|/| )\._' | sort -u || true)
if [[ -z "$bad_names" ]]; then
    pass "zip has no .DS_Store, __MACOSX or AppleDouble entries ($(print -r -- "$LISTING" | tail -1 | awk '{ print $2 }') entries)"
else
    fail "zip has Finder or AppleDouble entries"
    print -r -- "$bad_names" | indent
fi
# com.apple.provenance is added locally by macOS to every file a process writes, it is not in the zip.
xattrs=$(xattr -lr "$SHIPPED" 2>/dev/null | grep -v ': com\.apple\.provenance:' || true)
if [[ -z "$xattrs" ]]; then
    pass "no extended attributes or quarantine flags after extracting the zip (ignoring local com.apple.provenance)"
else
    fail "extended attributes found after extracting the zip"
    print -r -- "$xattrs" | head -20 | cut -c1-160 | indent
fi
build_products=$(print -r -- "$LISTING" | grep -E '\.dSYM/|\.swiftmodule/' || true)
if [[ -z "$build_products" ]]; then
    pass "zip has no dSYM or swiftmodule folders"
else
    fail "zip has dSYM or swiftmodule folders"
    print -r -- "$build_products" | indent
fi
if codesign --verify --deep --strict "$SHIPPED" 2>/dev/null; then
    pass "extracted app passes codesign --verify --deep --strict"
else
    fail "extracted app fails codesign --verify --deep --strict"
fi

print
print "Architectures (requested $ARCHS_BUILT):"
print "    KeeBridge: $(lipo -archs "$SHIPPED/Contents/MacOS/KeeBridge")"
print "    KeeBridge Extension: $(lipo -archs "$SHIPPED_APPEX/Contents/MacOS/KeeBridge Extension")"
print "Extension entitlements:"
plutil -p "$ENTITLEMENTS_APPEX" | indent

if (( FAILURES > 0 )); then
    rm -f "$ZIP"
    print -u2 "$FAILURES privacy checks failed, removed $ZIP"
    exit 1
fi
print
print "$ZIP"
print "Size: $(stat -f %z "$ZIP") bytes ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"
print "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
