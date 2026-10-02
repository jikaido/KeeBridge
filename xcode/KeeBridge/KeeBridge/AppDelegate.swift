// KeeBridge, Safari bridge for KeePassXC. Copyright (C) 2026 jikaido. GPL-3.0-or-later. See COPYING.
// The bundled extension is KeePassXC-Browser 1.10.4.

import Cocoa
import os
import SafariServices

let extensionBundleIdentifier = "com.jikaido.keebridge.Extension"
let bridgePort: UInt16 = 17634
let proxyExecutable = "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-proxy"

private let maxFrameLength = 1024 * 1024
private let browserSocketName = "org.keepassxc.KeePassXC.BrowserServer"
private let log = Logger(subsystem: "com.jikaido.keebridge", category: "bridge")

struct BridgeSnapshot {
    var listening: Bool
    var listenError: String?
    var socketFound: Bool
    var proxyInstalled: Bool
    var proxyRunning: Bool
}

final class ProxyBridge {
    static let shared = ProxyBridge()

    private let lock = NSLock()
    // Clients are handled one at a time in accept order, so frames reach the proxy in the order Safari sent them.
    private let clientQueue = DispatchQueue(label: "com.jikaido.keebridge.clients")
    private var proxy: Process?
    private var proxyStdin: FileHandle?
    private var generation: UInt64 = 0
    private var listenFD: Int32 = -1

    private var listening = false
    private var listenError: String?

    func stop() {
        lock.lock()
        let proc = proxy
        let stdin = proxyStdin
        proxy = nil
        proxyStdin = nil
        generation &+= 1
        let fd = listenFD
        listenFD = -1
        listening = false
        lock.unlock()
        try? stdin?.close()
        proc?.terminate()
        if fd >= 0 {
            close(fd)
        }
    }

    func snapshot() -> BridgeSnapshot {
        lock.lock()
        let running = proxy?.isRunning == true
        lock.unlock()
        return BridgeSnapshot(
            listening: listening,
            listenError: listenError,
            socketFound: keePassSocketPath() != nil,
            proxyInstalled: FileManager.default.isExecutableFile(atPath: proxyExecutable),
            proxyRunning: running
        )
    }

    private func keePassSocketPath() -> String? {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(browserSocketName)
            .path
        if FileManager.default.fileExists(atPath: temporary) {
            return temporary
        }
        let fallback = "/tmp/" + browserSocketName
        if FileManager.default.fileExists(atPath: fallback) {
            return fallback
        }
        return nil
    }

    func start() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            listenError = String(cString: strerror(errno))
            log.error("socket failed \(self.listenError ?? "", privacy: .public)")
            return
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = bridgePort.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 || listen(fd, 16) != 0 {
            listenError = String(cString: strerror(errno))
            log.error("listen failed \(self.listenError ?? "", privacy: .public)")
            close(fd)
            return
        }

