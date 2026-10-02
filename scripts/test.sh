#!/bin/bash
# Verification harness for KeeBridge. Prints one PASS/FAIL/SKIP line per check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODE_DIR="$ROOT/xcode/KeeBridge"
EXT_RES="$XCODE_DIR/KeeBridge Extension/Resources"
DERIVED="/tmp/keebridge-test-dd"
APP="$DERIVED/Build/Products/Debug/KeeBridge.app"
APP_BIN="$APP/Contents/MacOS/KeeBridge"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PORT=17634
LOCK="$DERIVED.lock"
LOG_DIR="$(mktemp -d /tmp/keebridge-test.XXXXXX)"

failures=0
skips=0
app_pid=""

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
skip() { echo "SKIP  $1"; skips=$((skips + 1)); }
port_open() { nc -z -G 1 127.0.0.1 "$PORT" 2>/dev/null; }

# Keep the logs only when something failed, since the FAIL lines point at them.
cleanup() {
    local status=$?
    stop_app
    # xcodebuild registers the Debug app, which would add a duplicate extension to Safari.
    "$LSREGISTER" -u "$APP" 2>/dev/null || true
    rm -rf "$LOCK"
    if ((status == 0)); then rm -rf "$LOG_DIR"; fi
}

stop_app() {
    if [[ -n $app_pid ]]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
        app_pid=""
    fi
}

# Concurrent runs share $DERIVED and port 17634, so take turns.
acquire_lock() {
    local i pid
    for i in {1..300}; do
        if mkdir "$LOCK" 2>/dev/null; then
            echo $$ >"$LOCK/pid"
            trap cleanup EXIT
            return
        fi
        pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
        if [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$LOCK"; fi
        sleep 1
    done
    echo "FAIL  another test.sh run held $LOCK for 5 minutes"
    exit 1
}

# a) Incremental Debug build, no signing. Swift warnings are errors, so a warning fails the build.
check_build() {
    local log="$LOG_DIR/build.log"
    if xcodebuild -project "$XCODE_DIR/KeeBridge.xcodeproj" -scheme KeeBridge \
        -configuration Debug -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build >"$log" 2>&1; then
        pass "xcodebuild Debug, Swift warnings as errors"
    else
        grep -E 'error:|BUILD FAILED' "$log" | sort -u | head -30 || true
        fail "xcodebuild Debug (log: $log)"
    fi
}

# b) Syntax check every non-minified .js file in one node process. Files are parsed as
# classic scripts, which is how the extension loads them, so a stray import/export fails here.
check_js() {
    local summary
    if summary="$(node - "$EXT_RES" <<'JS'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = process.argv[2];
const files = fs.readdirSync(root, { recursive: true })
    .filter((f) => f.endsWith('.js') && !f.endsWith('.min.js'))
    .map((f) => path.join(root, f))
    .sort();
let bad = 0;
for (const filename of files) {
    try {
        new vm.Script(fs.readFileSync(filename, 'utf8'), { filename });
    } catch (err) {
        bad++;
        console.error(err.stack.split('\n    at ')[0]);
    }
}
console.log(`${bad} ${files.length}`);
process.exit(bad > 0 ? 1 : 0);
JS
    )"; then
        pass "JS syntax check on ${summary#* } .js files"
    else
        fail "JS syntax check: ${summary%% *} of ${summary#* } files have syntax errors"
    fi
}

# c) JSON validity: manifest.json is required, every other .json present must parse.
check_json() {
    local files=() file
    while IFS= read -r -d '' file; do files+=("$file"); done \
        < <(find "$EXT_RES" -name '*.json' ! -name manifest.json -print0)
    # Bash 3.2 with set -u treats an empty "${files[@]}" as unbound, hence the + guard.
    if jq empty "$EXT_RES/manifest.json" ${files[@]+"${files[@]}"}; then
        pass "jq: manifest.json and ${#files[@]} other .json files parse"
    else
        fail "jq: invalid or missing JSON"
    fi
}

