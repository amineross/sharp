import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Network
import ServiceManagement
import SwiftUI
import SystemConfiguration
import VideoToolbox

@MainActor
final class SharpModel: ObservableObject {
    static let shared = SharpModel()
    @Published var role: SharpRole
    @Published var resolution: SharpResolution
    @Published var displayMode: SharpMode
    @Published var cursorHue: Double
    @Published var cursorScale: Double
    @Published var logsEnabled: Bool
    @Published var launchAtLogin: Bool
    @Published var configured: Bool
    @Published var sharingEnabled: Bool
    @Published var status = "Starting…"
    @Published var peerName = ""
    @Published var peerDisplaySize: SharpDisplaySize?
    @Published var linkState: SharpLinkState = .waiting
    @Published var probes: [ProbeResult] = []
    @Published var showingDiagnostics = false
    @Published var audioEnabled = true
    @Published var preferredInterface: String
    @Published var profiles: [String: SharpPeerProfile]
    @Published var benchmarkRunning = false
    @Published var benchmarkStatus = ""
    var benchmarkLines: [String] = []
    var benchmarkStartedAt: Date?
    var benchmarkProcess: Process?
    var benchmarkScene = ""
    var benchmarkSenderPID: Int32?
    var streamDisplayID: UInt32?
    var benchmarkPeerScene: String?
    @Published var audioPermissionConfirmed = false
    var permissionAudio: SharpAudio?
    var peerSharingEnabled = true
    @Published var audioActive = false
    @Published var audioStatus = ""
    @Published var peerSupportsAudio = false
    var audioRoute: SharpAudio?
    var audioToken: String?
    var audioSourceIP: String?
    var audioReceiverIP: String?

