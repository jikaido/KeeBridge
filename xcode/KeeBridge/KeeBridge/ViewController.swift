// KeeBridge, Safari bridge for KeePassXC. Copyright (C) 2026 jikaido. GPL-3.0-or-later. See COPYING.

import Cocoa
import ServiceManagement

class ViewController: NSViewController {
    private let relayField = NSTextField(labelWithString: "Relay: starting")
    private let keepassField = NSTextField(labelWithString: "KeePassXC: checking")
    private let proxyField = NSTextField(labelWithString: "Proxy: checking")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let runModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let approvalRow = NSStackView()
    private var stack: NSStackView?
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()

        let title = NSTextField(labelWithString: "KeeBridge")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        for field in [relayField, keepassField, proxyField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 2
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0
        detail.lineBreakMode = .byWordWrapping
        detail.stringValue = """
        This app relays Safari to KeePassXC. The database and the master password stay in KeePassXC.

        Keep this app running while you use the extension. Closing the window leaves the relay running. Use Quit to stop it. In Background only mode, open the app again to bring this window back.

        In Safari, open Settings, then Extensions, and turn on KeeBridge. Allow it on the sites you use. The first time a site asks for a password, approve the connection in KeePassXC.

        HTTP basic authentication autofill is not available in Safari.

        KeeBridge is unofficial and not affiliated with the KeePassXC project. It includes KeePassXC-Browser 1.10.4 under the GNU GPL version 3. The license is the COPYING file inside this app.
        """

        for mode in RunMode.allCases {
            runModePopup.addItem(withTitle: mode.title)
            runModePopup.lastItem?.representedObject = mode.rawValue
        }
        runModePopup.target = self
        runModePopup.action = #selector(runModeChanged)
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginToggled)
        let runModeRow = NSStackView(views: [NSTextField(labelWithString: "Run as:"), runModePopup, loginCheckbox])
        runModeRow.spacing = 8
        runModeRow.setCustomSpacing(20, after: runModePopup)

        let approvalNote = NSTextField(labelWithString: "Allow KeeBridge in Login Items to start it at login.")
        approvalNote.textColor = .secondaryLabelColor
        let approvalButton = NSButton(title: "Open Login Items", target: self, action: #selector(openLoginItems))
        approvalButton.bezelStyle = .rounded
        approvalButton.controlSize = .small
        approvalRow.addArrangedSubview(approvalNote)
        approvalRow.addArrangedSubview(approvalButton)
        approvalRow.spacing = 8
        approvalRow.isHidden = true

        let button = NSButton(title: "Open Safari Extension Settings", target: self, action: #selector(openSettings))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        let buttons = NSStackView(views: [button, quit])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, relayField, keepassField, proxyField, runModeRow, approvalRow, buttons, detail])
        self.stack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: title)
        stack.setCustomSpacing(16, after: proxyField)
        stack.setCustomSpacing(22, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            relayField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keepassField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            proxyField.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = detail.bounds.width
        if width > 0 {
            detail.preferredMaxLayoutWidth = width
            keepassField.preferredMaxLayoutWidth = width
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let stack, let window = view.window {
            let height = stack.fittingSize.height + 48
            window.setContentSize(NSSize(width: 520, height: max(height, 420)))
            window.minSize = NSSize(width: 440, height: 360)
        }
        if let index = RunMode.allCases.firstIndex(of: RunMode.current) {
            runModePopup.selectItem(at: index)
        }
        refreshLoginItem()
        // The occlusion state may not report visible yet, so fill the labels now.
        refresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: view.window
        )
        occlusionChanged()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        timer?.invalidate()
        timer = nil
    }

    // Poll only while the window is on screen. Hidden, minimized and covered windows do no work.
    @objc private func occlusionChanged() {
        guard view.window?.occlusionState.contains(.visible) == true else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else {
            return
        }
        refresh()
        // Catches approval granted in System Settings while the window was covered.
        refreshLoginItem()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 0.2
        self.timer = timer
    }

    private func refresh() {
        let state = ProxyBridge.shared.snapshot()
        relayField.stringValue = state.relayLine
        relayField.textColor = state.listening ? .labelColor : .systemRed
        keepassField.stringValue = state.keepassLine
        keepassField.textColor = state.socketFound ? .labelColor : .systemRed

        if !state.proxyInstalled {
            proxyField.stringValue = "Proxy: keepassxc-proxy is not at \(proxyExecutable)"
            proxyField.textColor = .systemRed
        } else if state.proxyRunning {
            proxyField.stringValue = "Proxy: running"
            proxyField.textColor = .labelColor
        } else {
            proxyField.stringValue = "Proxy: waiting for Safari"
            proxyField.textColor = .labelColor
        }
    }

    private func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        loginCheckbox.state = status == .enabled || status == .requiresApproval ? .on : .off
        let needsApproval = status == .requiresApproval
        guard approvalRow.isHidden == needsApproval else {
            return
        }
        approvalRow.isHidden = !needsApproval
        // Grow the window if the note no longer fits.
        if let stack, let window = view.window {
            let height = stack.fittingSize.height + 48
            if window.contentLayoutRect.height < height {
                window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: height))
            }
        }
    }

    @objc private func runModeChanged() {
        guard let raw = runModePopup.selectedItem?.representedObject as? String,
              let mode = RunMode(rawValue: raw) else {
            return
        }
        (NSApp.delegate as? AppDelegate)?.setRunMode(mode)
    }

    @objc private func loginToggled() {
        do {
            if loginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            presentAlert(NSAlert(error: error), in: view.window)
        }
        refreshLoginItem()
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func openSettings() {
        openExtensionSettings(from: view.window)
    }
}