        listenFD = fd
        listening = true
        listenError = nil
        log.info("listening on 127.0.0.1:\(bridgePort, privacy: .public)")

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(fd)
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            var storage = sockaddr_in()
            let client = withUnsafeMutablePointer(to: &storage) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    return accept(fd, sock, &length)
                }
            }
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                log.error("accept ended errno=\(errno, privacy: .public)")
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            clientQueue.async { [weak self] in
                self?.handleClient(client)
                close(client)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        // Clients are served one at a time on clientQueue, so an idle connection stalls Safari
        // until this fires. The extension writes each frame in one go over loopback and closes.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        while let frame = readFrame(fd, source: "client") {
            forward(frame)
        }
    }

    private func forward(_ frame: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            log.error("dropped a frame that was not a JSON object")
            return
        }
        let action = object["action"] as? String ?? ""
        log.info("request action=\(action, privacy: .public) bytes=\(frame.count, privacy: .public)")

        if keePassSocketPath() == nil {
            log.error("KeePassXC socket missing for action=\(action, privacy: .public)")
            dispatch([
                "action": action,
                "error": "KeePassXC is not running",
                "errorCode": 5
            ])
            return
        }
        sendToProxy(frame)
    }

    // Runs on clientQueue only, so writes are serialized without holding the lock.
    // Writing outside the lock keeps a full stdin pipe from blocking the stdout reader.
    private func sendToProxy(_ frame: Data) {
        let length = UInt32(frame.count).littleEndian
        let header = withUnsafeBytes(of: length) { Data($0) }
        for attempt in 0..<2 {
            var written: UInt64?
            do {
                let input = try proxyInput()
                written = input.generation
                try input.stdin.write(contentsOf: header)
                try input.stdin.write(contentsOf: frame)
                return
            } catch {
                log.error("proxy write failed \(error.localizedDescription, privacy: .public)")
                discardProxy(generation: written)
                if attempt == 1 {
                    return
                }
            }
        }
    }

    private func proxyInput() throws -> (stdin: FileHandle, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let stdin = try ensureProxyLocked()
        return (stdin, generation)
    }

    // A nil generation means the spawn failed. Otherwise skip if stop() or a respawn already replaced that proxy.
    private func discardProxy(generation failed: UInt64?) {
        lock.lock()
        if let failed, failed != generation {
            lock.unlock()
            return
        }
        let proc = proxy
        proxy = nil
        proxyStdin = nil
        generation &+= 1
        lock.unlock()
        proc?.terminate()
    }

    // proxy and proxyStdin are always set and cleared together under the lock.
    private func ensureProxyLocked() throws -> FileHandle {
        if let proxy, proxy.isRunning, let proxyStdin {
            return proxyStdin
        }
        guard FileManager.default.isExecutableFile(atPath: proxyExecutable) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: proxyExecutable)
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = errors
        try proc.run()

        generation &+= 1
        let expected = generation
        let stdin = input.fileHandleForWriting
        proxy = proc
        proxyStdin = stdin
        let stdout = output.fileHandleForReading
        let stderr = errors.fileHandleForReading

        log.info("started keepassxc-proxy pid=\(proc.processIdentifier, privacy: .public)")

        Thread.detachNewThread { [weak self] in
            self?.readProxyStdout(stdout, generation: expected)
        }
        Thread.detachNewThread {
            while true {
                let data = stderr.availableData
                if data.isEmpty {
                    return
                }
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty {
                    let clipped = String(text.prefix(300))
                    log.error("proxy stderr \(clipped, privacy: .public)")
                }
            }
        }
        return stdin
    }

    private func readProxyStdout(_ handle: FileHandle, generation expected: UInt64) {
        while true {
            lock.lock()
            let current = generation
            lock.unlock()
            if current != expected {
                return
            }
            guard let body = readFrame(handle.fileDescriptor, source: "proxy") else {
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                log.error("proxy frame was not a JSON object")
                continue
            }
            let action = object["action"] as? String ?? ""
            let success = object["success"] as? String ?? ""
            let errorCode = (object["errorCode"] as? NSNumber)?.intValue ?? -1
            log.info("proxy response action=\(action, privacy: .public) success=\(success, privacy: .public) errorCode=\(errorCode, privacy: .public)")
            dispatch(sanitize(object))
        }
    }

    private func dispatch(_ info: [String: Any]) {
        let action = info["action"] as? String ?? ""
        DispatchQueue.main.async {
            SFSafariApplication.dispatchMessage(
                withName: "keepassxc",
                toExtensionWithIdentifier: extensionBundleIdentifier,
                userInfo: info
            ) { error in
                if let error {
                    log.error("dispatch \(action, privacy: .public) failed \(error.localizedDescription, privacy: .public)")
                } else {
                    log.info("dispatched \(action, privacy: .public)")
                }
            }
        }
    }

    private func sanitize(_ object: [String: Any]) -> [String: Any] {
        var cleaned: [String: Any] = [:]
        for (key, value) in object {
            if let propertyList = plistValue(value) {
                cleaned[key] = propertyList
            }
        }
        return cleaned
    }

    private func plistValue(_ value: Any) -> Any? {
        switch value {
        case is NSNull:
            return nil
        case let text as String:
            return text
        case let number as NSNumber:
            return number
        case let dictionary as [String: Any]:
            return sanitize(dictionary)
        case let list as [Any]:
            return list.compactMap { plistValue($0) }
        default:
            return nil
        }
    }

    private func readFrame(_ fd: Int32, source: String) -> Data? {
        guard let header = readExact(fd, 4) else {
            return nil
        }
        let bytes = [UInt8](header)
        let length = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        if length == 0 || length > UInt32(maxFrameLength) {
            log.error("\(source, privacy: .public) frame length rejected")
            return nil
        }
        return readExact(fd, Int(length))
    }

    private func readExact(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n: Int = data.withUnsafeMutableBytes { raw in
                let pointer = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: got)
                return read(fd, pointer, count - got)
            }
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            if n == 0 {
                return nil
            }
            got += n
        }
        return data
    }
}

