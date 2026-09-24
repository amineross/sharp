import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Network
import ServiceManagement
import SwiftUI
import SystemConfiguration
import VideoToolbox

@main
enum SharpMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var permissionWindow: NSWindow?
    private var installWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var advancedWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?
    private var audioProbe: SharpAudio?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Task { @MainActor in
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--audio-probe"), args.count > index + 4 {
                let mode = args[index + 1]
                let route = SharpAudio { state in
                    print("audio-probe \(state)"); fflush(stdout)
                }
                self.audioProbe = route
                if mode == "receive" {
                    route.receive(on: args[index + 2], token: args[index + 3])
                } else if mode == "send", args.count > index + 5 {
                    route.send(from: args[index + 2], to: args[index + 3], token: args[index + 4])
                } else { NSApp.terminate(nil); return }
                let duration = min(300.0, max(1.0, Double(args.last ?? "15") ?? 15))
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    route.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                }
                return
            }
            if CommandLine.arguments.contains("--uninstall") {
                self.uninstallCurrentUser()
                return
            }
            guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
                self.showInstallRequired()
                return
            }
            let notifications = NSWorkspace.shared.notificationCenter
            notifications.addObserver(self, selector: #selector(systemWillSleep),
                                      name: NSWorkspace.willSleepNotification, object: nil)
            notifications.addObserver(self, selector: #selector(systemDidWake),
                                      name: NSWorkspace.didWakeNotification, object: nil)
            self.installStatusItem()
            SharpModel.shared.activate()
            if !SharpModel.shared.configured { self.showPermission() }
            else if SharpModel.shared.needsScreenPermission { self.showPermission() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            if SharpModel.shared.configured { self.showSettings() } else { self.showPermission() }
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            SharpModel.shared.refreshAfterActivation()
        }
    }

    @MainActor @objc private func systemWillSleep() {
        SharpModel.shared.systemWillSleep()
    }

    @MainActor @objc private func systemDidWake() {
        SharpModel.shared.systemDidWake()
    }

    @MainActor private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = sharpStatusImage()
            button.setAccessibilityLabel("Sharp")
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 440)
        popover.contentViewController = NSHostingController(rootView: SharpMenuView().environmentObject(SharpModel.shared))
        self.statusItem = item
        self.popover = popover
    }

    @MainActor @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover?.isShown == true { popover?.performClose(sender) }
        else { showMenu() }
    }

    @MainActor func showMenu() {
        guard let popover, let button = statusItem?.button else { return }
        if let size = popover.contentViewController?.view.fittingSize { popover.contentSize = size }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @MainActor func closeDiagnostics() { diagnosticsWindow?.close() }

    @MainActor func closeSettings() { settingsWindow?.close() }

    @MainActor func closeAdvanced() { advancedWindow?.close() }

    @MainActor func showAdvanced() {
        if advancedWindow == nil {
            advancedWindow = makeWindow(size: NSSize(width: 520, height: 570), title: "Sharp Advanced",
                                        content: SharpAdvancedView().environmentObject(SharpModel.shared))
        }
        advancedWindow?.setContentSize(NSSize(width: 520, height: SharpModel.shared.role == .sender ? 570 : 290))
        present(advancedWindow)
    }

    @MainActor func showSettings() {
        popover?.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = makeWindow(size: NSSize(width: 620, height: 560), title: "Sharp Settings",
                                        content: SharpSettingsView().environmentObject(SharpModel.shared))
        }
        settingsWindow?.setContentSize(NSSize(width: 620, height: SharpModel.shared.role == .sender ? 560 : 480))
        present(settingsWindow)
    }

    @MainActor func showDiagnostics() {
        SharpModel.shared.runProbes()
        if diagnosticsWindow == nil {
            diagnosticsWindow = makeWindow(size: NSSize(width: 560, height: 500), title: "Sharp Compatibility",
                                           content: DiagnosticsView().environmentObject(SharpModel.shared))
        }
        present(diagnosticsWindow)
    }

    @MainActor private func showPermission() {
        if permissionWindow == nil {
            let content = PermissionView(dismiss: { [weak self] in self?.permissionWindow?.close() })
                .environmentObject(SharpModel.shared)
            permissionWindow = makeWindow(size: NSSize(width: 580, height: 390), title: "Sharp", content: content)
        }
        present(permissionWindow)
    }

    @MainActor private func showInstallRequired() {
        let content = InstallView(install: { [weak self] in self?.installAndRelaunch() })
        installWindow = makeWindow(size: NSSize(width: 500, height: 230), title: "Install Sharp", content: content)
        present(installWindow)
    }

    @MainActor private func installAndRelaunch() {
        let source = Bundle.main.bundleURL.path
        let destination = "/Applications/Sharp.app"
        let command = "/usr/bin/ditto \(shellQuote(source)) \(shellQuote(destination))"
        var installed = runShell(command)
        if !installed {
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            var error: NSDictionary?
            let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
            installed = script?.executeAndReturnError(&error) != nil
        }
        guard installed, FileManager.default.isExecutableFile(atPath: destination + "/Contents/MacOS/Sharp") else {
            let alert = NSAlert()
            alert.messageText = "Sharp could not be installed"
            alert.informativeText = "Move Sharp.app into Applications, then open it again."
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: destination))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    private func runShell(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor private func makeWindow<Content: View>(size: NSSize, title: String, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.145, green: 0.145, blue: 0.135, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func sharpStatusImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "SharpStatus", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            image.accessibilityDescription = "Sharp"
            return image
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.white.setFill()
            let text = "sh" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (rect.width-size.width)/2, y: (rect.height-size.height)/2), withAttributes: attributes)
            return rect.width > 0
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sharp"
        return image
    }

    @MainActor private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor private func uninstallCurrentUser() {
        if #available(macOS 13.0, *) { try? SMAppService.mainApp.unregister() }
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/sh.sharp.app.autostart.plist")
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["bootout", "gui/\(getuid())/sh.sharp.app.autostart"]
        launchctl.standardOutput = FileHandle.nullDevice
        launchctl.standardError = FileHandle.nullDevice
        try? launchctl.run()
        launchctl.waitUntilExit()
        try? FileManager.default.removeItem(at: agent)
        UserDefaults.standard.removePersistentDomain(forName: "sh.sharp.app")
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("Sharp", isDirectory: true))
        }
        NSApp.terminate(nil)
    }
}