# d) Every file the manifest or an HTML page references exists.
check_references() {
    if python3 - "$EXT_RES" <<'PY'
import json, os, re, sys
from html.parser import HTMLParser

root = sys.argv[1]
missing = []

def need(path, source, base=root):
    path = path.split("#")[0].split("?")[0]
    if not path or re.match(r"^[a-z-]+:|^//", path) or "*" in path:
        return
    full = os.path.join(root, path.lstrip("/")) if path.startswith("/") else os.path.join(base, path)
    if not os.path.isfile(os.path.normpath(full)):
        missing.append(f"{source}: {path}")

def need_all(value, source):
    # Accepts a path, a list of paths, or an icon size -> path dict.
    if isinstance(value, dict):
        value = list(value.values())
    for p in [value] if isinstance(value, str) else value or []:
        need(p, source)

text = open(os.path.join(root, "manifest.json")).read()
m = json.loads(text)
bg = m.get("background", {})
need_all(m.get("icons"), "icons")
need_all([bg[k] for k in ("page", "service_worker") if k in bg] + bg.get("scripts", []), "background")
for cs in m.get("content_scripts", []):
    need_all(cs.get("js", []) + cs.get("css", []), "content_scripts")
for entry in m.get("web_accessible_resources", []):
    need_all(entry if isinstance(entry, str) else entry.get("resources", []), "web_accessible_resources")
options = m.get("options_ui", {}).get("page") or m.get("options_page")
need_all(options, "options")
for key in ("browser_action", "action", "page_action"):
    need_all(m.get(key, {}).get("default_popup"), f"{key}.default_popup")
    need_all(m.get(key, {}).get("default_icon"), f"{key}.default_icon")
if "default_locale" in m:
    need(f"_locales/{m['default_locale']}/messages.json", "default_locale")

en = os.path.join(root, "_locales/en/messages.json")
keys = {k.lower() for k in json.load(open(en))} if os.path.isfile(en) else set()
for key in sorted(set(re.findall(r"__MSG_(\w+)__", text))):
    if key.lower() not in keys:
        missing.append(f"__MSG_{key}__: not in _locales/en/messages.json")

class Refs(HTMLParser):
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        ref = a.get("src") if tag == "script" else a.get("href") if tag == "link" else None
        if ref:
            need(ref, os.path.relpath(self.path, root), base=os.path.dirname(self.path))

pages = 0
for dirpath, _, files in os.walk(root):
    for name in files:
        if name.endswith(".html"):
            pages += 1
            parser = Refs()
            parser.path = os.path.join(dirpath, name)
            parser.feed(open(parser.path, encoding="utf-8").read())

for line in missing:
    print(f"  missing  {line}")
print(f"  checked manifest and {pages} html files")
sys.exit(1 if missing else 0)
PY
    then pass "manifest and HTML references resolve"
    else fail "manifest or HTML references point at missing files"; fi
}

# e) Launch the Debug app and poke the TCP bridge. Only test-built instances are killed.
# Safari wraps replies from the app as { name, userInfo } and sends an empty message
# per request. native-shim.js must hand client.js the bare reply and drop the rest.
check_native_shim() {
    if node - "$EXT_RES/background/native-shim.js" <<'JS'
const fs = require('fs');
const vm = require('vm');
const seen = [];
const context = { keepassClient: { onNativeMessage: (m) => seen.push(m) } };
vm.createContext(context);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), context);
const reply = { action: 'change-public-keys', nonce: 'n', success: 'true' };
const error = { action: 'get-logins', error: 'KeeBridge is not running', errorCode: 5 };
for (const m of [{ name: 'keepassxc', userInfo: reply }, undefined, null, error]) {
    context.keepassClient.onNativeMessage(m);
}
const ok = seen.length === 2 && seen[0] === reply && seen[1] === error;
if (!ok) console.error(`  got ${JSON.stringify(seen)}`);
process.exit(ok ? 0 : 1);
JS
    then
        pass "native-shim.js unwraps Safari replies"
    else
        fail "native-shim.js does not unwrap Safari replies"
    fi
}

check_bridge() {
    local i
    if [[ ! -x $APP_BIN ]]; then
        fail "bridge smoke test: no Debug build at $APP_BIN"
        return
    fi
    pkill -f "$APP/Contents/MacOS" || true
    for i in {1..15}; do port_open || break; sleep 0.2; done
    if port_open; then
        skip "bridge smoke test: port $PORT in use (is the KeeBridge relay running?)"
        return
    fi

    "$APP_BIN" >"$LOG_DIR/app.log" 2>&1 &
    app_pid=$!
    for i in {1..50}; do port_open && break; sleep 0.2; done
    if ! port_open; then
        fail "bridge smoke test: app did not listen on 127.0.0.1:$PORT within 10s (log: $LOG_DIR/app.log)"
        return
    fi

    # One valid frame (UInt32 little-endian length + JSON), then a header over the 1 MiB limit.
    if ! python3 - "$PORT" <<'PY'
import json, socket, struct, sys
port = int(sys.argv[1])
body = json.dumps({"action": "get-databasehash"}).encode()
with socket.create_connection(("127.0.0.1", port), timeout=3) as s:
    s.sendall(struct.pack("<I", len(body)) + body)
with socket.create_connection(("127.0.0.1", port), timeout=3) as s:
    s.sendall(struct.pack("<I", 2 * 1024 * 1024))
PY
    then
        fail "bridge smoke test: could not send to the bridge"
        return
    fi
    sleep 0.5
    if ! kill -0 "$app_pid" 2>/dev/null || ! port_open; then
        fail "bridge smoke test: app died (log: $LOG_DIR/app.log)"
    elif ! /usr/bin/log show --last 1m --info --style compact --predicate \
        "processIdentifier == $app_pid AND subsystem == \"com.jikaido.keebridge\"" \
        | grep -q 'request action=get-databasehash'; then
        fail "bridge smoke test: app alive but did not log 'request action=get-databasehash'"
    else
        pass "bridge smoke test: frame logged, app alive after oversized header"
    fi
    stop_app
}

acquire_lock
check_build
check_js
check_json
check_references
check_native_shim
check_bridge

echo "$failures failed, $skips skipped"
((failures == 0))