    let defaults: UserDefaults
    let controlPort: NWEndpoint.Port = 49171
    let streamPort = "49172"
    let serviceType = "_sharp._tcp"
    let queue = DispatchQueue(label: "sh.sharp.control")
    let peerID: String
    var hasSavedRole: Bool
    var rememberedPeerID: String?
    var listener: NWListener?
    var browser: NWBrowser?
    var control: LineConnection?
    var pendingConnection: NWConnection?
    var senderProcess: Process?
    var receiverProcess: Process?
    var reconnectWork: DispatchWorkItem?
    var heartbeatWork: DispatchWorkItem?
    var lastControlMessage = Date.distantPast
    var senderTail: [String] = []
    var receiverTail: [String] = []
    var receiverReady: (() -> Void)?
    var peerReportedSleep = false
    var localSleeping = false
    var controlTail: [String] = []
    var stopping = false
    var expectedTerminations = Set<Int32>()
    var activated = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedRole = defaults.string(forKey: "role")
        role = SharpRole(rawValue: savedRole ?? "") ?? .sender
        hasSavedRole = savedRole != nil
        resolution = SharpResolution(rawValue: defaults.string(forKey: "resolution") ?? "") ?? .native
        displayMode = SharpMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .mirror
        cursorScale = defaults.object(forKey: "cursorScale") as? Double ?? 1.0
        cursorHue = defaults.object(forKey: "cursorHue") as? Double ?? 0.94
        audioPermissionConfirmed = defaults.bool(forKey: "audioPermissionConfirmed")
        audioEnabled = defaults.object(forKey: "audioEnabled") as? Bool ?? true
        preferredInterface = defaults.string(forKey: "preferredInterface") ?? ""
        profiles = (defaults.data(forKey: "peerProfiles").flatMap { try? JSONDecoder().decode([String: SharpPeerProfile].self, from: $0) }) ?? [:]
        logsEnabled = defaults.object(forKey: "logsEnabled") as? Bool ?? false
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        configured = defaults.bool(forKey: "configured")
        sharingEnabled = defaults.object(forKey: "sharingEnabled") as? Bool ?? true
        peerID = defaults.string(forKey: "peerID") ?? UUID().uuidString.lowercased()
        rememberedPeerID = defaults.string(forKey: "rememberedPeerID")
        defaults.set(peerID, forKey: "peerID")
        if let id = rememberedPeerID, let profile = profiles[id] { applyProfile(profile) }
        if SharpResolution(rawValue: defaults.string(forKey: "resolution") ?? "") == nil {
            defaults.set(SharpResolution.native.rawValue, forKey: "resolution")
        }
    }

    var isStreaming: Bool { senderProcess?.isRunning == true || receiverProcess?.isRunning == true }
    var isPeerConnected: Bool { linkState == .connected }
    var canShare: Bool { !probes.contains { $0.level == .fatal } }
    var needsScreenPermission: Bool {
        role == .sender && probes.contains { $0.id == "capture" && $0.level == .fatal }
    }
    var hasRememberedPeer: Bool { rememberedPeerID != nil }
    var selectedStreamSize: (Int, Int) {
        let lastDisplay = rememberedPeerID.flatMap { profiles[$0]?.display }
        return resolution.size(for: peerDisplaySize ?? lastDisplay ?? SharpDisplaySize(width: 2560, height: 1440))
    }
    var reportsURL: URL { appSupportURL.appendingPathComponent("Reports", isDirectory: true) }

    func activate() {
        guard !activated else { return }
        activated = true
        runProbes()
        let probeSummary = probes.map { "\($0.id):\($0.level.rawValue)" }.joined(separator: ",")
        trace("activate role=\(role.rawValue) configured=\(configured) sharing=\(sharingEnabled) probes=\(probeSummary)")
        guard configured else { status = "Choose how this Mac will use Sharp"; return }
        applyLaunchAtLogin()
        startRole()
    }

    func saveAndStart() {
        configured = true
        sharingEnabled = true
        persist()
        runProbes()
        applyLaunchAtLogin()
        startRole()
    }

    func saveRoleChoice() {
        defaults.set(role.rawValue, forKey: "role")
        hasSavedRole = true
        runProbes()
    }

    var receiverInput: Pipe?
    func cursorChanged() {
        defaults.set(cursorScale, forKey: "cursorScale")
        defaults.set(cursorHue, forKey: "cursorHue")
        saveCurrentProfile()
        control?.send(ControlMessage(command: "cursor-style", peerID: peerID, peerName: "", cursorScale: cursorScale, cursorHue: cursorHue))
        updateReceiverCursor()
    }
    func updateReceiverCursor() {
        guard receiverProcess?.isRunning == true, let input = receiverInput else { return }
        let line = "\(cursorScale) \(cursorHue)\n"
        line.withCString { _ = Darwin.write(input.fileHandleForWriting.fileDescriptor, $0, strlen($0)) }
    }
    func handleCursorStyle(_ message: ControlMessage) -> Bool {
        guard message.command == "cursor-style" else { return false }
        guard let scale = message.cursorScale, let hue = message.cursorHue,
              scale.isFinite, hue.isFinite else { return true }
        cursorScale = min(2, max(0.6, scale)); cursorHue = min(1, max(0, hue))
        defaults.set(cursorScale, forKey: "cursorScale"); defaults.set(cursorHue, forKey: "cursorHue")
        updateReceiverCursor()
        return true
    }

    func settingsChanged(restart: Bool = true) {
        persist()
        applyLaunchAtLogin()
        if restart && configured {
            if role == .receiver, control != nil {
                stopReceiver()
                control?.send(ControlMessage(command: "restart", peerID: peerID, peerName: Host.current().localizedName ?? "Mac",
                                             mode: displayMode.rawValue, cursorScale: cursorScale, cursorHue: cursorHue))
                status = "Applying settings…"
            } else {
                restartRole()
            }
        }
    }

    func chooseDisplayMode(_ mode: SharpMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        settingsChanged()
    }

    func chooseRole(_ newRole: SharpRole) {
        guard role != newRole else { return }
        role = newRole
        persist()
        runProbes()
        if configured { restartRole() }
    }

    func savePreferences() {
        persist()
        applyLaunchAtLogin()
    }

    func chooseInterface(_ name: String) {
        guard preferredInterface != name else { return }
        preferredInterface = name
        defaults.set(name, forKey: "preferredInterface")
        saveCurrentProfile()
        if configured { restartRole() }
    }

    func toggleSharing() {
        sharingEnabled.toggle()
        trace("sharing \(sharingEnabled ? "resumed" : "paused")")
        defaults.set(sharingEnabled, forKey: "sharingEnabled")
        if !sharingEnabled {
            control?.send(ControlMessage(command: "stop", peerID: peerID,
                peerName: Host.current().localizedName ?? "Mac", sharingEnabled: false))
            stopSender(); stopReceiver()
            status = isPeerConnected ? "Paused" : "Connect an Ethernet cable"
        } else if control != nil {
            control?.send(ControlMessage(command: "resume", peerID: peerID,
                peerName: Host.current().localizedName ?? "Mac", sharingEnabled: true))
            if role == .sender { sendStartRequest() }
        } else { startRole() }
    }

    var connectionStatus: SharpConnectionStatus {
        if localSleeping || peerReportedSleep || linkState == .sleeping ||
            (isPeerConnected && (!sharingEnabled || !peerSharingEnabled)) { return .paused }
        return isPeerConnected ? .connected : .disconnected
    }

    var connectionTitle: String { connectionStatus.rawValue }

    var connectionDetail: String {
        if connectionStatus == .disconnected { return "No Mac connected" }
        return peerName.isEmpty ? "Waiting for the other Mac" : peerName
    }

    func confirmAudioPermission() {
        audioPermissionConfirmed = true
        defaults.set(true, forKey: "audioPermissionConfirmed")
    }

    func requestAudioPermission() {
        guard #available(macOS 14.2, *) else { return }
        guard permissionAudio == nil else { return }
        let route = SharpAudio { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if state == "permission-confirmed" { self.confirmAudioPermission() }
                self.permissionAudio = nil
            }
        }
        permissionAudio = route
        route.requestPermission()
    }

    func forgetPairing() {
        if let id = rememberedPeerID { profiles.removeValue(forKey: id); saveProfiles() }
        rememberedPeerID = nil
        peerName = ""
        defaults.removeObject(forKey: "rememberedPeerID")
        restartRole()
    }

    func requestScreenPermission() {
        guard role == .sender else { return }
        saveRoleChoice()
        let result = run(senderURL, ["--check-permission", "--request-permission"])
        if result.code == 0 {
            runProbes()
            if configured { startRole() }
            status = configured ? "Waiting for a Sharp connection" : "Permission granted. Reopen Sharp to continue."
        } else {
            status = "Allow Sharp in Screen Recording, then reopen it"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func revealReports() {
        try? FileManager.default.createDirectory(at: reportsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([reportsURL])
    }

    func shutdown() { stopAll(userInitiated: true) }

    func systemWillSleep() {
        guard configured else { return }
        localSleeping = true
        trace("system will sleep")
        control?.send(ControlMessage(command: "sleeping", peerID: peerID,
                                     peerName: Host.current().localizedName ?? "Mac"))
        reconnectWork?.cancel(); reconnectWork = nil
        heartbeatWork?.cancel()
        heartbeatWork = nil
        stopSender(); stopReceiver()
        linkState = .sleeping
        status = "This Mac is going to sleep"
    }

    func systemDidWake() {
        guard configured else { return }
        localSleeping = false
        peerReportedSleep = false
        trace("system did wake")
        stopAll(userInitiated: false)
        linkState = .waiting
        status = "Waiting for a Sharp connection"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.localSleeping else { return }
            self.startRole()
        }
    }

    func runProbes() {
        var next: [ProbeResult] = []
        let osOK: Bool
        if role == .sender {
            if #available(macOS 12.3, *) { osOK = true } else { osOK = false }
        } else {
            if #available(macOS 10.15, *) { osOK = true } else { osOK = false }
        }
        next.append(.init(id: "os", level: osOK ? .pass : .fatal,
                          title: "macOS", detail: osOK ? ProcessInfo.processInfo.operatingSystemVersionString :
                            (role == .sender ? "Sending requires macOS 12.3 or newer" : "Displaying requires macOS 10.15 or newer")))
        let helpers = [senderURL, receiverURL].allSatisfy { FileManager.default.isExecutableFile(atPath: $0.path) }
        next.append(.init(id: "helpers", level: helpers ? .pass : .fatal,
                          title: "Packaged engines", detail: helpers ? "Sender and receiver are included" : "Sharp is incomplete; reinstall the app"))
        let wired = activeWiredInterfaces().filter {
            preferredInterface.isEmpty || $0.hasPrefix(preferredInterface + " ")
        }
        next.append(.init(id: "ethernet", level: wired.isEmpty ? .warning : .pass,
                          title: "Ethernet", detail: wired.isEmpty ? "Connect a direct Ethernet cable" : wired.joined(separator: ", ")))
        if role == .sender {
            let size = selectedStreamSize
            let encoder = h264HardwareEncoderAvailable(width: size.0, height: size.1)
            next.append(.init(id: "h264", level: encoder ? .pass : .warning,
                              title: "H.264 hardware", detail: encoder ? "Hardware encode is available at \(size.0)×\(size.1)" : "No hardware encoder reported at \(size.0)×\(size.1); motion may be slow"))
            let permission = run(senderURL, ["--check-permission"]).code == 0
            next.append(.init(id: "capture", level: permission ? .pass : .fatal,
                              title: "Screen Recording", detail: permission ? "Granted" : "Permission is required to send this screen"))
            let virtualAPI = NSClassFromString("CGVirtualDisplay") != nil
            next.append(.init(id: "extend", level: virtualAPI ? .pass : .warning,
                              title: "Extended display", detail: virtualAPI ? "Virtual-display API is present" : "Mirror works; Extend is unavailable"))
        } else {
            let receiverProbe = run(receiverURL, ["--check-compatibility"])
            let renderer = receiverProbe.code == 0
            next.append(.init(id: "renderer", level: renderer ? .pass : .fatal,
                              title: "Display renderer", detail: renderer ? "OpenGL 3.2 renderer is available" : "This Mac cannot create Sharp's display renderer"))
            let decoder = receiverProbe.output.contains("h264_hw_decode=1")
            next.append(.init(id: "h264", level: decoder ? .pass : .warning,
                              title: "H.264 hardware", detail: decoder ? "Hardware decode is available" : "No hardware decoder reported; motion may be slow"))
        }
        probes = next
    }

    func refreshAfterActivation() {
        guard activated else { return }
        let wasCaptureBlocked = needsScreenPermission
        runProbes()
        guard configured else { return }
        if control == nil && browser == nil && listener == nil && pendingConnection == nil {
            startRole()
        } else if wasCaptureBlocked && !needsScreenPermission && role == .sender {
            sendStartRequest()
        }
    }

    func startRole() {
        guard configured, !localSleeping else { return }
        stopNetworking()
        linkState = peerReportedSleep ? .sleeping : .waiting
        runProbes()
        let wiredSummary = activeWiredInterfaces().joined(separator: ",")
        trace("start role=\(role.rawValue) wired=\(wiredSummary)")
        guard !probes.contains(where: { $0.level == .fatal && $0.id != "capture" }) else {
            status = probes.first(where: { $0.level == .fatal })?.detail ?? "This Mac is not ready"; return
        }
        if role == .receiver { startReceiverService() } else { startBrowser() }
    }

    func restartRole() {
        stopAll(userInitiated: true)
        startRole()
    }

    func stopAll(userInitiated: Bool) {
        stopping = true
        reconnectWork?.cancel(); reconnectWork = nil
        if userInitiated { control?.send(ControlMessage(command: "stop", peerID: peerID, peerName: "Sharp")) }
        control?.cancel(); control = nil
        peerDisplaySize = nil
        heartbeatWork?.cancel(); heartbeatWork = nil
        stopNetworking(); stopSender(); stopReceiver()
        stopping = false
        status = sharingEnabled ? "Stopped" : "Sharing paused"
    }

    func stopSender() {
        if benchmarkRunning { stopBenchmark(reason: "Stream stopped") }
        streamDisplayID = nil
        stopAudio(); audioSourceIP = nil; audioReceiverIP = nil; terminate(senderProcess); senderProcess = nil
    }
    func stopReceiver() { benchmarkPeerScene = nil; receiverInput = nil; stopAudio(); receiverReady = nil; terminate(receiverProcess); receiverProcess = nil }
    func stopNetworking() {
        pendingConnection?.cancel(); pendingConnection = nil
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
    }

    func rememberPeer(_ id: String) {
        rememberProfile(id, name: peerName.isEmpty ? "Mac" : peerName)
    }

    func scheduleReconnect() {
        guard configured, !localSleeping else { return }
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.configured, !self.localSleeping,
                      self.control == nil else { return }
                self.startRole()
            }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func startHeartbeat() {
        lastControlMessage = Date()
        heartbeatWork?.cancel()
        scheduleHeartbeat()
    }

    func scheduleHeartbeat() {
        guard control != nil, !localSleeping else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.heartbeatTick() }
        }
        heartbeatWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func heartbeatTick() {
        guard let control, !localSleeping else { return }
        if Date().timeIntervalSince(lastControlMessage) > 4 {
            control.cancel()
            if role == .receiver {
                self.control = nil
                stopReceiver()
                linkState = peerReportedSleep ? .sleeping : .waiting
                status = peerReportedSleep
                    ? "\(peerName.isEmpty ? "The sender" : peerName) is asleep"
                    : "Waiting for a Sharp connection"
            } else {
                handleDisconnect()
            }
            return
        }
        control.send(ControlMessage(command: "ping", peerID: peerID,
                                    peerName: Host.current().localizedName ?? "Mac"))
        scheduleHeartbeat()
    }

    func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        expectedTerminations.insert(process.processIdentifier)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }

    func directPathProblem(_ path: NWPath?) -> String? {
        guard let path, path.usesInterfaceType(.wiredEthernet) else { return "Connect both Macs with Ethernet" }
        guard let address = wiredIPv4Address(for: path) else { return "This Ethernet link needs an IPv4 address" }
        if !preferredInterface.isEmpty && ipv4Address(interfaceName: preferredInterface) != address {
            return "The selected Ethernet interface is not connected to this Mac"
        }
        return nil
    }

    func persist() {
        defaults.set(role.rawValue, forKey: "role")
        defaults.set(resolution.rawValue, forKey: "resolution")
        defaults.set(displayMode.rawValue, forKey: "displayMode")
        defaults.set(cursorScale, forKey: "cursorScale")
        defaults.set(cursorHue, forKey: "cursorHue")
        defaults.set(logsEnabled, forKey: "logsEnabled")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(configured, forKey: "configured")
        defaults.set(sharingEnabled, forKey: "sharingEnabled")
        saveCurrentProfile()
    }

    func applyLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin && SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
                if !launchAtLogin && SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            } catch {
                addLoginWarning()
            }
            return
        }
        configureLegacyLaunchAgent(enabled: launchAtLogin)
    }

    func addLoginWarning() {
        guard !probes.contains(where: { $0.id == "login" }) else { return }
        probes.append(.init(id: "login", level: .warning, title: "Start at login",
                            detail: "Move Sharp to Applications to keep it available after a restart"))
    }

    func configureLegacyLaunchAgent(enabled: Bool) {
        let manager = FileManager.default
        let agents = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plist = agents.appendingPathComponent("sh.sharp.app.autostart.plist")
        let domain = "gui/\(getuid())"
        let label = "sh.sharp.app.autostart"
        if !enabled {
            _ = run(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", "\(domain)/\(label)"])
            try? manager.removeItem(at: plist)
            return
        }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { addLoginWarning(); return }
        do {
            try manager.createDirectory(at: agents, withIntermediateDirectories: true)
            let payload: [String: Any] = [
                "Label": label,
                "ProgramArguments": [Bundle.main.executableURL!.path],
                "RunAtLoad": true,
                "ProcessType": "Interactive"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
            _ = run(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", "\(domain)/\(label)"])
            let result = run(URL(fileURLWithPath: "/bin/launchctl"), ["bootstrap", domain, plist.path])
            if result.code != 0 { addLoginWarning() }
        } catch {
            addLoginWarning()
        }
    }

    func writeReport(kind: String, lines: [String], exitCode: Int32? = nil) {
        try? FileManager.default.createDirectory(at: reportsURL, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = reportsURL.appendingPathComponent("\(kind)-failure-\(stamp).txt")
        var text = "Sharp failure report\nkind=\(kind)\ndate=\(Date())\nos=\(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        if let exitCode { text += "exit_code=\(exitCode)\n" }
        text += "role=\(role.rawValue) resolution=\(resolution.rawValue) mode=\(displayMode.rawValue)\n\n"
        text += probes.map { "[\($0.level.rawValue)] \($0.title): \($0.detail)" }.joined(separator: "\n")
        text += "\n\nLast engine output:\n" + lines.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func trace(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
        controlTail.append(line)
        if controlTail.count > 200 { controlTail.removeFirst(controlTail.count - 200) }
        guard logsEnabled else { return }
        let directory = appSupportURL.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("control.log")
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        if let file = try? FileHandle(forWritingTo: url) {
            file.seekToEndOfFile()
            file.write(data)
            file.closeFile()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("Sharp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var helpersURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers") }
    var senderURL: URL { helpersURL.appendingPathComponent("SharpSender") }
    var receiverURL: URL { helpersURL.appendingPathComponent("SharpReceiver") }
    var cursorsURL: URL { Bundle.main.resourceURL!.appendingPathComponent("Cursors") }

    func run(_ url: URL, _ args: [String]) -> (code: Int32, output: String) {
        let process = Process(); process.executableURL = url; process.arguments = args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return (127, error.localizedDescription) }
        process.waitUntilExit()
        return (process.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
