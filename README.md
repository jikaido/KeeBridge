# KeeBridge

Safari bridge for KeePassXC.

KeeBridge is a Safari port of [KeePassXC-Browser](https://github.com/keepassxreboot/keepassxc-browser) 1.10.4. The app KeeBridge (`com.jikaido.keebridge`) contains the Safari Web Extension KeeBridge Extension (`com.jikaido.keebridge.Extension`) and relays its messages to KeePassXC.

**KeeBridge is unofficial. It is not affiliated with, or endorsed by, the KeePassXC project.** Report problems with KeeBridge here, not to KeePassXC. The extension code is KeePassXC-Browser by the KeePassXC Team, adapted for Safari.

## Requirements

Requires macOS 14 or later and KeePassXC installed at `/Applications/KeePassXC.app`, with Browser Integration enabled in KeePassXC. The relay runs `Contents/MacOS/keepassxc-proxy` from that bundle.

## Install from a release

1. Download `KeeBridge-<version>.zip` from the Releases page, unzip it and move `KeeBridge.app` to `/Applications`.
2. Open KeeBridge. Release builds are signed ad hoc and not notarized, so macOS blocks the first launch.
   - macOS 15 and later: close the warning (Done, not Move to Trash), open System Settings, then Privacy & Security, scroll to Security and click Open Anyway next to the KeeBridge message. Confirm with your password, then click Open Anyway in the dialog that follows. The button appears only for about an hour after the blocked launch. Control clicking the app and choosing Open no longer bypasses Gatekeeper on these versions.
   - macOS 14: Control click `KeeBridge.app` in Finder, choose Open, then Open again. The Open Anyway button in System Settings, Privacy & Security works too.
3. In Safari, open Settings, then Advanced, and turn on Show features for web developers. Then open the Developer tab and turn on Allow unsigned extensions. Safari turns this off every time it quits, so turn it on again after each Safari launch.
4. In Safari Settings, open Extensions, turn on KeeBridge and allow it on the sites you use.
5. In KeePassXC, open Settings, then Browser Integration, and turn on Enable browser integration. Then open the KeeBridge extension settings (Safari Settings, Extensions, KeeBridge, Settings), click Connect and approve the connection in KeePassXC by giving it a name.

## Build and run

Building needs full Xcode (not only the Command Line Tools). `scripts/test.sh` also needs Node.js 18.17 or later, `jq` and `python3`.

```sh
./scripts/test.sh
./scripts/build-app.sh
open KeeBridge.app
```

`build-app.sh` makes an arm64 Release build. xcodebuild signs it with the first Apple Development identity in the keychain, or ad hoc if there is none. The script quits the running copy, replaces `KeeBridge.app` in the project root and runs `codesign --verify`. Safari lists one extension per copy registered with Launch Services, so the script registers only the root copy and unregisters the DerivedData copy (`test.sh` unregisters its Debug build too). Do not install a second copy elsewhere, such as `~/Applications`, or Safari shows a duplicate extension. The build log is `build/xcodebuild.log`.

The project sets no development team. Building in Xcode without one signs with Sign to Run Locally (ad hoc), which works but needs Allow unsigned extensions in Safari (see below). To sign with your own certificate, choose your team under Signing and Capabilities for both the KeeBridge and KeeBridge Extension targets, and change the bundle identifiers if you distribute your build.

`test.sh` prints one PASS, FAIL or SKIP line per check:

- An unsigned incremental Debug build with Swift warnings treated as errors.
- A syntax check of every non-minified JavaScript file in the extension, parsed as classic scripts in one `node` process.
- `jq` parsing of every JSON file.
- Every file referenced by the manifest (including `__MSG_` keys against `_locales/en`) and by every HTML page must exist.
- A `node` test that `background/native-shim.js` passes the bare reply from a wrapped `{ name, userInfo }` message and an unwrapped error to `client.js`, and drops empty messages.
- A bridge smoke test that launches the Debug app, sends one framed message and one oversized header, then checks that the request was logged and the app is still alive. It is skipped, not failed, when port 17634 is already taken (for example by the running relay).

Concurrent runs wait on a lock.

## Release

```sh
./scripts/package-release.sh
```

`package-release.sh` writes `dist/KeeBridge-<version>.zip` (the version is `MARKETING_VERSION` from `project.pbxproj`) and prints its size and SHA-256. It refuses to run with uncommitted changes. It exports `HEAD` with `git archive` to `/tmp/keebridge-release/src` and builds there, so no path from your home folder ends up in the binaries. The build is universal (arm64 and x86_64, falling back to arm64 with a warning) and signed ad hoc with no team, so the zip carries no certificate, name or email. The extension keeps its sandbox and network.client entitlements and the `get-task-allow` entitlement is removed. The script then extracts the zip and fails, deleting the zip, if a privacy check fails: ad hoc signature and no team on the app and extension, no identity data in signatures or entitlements, no home path, user name, host name, certificate field or email in the strings of any file, no `.DS_Store`, AppleDouble files, extended attributes, dSYM or swiftmodule folders, and a passing `codesign --verify --deep --strict`. Personal strings are read from this Mac at run time (user and host names plus the fields of every code signing identity) and never stored in the script. Add more with `KEEBRIDGE_PRIVATE_PATTERNS="word another"`. The build log is `build/package-release.log`.

## Enable in Safari

1. Open Safari Settings, then Extensions, and turn on KeeBridge.
2. Allow the extension on the sites you use.
3. Approve the connection in KeePassXC on first use.

Ad hoc signed builds also need Allow unsigned extensions in Safari's Developer settings. Those settings appear after turning on Show features for web developers in Advanced. Safari resets Allow unsigned extensions on every relaunch.

## How it works

The extension's native handler sends each native message over TCP to `127.0.0.1:17634`, framed as a little-endian UInt32 length followed by JSON. Frames are capped at 1 MiB. If the app is not listening, the handler launches it in the background (NSWorkspace without activation, then the `keebridge://launch` URL scheme once the launch completes) and retries for up to 5 seconds. Requests that arrive within 5 seconds of a failed launch fail immediately with errorCode 5.

The app handles connections one at a time in arrival order. It starts `keepassxc-proxy` on demand, writes each frame to its stdin and pushes replies back to Safari with `SFSafariApplication.dispatchMessage`. If the KeePassXC socket is missing it replies with errorCode 5 itself. Safari delivers those replies to the extension's native port wrapped as `{ name, userInfo }`, and `background/native-shim.js` unwraps them for `client.js`.

Closing the status window keeps the relay running. Use the Quit button in the window (or Quit KeeBridge in the menu bar icon's menu, or the Dock) to stop it. The status window refreshes only while visible.

## Run as and Start at login

The status window has a Run as menu. The choice is stored in the `runMode` user default and applies immediately, without a relaunch.

- Menu bar app (the default) shows a key icon in the menu bar and no Dock icon. Its menu shows the relay and KeePassXC status and has Show Window, Open Safari Extension Settings and Quit KeeBridge.
- Dock app shows a Dock icon and the app menu, like a regular app.
- Background only shows neither. To get the window back, open the app again (from Finder, Spotlight or `open -a KeeBridge`).

Start at login registers the app as a login item with `SMAppService`. If macOS asks for approval, the window shows a button that opens Login Items in System Settings.

The window opens when you launch the app yourself. It stays hidden when Safari launches the app (the extension passes `--launched-by-safari` and then opens `keebridge://launch`) and when the app starts as a login item. In every case the window opens if the relay could not listen on port 17634. The `keebridge://launch` URL only brings the window forward while the relay is not listening.

Follow the logs with:

```sh
/usr/bin/log stream --level info --predicate 'subsystem == "com.jikaido.keebridge"'
```

## Limitations

- HTTP basic authentication autofill is not available. The MV3 `webRequestAuthProvider` permission has no Safari equivalent and was dropped.
- Managed (enterprise policy) settings are not supported. Upstream skips managed storage on Safari, and `managed_storage.json` is not shipped.
- The relay app must be running. The extension launches it automatically.

## Layout

- `upstream/` is the unmodified KeePassXC-Browser Chromium build (MV3), kept only to diff future releases. Never edit it.
- `xcode/KeeBridge/KeeBridge Extension/Resources/` is the Safari extension that is actually built.
- `xcode/KeeBridge/KeeBridge Extension/SafariWebExtensionHandler.swift` is the native handler that forwards to the app and launches it.
- `xcode/KeeBridge/KeeBridge/` holds the app. `AppDelegate.swift` contains the relay, the run modes and the menu bar item, and `ViewController.swift` the status window. The app is not sandboxed (it runs `keepassxc-proxy`). The extension is.
- `scripts/` holds `build-app.sh`, `package-release.sh`, `test.sh` and `make-icon.swift`. `swift scripts/make-icon.swift` rebuilds the half KeePassXC, half compass icon (the app icon set and the extension's `icons/safari_*.png`). It draws the background and the compass in code and renders the key from `upstream/icons/keepassxc.svg`, so it uses no Apple artwork and no installed app icons. The extension's pages keep the upstream KeePassXC icons.

## Updating KeePassXC-Browser

Reapply these Safari specific changes for each new upstream release. Paths below are relative to the extension Resources folder unless noted.

1. Replace `upstream/` with the new Chromium build, then copy it over the extension Resources folder, keeping `COPYING`, `background/background.html`, `background/native-shim.js` and `icons/safari_*.png`.
2. Delete the files Safari never loads (MV3 only files, the HTTP auth popup and the PNG toolbar icons): `background/background_service.js`, `managed_storage.json`, `offscreen/`, `icons/keepassxc-dark_*.png`, `popups/popup_httpauth.html`, `popups/popup_httpauth.js` and `icons/toolbar/*/*.png` (Safari uses the SVGs next to them). Grep the new release for references to each before deleting.
3. Convert `manifest.json` to MV2. Diff the result against the current manifest (`git show HEAD:...` or the working copy) before overwriting it.
   - Set `manifest_version` to 2.
   - Remove `version_name` and `minimum_chrome_version`.
   - Rename `action` to `browser_action`.
   - Remove `options_ui.open_in_tab`.
   - Replace `background.service_worker` with `"page": "background/background.html"` and `"persistent": true`.
   - Flatten `web_accessible_resources` to a plain list of paths.
   - Drop the `notifications`, `offscreen`, `webRequest` and `webRequestAuthProvider` permissions and add `"<all_urls>"` to `permissions`.
   - Remove `optional_permissions`, `host_permissions` and `storage.managed_schema`.
   - Set `content_security_policy` to the string `"script-src 'self'; object-src 'self'"`.
   - Point `icons` and `browser_action.default_icon` at `icons/safari_*.png` instead of `icons/keepassxc_*.png`.
   - Set `name` and `browser_action.default_title` to `"KeeBridge"`, and replace the `__MSG_extensionDescription__` key in `description` with the literal `"Fill KeePassXC passwords in Safari"`. Leave `_locales` untouched.
4. Rebuild the `<script>` list in `background/background.html` from the `importScripts` list in `upstream/background/background_service.js`, in the same order, and load `native-shim.js` right after `client.js`. Safari hands replies from the app to the native port wrapped as `{ name, userInfo }`, and the shim unwraps them for `client.js`.
5. Update the 1.10.4 mentions in `AppDelegate.swift` (header comment), `ViewController.swift` (status text) and the introduction of this README. KeeBridge has its own version: bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in all four target configurations of `project.pbxproj` (app and extension, Debug and Release) together.
6. Run `scripts/test.sh`, then `scripts/build-app.sh`.

## License

KeeBridge's own code (the Swift app, the native handler, `native-shim.js` and the scripts) is GPL-3.0-or-later. Copyright (C) 2026 jikaido. The combined work, including KeePassXC-Browser, is distributed under GPL-3.0. See `COPYING`, which also ships inside the extension and at the root of the release zip.

The extension is modified from KeePassXC-Browser 1.10.4 for Safari (October 2026). The changes are listed under Updating KeePassXC-Browser.
