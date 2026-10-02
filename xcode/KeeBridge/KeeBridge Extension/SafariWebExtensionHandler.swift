// KeeBridge, Safari bridge for KeePassXC. Copyright (C) 2026 jikaido. GPL-3.0-or-later. See COPYING.
// Forwards one connectNative message to the containing app. The app owns keepassxc-proxy.

import AppKit
import os
import SafariServices

private let bridgePort: UInt16 = 17634
private let maxFrameLength = 1024 * 1024
private let log = Logger(subsystem: "com.jikaido.keebridge", category: "handler")

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    // One serial queue for every request in this process. Frames reach the app in the order
    // Safari delivered them, at most one launch-and-wait runs at a time, and the thread Safari
    // calls beginRequest on is never parked in the retry loop.
    private static let forwardQueue = DispatchQueue(label: "com.jikaido.keebridge.forward")
    private static let launchWait: TimeInterval = 5
    // When the last launch-and-wait gave up. Only read and written on forwardQueue.
    private static var launchFailedAt = Date.distantPast

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        // data(withJSONObject:) raises an Objective-C exception on an invalid object, which try?
        // does not catch, so validate first.
        guard let message,
              JSONSerialization.isValidJSONObject(message),
              let payload = try? JSONSerialization.data(withJSONObject: message),
              payload.count <= maxFrameLength else {
            log.error("ignored an empty, non-object or oversized native message")
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        let action = message["action"] as? String ?? ""
        log.info("forward action=\(action, privacy: .public) bytes=\(payload.count, privacy: .public)")

        Self.forwardQueue.async {
            if Self.forward(payload) {
                // connectNative replies arrive through dispatchMessage, including database lock pushes.
                // Do not echo the request back through completeRequest.
                context.completeRequest(returningItems: nil, completionHandler: nil)
                return
            }

            let errorBody: [String: Any] = [
                "action": action,
                "error": "KeeBridge is not running",
                "errorCode": 5
            ]
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: errorBody]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    private static func forward(_ payload: Data) -> Bool {
        let length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: length) { Data($0) }
        frame.append(payload)

        if sendFrame(frame) {
            return true
        }
        // A launch-and-wait just gave up. Requests queued behind it fail at once instead of
        // relaunching and waiting again one after another.
        if Date().timeIntervalSince(launchFailedAt) < launchWait {
            return false
        }
        launchContainer()
        let deadline = Date().addingTimeInterval(launchWait)
        while Date() < deadline {
            usleep(150_000)
            if sendFrame(frame) {
                return true
            }
        }
        launchFailedAt = Date()
        return false
    }

    private static func launchContainer() {
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        log.info("launching container \(appURL.path, privacy: .public)")
        // Always open the URL too. If the app is running but its listener failed, this brings
        // the status window forward with the error.
        let openLaunchURL = {
            if let url = URL(string: "keebridge://launch") {
                NSWorkspace.shared.open(url)
            }
        }
        DispatchQueue.main.async {
            guard appURL.pathExtension == "app" else {
                openLaunchURL()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            // Tells the app to start without showing its window.
            configuration.arguments = ["--launched-by-safari"]
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    log.error("open app failed \(error.localizedDescription, privacy: .public)")
                }
                // Only after the launch. If the URL launched the app instead, the argument would be lost.
                DispatchQueue.main.async(execute: openLaunchURL)
            }
        }
    }

    private static func sendFrame(_ frame: Data) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            return false
        }
        defer { close(fd) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = bridgePort.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            return false
        }

        return writeAll(fd, frame)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        let total = data.count
        return data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < total {
                let n = write(fd, base.advanced(by: sent), total - sent)
                if n < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                if n == 0 {
                    return false
                }
                sent += n
            }
            return true
        }
    }
}