extension BridgeSnapshot {
    var relayLine: String {
        if listening {
            return "Relay: listening on 127.0.0.1:\(bridgePort)"
        }
        return "Relay: not listening. \(listenError ?? "port \(bridgePort) is unavailable")"
    }

    var keepassLine: String {
        socketFound ? "KeePassXC: running" : "KeePassXC: not reachable. Open KeePassXC and unlock a database."
    }
}

enum RunMode: String, CaseIterable {
    case dock, menuBar, background

    private static let defaultsKey = "runMode"

    static var current: RunMode {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(RunMode.init(rawValue:)) ?? .menuBar }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var title: String {
        switch self {
        case .dock: return "Dock app"
        case .menuBar: return "Menu bar app"
        case .background: return "Background only"
        }
    }
}

func openExtensionSettings(from window: NSWindow?) {
    SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { error in
        guard let error else {
            return
        }
        // An alert persists, unlike a status label that refresh() rewrites every second.
        DispatchQueue.main.async {
            presentAlert(NSAlert(error: error), in: window)
        }
    }
}

func presentAlert(_ alert: NSAlert, in window: NSWindow?) {
    if let window, window.isVisible {
        alert.beginSheetModal(for: window)
    } else {
        NSApp.activate()
        alert.runModal()
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowController: NSWindowController?
    private var statusItem: NSStatusItem?
    private let relayMenuLine = NSMenuItem(title: "Relay: starting", action: nil, keyEquivalent: "")
    private let keepassMenuLine = NSMenuItem(title: "KeePassXC: checking", action: nil, keyEquivalent: "")
    private var finishedLaunching = false
    private var launchedForURL = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so menu bar and background modes do not flash a Dock icon.
        applyRunMode()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        ProxyBridge.shared.start()
        finishedLaunching = true

        // The launch Apple event is current here, not in applicationWillFinishLaunching.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let bySafari = ProcessInfo.processInfo.arguments.contains("--launched-by-safari")
        let failed = ProxyBridge.shared.snapshot().listenError != nil
        log.info("launch mode=\(RunMode.current.rawValue, privacy: .public) safari=\(bySafari, privacy: .public) url=\(self.launchedForURL, privacy: .public) loginItem=\(loginItem, privacy: .public) listenFailed=\(failed, privacy: .public)")
        if failed || !(bySafari || launchedForURL || loginItem) {
            showWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        applyRunMode()
        showWindow()
        return true
    }

    // The extension opens this URL on every launch attempt, so only an error brings the window up.
    func application(_ application: NSApplication, open urls: [URL]) {
        applyRunMode()
        // Launched through the URL, which only the extension opens. didFinishLaunching decides.
        guard finishedLaunching else {
            launchedForURL = true
            return
        }
        if !ProxyBridge.shared.snapshot().listening {
            showWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyBridge.shared.stop()
    }

    func setRunMode(_ mode: RunMode) {
        let wasVisible = statusWindow()?.isVisible == true
        RunMode.current = mode
        applyRunMode()
        // Leaving .regular deactivates the app and sends the window behind others.
        if wasVisible {
            showWindow()
        }
    }

    @objc func showWindow() {
        guard let window = statusWindow() else {
            return
        }
        // An accessory app is not activated by ordering a window front.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // The storyboard has no initial controller, because AppKit always shows that one at launch.
    private func statusWindow() -> NSWindow? {
        if windowController == nil {
            windowController = NSStoryboard.main?.instantiateController(withIdentifier: "StatusWindow") as? NSWindowController
        }
        return windowController?.window
    }

    // Also called on reopen and URL opens, because Launch Services turns the running app back
    // into a regular Dock app when it is opened again.
    private func applyRunMode() {
        let mode = RunMode.current
        let policy: NSApplication.ActivationPolicy = mode == .dock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
        if mode == .menuBar {
            installStatusItem()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else {
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "KeeBridge")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        relayMenuLine.isEnabled = false
        keepassMenuLine.isEnabled = false
        menu.addItem(relayMenuLine)
        menu.addItem(keepassMenuLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Window", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Safari Extension Settings", action: #selector(openSettingsFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit KeeBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let state = ProxyBridge.shared.snapshot()
        relayMenuLine.title = state.relayLine
        keepassMenuLine.title = state.keepassLine
    }

    @objc private func openSettingsFromMenu() {
        openExtensionSettings(from: statusWindow())
    }
}
