import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Network
import ServiceManagement
import SwiftUI
import SystemConfiguration
import VideoToolbox

// App-internal operations; all model access is serialized on MainActor.
extension SharpModel {
    func startReceiverService() {
        guard !localSleeping else { return }
        do {
            // Bonjour carries the port, so when another app holds 49171 any free port works.
            let listener = try NWListener(using: directParameters, on: controlPortInUse ? .any : controlPort)
            self.listener = listener
            listener.service = NWListener.Service(name: peerID, type: serviceType)
            listener.serviceRegistrationUpdateHandler = { change in
                FileHandle.standardError.write(Data("Sharp Bonjour \(change)\n".utf8))
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    self.trace("listener \(state)")
                    switch state {
                    case .ready:
                        if self.control == nil, !self.localSleeping {
                            self.linkState = self.peerReportedSleep ? .sleeping : .waiting
                            self.status = "Connect an Ethernet or Thunderbolt cable"
                        }
                    case .waiting(let error):
                        if self.isLocalNetworkDenied(error) {
                            self.localNetworkDenied = true
                            self.status = "Allow Local Network access for Sharp in System Settings"
                        } else {
                            self.status = "Discovery is waiting. \(error.localizedDescription)"
                        }
                    case .failed(.posix(.EADDRINUSE)) where !self.controlPortInUse:
                        self.trace("control port \(self.controlPort) in use; listening on another port")
                        self.controlPortInUse = true
                        listener.cancel(); self.listener = nil
                        self.startReceiverService()
                    case .failed(let error):
                        self.linkState = .waiting
                        self.status = "Discovery failed. \(error.localizedDescription)"
                        self.writeReport(kind: "discovery", lines: ["\(error)"])
                        self.scheduleReconnect()
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
        } catch {
            status = "Could not start discovery"
            writeReport(kind: "discovery", lines: [error.localizedDescription])
        }
    }

    func accept(_ connection: NWConnection) {
        guard !localSleeping else { connection.cancel(); return }
        pendingConnection?.cancel()
        pendingConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                guard self.pendingConnection === connection else { return }
                if case .ready = state {
                    if let problem = self.directPathProblem(connection.currentPath) {
                        self.trace("rejected connection: \(problem) path=\(String(describing: connection.currentPath))")
                        self.pendingConnection = nil
                        self.reject(connection, wifi: connection.currentPath?.usesInterfaceType(.wifi) == true)
                        return
                    }
                    self.pendingConnection = nil
                    self.attachReceiverControl(connection)
                } else if case .failed = state {
                    self.pendingConnection = nil
                }
            }
        }
        connection.start(queue: queue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak connection] in
            guard let self, let connection, self.pendingConnection === connection else { return }
            self.pendingConnection = nil
            connection.cancel()
            self.scheduleReconnect()
        }
    }

    /// Tell the sender why before closing, so it can explain instead of retrying blindly.
    func reject(_ connection: NWConnection, wifi: Bool) {
        let name = Host.current().localizedName ?? "The display Mac"
        let reason = wifi ? "\(name) is reachable only over Wi-Fi. Connect the Macs with Ethernet or Thunderbolt."
                          : "\(name) can’t use this network link. Connect the Macs with Ethernet or Thunderbolt."
        guard var data = try? JSONEncoder().encode(ControlMessage(command: "rejected", peerID: peerID, peerName: name, reason: reason)) else {
            connection.cancel(); return
        }
        data.append(0x0a)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    func attachReceiverControl(_ connection: NWConnection) {
        guard !localSleeping else { connection.cancel(); return }
        control?.cancel()
        reconnectFailures = 0
        peerDisplayAsleep = false
        disconnectStatus = nil
        peerReportedSleep = false
        linkState = .connected
        status = "Sharp device connected"
        let line = LineConnection(connection)
        control = line
        line.onLine = { [weak self] text in Task { @MainActor in
            self?.lastControlMessage = Date()
            self?.handleReceiverMessage(text)
        } }
        line.onClosed = { [weak self, weak line] reason in
            Task { @MainActor in
                guard let self, self.control === line else { return }
                self.trace("disconnected: \(reason)")
                self.heartbeatWork?.cancel(); self.heartbeatWork = nil
                self.control = nil
                self.stopReceiver()
                self.linkState = self.localSleeping || self.peerReportedSleep ? .sleeping : .waiting
                self.status = self.peerReportedSleep
                    ? "\(self.peerName.isEmpty ? "The sender" : self.peerName) is asleep"
                    : self.disconnectStatus ?? "Waiting for a Sharp connection"
            }
        }
        line.start()
        let display = receiverDisplaySize()
        line.send(ControlMessage(command: "display", peerID: peerID,
                                 peerName: Host.current().localizedName ?? "Mac",
                                 width: display.width, height: display.height, sharingEnabled: sharingEnabled, audioSupported: true))
        startHeartbeat()
    }

    func handleReceiverMessage(_ text: String) {
        guard !localSleeping else { return }
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(ControlMessage.self, from: data) else { return }
        if handleCursorStyle(message) { return }
        if handleAudioMessage(message) { return }
        if message.command == "ping" { return }
        if message.command == "benchmark-scene" {
            benchmarkPeerScene = receiverProcess?.isRunning == true ? message.mode : nil
            return
        }
        if message.command == "benchmark-stop" { benchmarkPeerScene = nil; return }
        trace("received \(message.command) from \(message.peerName)")
        if message.command == "display-sleep" { peerDisplayAsleep = true; return }
        if message.command == "display-wake" { peerDisplayAsleep = false; wakeDisplay(); return }
        if peerReportedSleep && message.command != "sleeping" { return }
        if message.command == "hello" || message.command == "resume" {
            peerName = message.peerName
            if let supported = message.audioSupported { peerSupportsAudio = supported }
            if role == .receiver, let enabled = message.audioEnabled { audioEnabled = enabled }
            rememberPeer(message.peerID)
            peerSharingEnabled = message.sharingEnabled ?? true
            peerReportedSleep = false
            linkState = .connected
            status = isStreaming ? "Connected" : "Paused"
            if role == .sender && message.command == "resume" { sendStartRequest() }
            return
        }
        if message.command == "stop" {
            peerSharingEnabled = message.sharingEnabled ?? false
            stopSender(); stopReceiver()
            linkState = .connected
            status = "Paused"
            return
        }
        if message.command == "sleeping" {
            peerName = message.peerName
            peerReportedSleep = true
            linkState = .sleeping
            stopReceiver()
            status = "\(message.peerName) is asleep"
            return
        }
        guard sharingEnabled, !peerReportedSleep, message.command == "start", message.width != nil, message.height != nil else { return }
        peerSupportsAudio = message.audioSupported == true
        if let mode = message.mode.flatMap(SharpMode.init(rawValue:)) { displayMode = mode }
        if let scale = message.cursorScale { cursorScale = min(2.0, max(0.6, scale)) }
        if let hue = message.cursorHue, hue.isFinite { cursorHue = min(1, max(0, hue)) }
        let localIP = directIPv4Address(for: control?.connection.currentPath)
        guard let localIP else { control?.send(ControlMessage(command: "error", peerID: peerID, peerName: "Sharp", reason: "The display Mac has no address on this cable")); return }
        rememberPeer(message.peerID)
        beginReceiverSession(message, localIP: localIP)
    }

    func beginReceiverSession(_ message: ControlMessage, localIP: String) {
        guard let width = message.width, let height = message.height else { return }
        rememberedPeerID = message.peerID
        peerName = message.peerName
        rememberPeer(message.peerID)
        linkState = .connected
        startReceiver(width: width, height: height) { [weak self] in
            guard let self else { return }
            self.control?.send(ControlMessage(command: "ready", peerID: self.peerID,
                                              peerName: Host.current().localizedName ?? "Mac",
                                              receiverIP: localIP))
            self.status = "Displaying \(self.peerName)"
        }
    }

    func startBrowser() {
        guard !localSleeping else { return }
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: directParameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                let resultSummary = results.map { String(describing: $0.endpoint) }.joined(separator: ",")
                self?.trace("browser results=\(resultSummary)")
                self?.consider(results)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.trace("browser \(state)")
                self.noteDiscoveryState(state)
                if case .failed(let error) = state {
                    self.status = "Discovery failed. \(error.localizedDescription)"
                    self.writeReport(kind: "discovery", lines: ["\(error)"])
                }
            }
        }
        browser.start(queue: queue)
        linkState = peerReportedSleep ? .sleeping : .waiting
        status = disconnectStatus ?? "Waiting for a Sharp connection"
        /*
         * A receiver and sender commonly launch at the same instant after
         * login. Network.framework can publish the current Bonjour result
         * before our change handler becomes useful, leaving an otherwise valid
         * service visible but never considered. Reconcile against the browser's
         * current snapshot, then rebuild discovery if it is still empty.
         */
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak browser] in
            guard let self, let browser, self.browser === browser,
                  self.control == nil, self.pendingConnection == nil,
                  self.senderProcess?.isRunning != true else { return }
            self.consider(browser.browseResults)
            if self.control == nil && self.pendingConnection == nil {
                self.scheduleReconnect()
            }
        }
    }

    func consider(_ results: Set<NWBrowser.Result>) {
        guard !localSleeping, control == nil, pendingConnection == nil, senderProcess?.isRunning != true else { return }
        let direct = Dictionary(directInterfaces().map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        rejectedInterfaces = rejectedInterfaces.filter { $0.value.timeIntervalSinceNow > -60 }
        let candidates = results.filter { result in
            guard case .service(let name, _, _, let interface) = result.endpoint else { return false }
            if let interface, direct[interface.name] == nil { return false }
            if let interface, !pinnedInterface.isEmpty && interface.name != pinnedInterface { return false }
            if let interface, rejectedInterfaces[interface.name] != nil { return false }
            return rememberedPeerID == nil || rememberedPeerID == name
        }.sorted { rank($0, direct) < rank($1, direct) }
        trace("direct candidates=\(candidates.count) remembered=\(rememberedPeerID ?? "none") pinned=\(pinnedInterface.isEmpty ? "auto" : pinnedInterface)")
        guard let result = candidates.first else { return }
        // A service endpoint can carry no interface; pin the attempt to the
        // best cable it was seen on so Network never tries the peer's Wi-Fi.
        let interface = result.interfaces
            .filter { direct[$0.name] != nil && rejectedInterfaces[$0.name] == nil &&
                      (pinnedInterface.isEmpty || $0.name == pinnedInterface) }
            .min { linkRank($0.name, direct) < linkRank($1.name, direct) }
        connect(result.endpoint, over: interface)
    }

    /// Thunderbolt first, then cables with self-assigned addresses (a direct
    /// link), then wired networks shared with other devices.
    private func rank(_ result: NWBrowser.Result, _ direct: [String: SharpDirectInterface]) -> Int {
        guard case .service(_, _, _, let interface?) = result.endpoint else {
            return result.interfaces.map { linkRank($0.name, direct) }.min() ?? 3
        }
        return linkRank(interface.name, direct)
    }

    private func linkRank(_ name: String, _ direct: [String: SharpDirectInterface]) -> Int {
        guard let link = direct[name] else { return 3 }
        if link.kind == .thunderbolt { return 0 }
        return ipv4Address(interfaceName: link.name)?.hasPrefix("169.254.") == true ? 1 : 2
    }

    func connect(_ endpoint: NWEndpoint, over interface: NWInterface? = nil) {
        guard !localSleeping else { return }
        // Monterey can stall forever when a Bonjour service endpoint is combined
        // with requiredInterfaceType. The browser is Ethernet-only, and the ready
        // path is verified below before Sharp attaches its control channel.
        // Keep Wi-Fi out of the race: macOS otherwise tries it first and the
        // attempt stalls until our timeout.
        var parameters = NWParameters.tcp
        if #available(macOS 13.0, *) {
            parameters = directParameters
            if let interface { parameters.requiredInterface = interface }
        }
        // The stream runs over IPv4, so the control link must too. Over IPv6
        // link-local, macOS can pick an interface with no IPv4 address, such
        // as a bridge member.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        pendingConnection?.cancel()
        pendingConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                guard self.pendingConnection === connection else { return }
                self.trace("connection \(state) path=\(String(describing: connection.currentPath))")
                switch state {
                case .ready:
                    if let problem = self.directPathProblem(connection.currentPath) {
                        self.trace("connection unusable: \(problem)")
                        self.pendingConnection = nil
                        connection.cancel()
                        self.status = problem
                        self.scheduleReconnect()
                        return
                    }
                    self.pendingConnection = nil
                    self.attachSenderControl(connection)
                case .failed:
                    self.pendingConnection = nil
                    if self.control?.connection === connection { self.handleDisconnect() }
                    else { self.scheduleReconnect() }
                default: break
                }
            }
        }
        linkState = .connecting
        status = "Connecting to Sharp"
        connection.start(queue: queue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak connection] in
            guard let self, let connection, self.pendingConnection === connection else { return }
            self.trace("connection timed out")
            self.pendingConnection = nil
            connection.cancel()
            self.scheduleReconnect()
        }
    }

    func attachSenderControl(_ connection: NWConnection) {
        guard !localSleeping else { connection.cancel(); return }
        peerReportedSleep = false
        linkState = .connected
        status = "Sharp device connected"
        let line = LineConnection(connection)
        control = line
        line.onLine = { [weak self] text in Task { @MainActor in
            self?.lastControlMessage = Date()
            self?.handleSenderMessage(text)
        } }
        line.onClosed = { [weak self, weak line] reason in
            Task { @MainActor in
                guard let self, self.control === line else { return }
                self.handleDisconnect(reason: reason)
            }
        }
        line.start()
        line.send(ControlMessage(command: "hello", peerID: peerID,
            peerName: Host.current().localizedName ?? "Mac", sharingEnabled: sharingEnabled,
            audioEnabled: audioEnabled, audioSupported: supportsAudio))
        startHeartbeat()
    }

    func sendStartRequest() {
        guard canShare, sharingEnabled, peerSharingEnabled, !localSleeping, !peerReportedSleep,
              let control, peerDisplaySize != nil else { return }
        let size = selectedStreamSize
        control.send(ControlMessage(command: "start", peerID: peerID,
                                    peerName: Host.current().localizedName ?? "Mac",
                                    width: size.0, height: size.1,
                                    mode: displayMode.rawValue,
                                    cursorScale: cursorScale, cursorHue: cursorHue, audioSupported: supportsAudio))
    }

    func handleSenderMessage(_ text: String) {
        guard !localSleeping else { return }
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(ControlMessage.self, from: data) else { return }
        if handleCursorStyle(message) { return }
        if handleAudioMessage(message) { return }
        if message.command == "ping" { return }
        if message.command == "benchmark-line" {
            if benchmarkRunning, message.peerID == rememberedPeerID,
               let scene = message.mode, let line = message.benchmarkLine {
                benchmarkLines.append("[\(scene) receiver] \(line)")
            }
            return
        }
        trace("received \(message.command) from \(message.peerName)")
        if peerReportedSleep && message.command != "sleeping" { return }
        if message.command == "hello" || message.command == "resume" {
            peerName = message.peerName
            if let supported = message.audioSupported { peerSupportsAudio = supported }
            if role == .receiver, let enabled = message.audioEnabled { audioEnabled = enabled }
            rememberPeer(message.peerID)
            peerSharingEnabled = message.sharingEnabled ?? true
            peerReportedSleep = false
            linkState = .connected
            status = isStreaming ? "Connected" : "Paused"
            if role == .sender && message.command == "resume" { sendStartRequest() }
            return
        }
        if message.command == "stop" {
            peerSharingEnabled = message.sharingEnabled ?? false
            stopSender(); stopReceiver()
            linkState = .connected
            status = "Paused"
            return
        }
        if message.command == "display", let width = message.width,
           let height = message.height, width >= 640, height >= 360 {
            reconnectFailures = 0
            disconnectStatus = nil
            rememberProfile(message.peerID, name: message.peerName,
                            display: SharpDisplaySize(width: width, height: height))
            peerSharingEnabled = message.sharingEnabled ?? true
            peerName = message.peerName
            status = "Paused"
            peerDisplaySize = SharpDisplaySize(width: width, height: height)
            peerSupportsAudio = message.audioSupported == true
            runProbes()
            sendStartRequest()
            return
        }
        if message.command == "sleeping" {
            peerName = message.peerName
            peerReportedSleep = true
            linkState = .sleeping
            stopSender()
            status = "\(message.peerName) is asleep"
            return
        }
        if sharingEnabled, peerSharingEnabled, !peerReportedSleep,
           message.command == "ready", let receiverIP = message.receiverIP,
           let sourceIP = directIPv4Address(for: control?.connection.currentPath) {
            if rememberedPeerID == nil { rememberPeer(message.peerID) }
            if rememberedPeerID == message.peerID {
                peerName = message.peerName
                linkState = .connected
                startSender(sourceIP: sourceIP, receiverIP: receiverIP)
            }
        } else if message.command == "restart" {
            if let mode = message.mode.flatMap(SharpMode.init(rawValue:)) { displayMode = mode }
            if let scale = message.cursorScale { cursorScale = min(2.0, max(0.6, scale)) }
            if let hue = message.cursorHue, hue.isFinite { cursorHue = min(1, max(0, hue)) }
            persist()
            stopSender()
            sendStartRequest()
        } else if message.command == "rejected" || message.command == "error" {
            if message.command == "rejected",
               let name = interfaceName(forIPv4: directIPv4Address(for: control?.connection.currentPath) ?? "") {
                rejectedInterfaces[name] = Date()
            }
            disconnectStatus = message.reason ?? "Connection rejected"
            status = disconnectStatus ?? status
            control?.cancel()
        }
    }

    func handleDisconnect(reason: String = "closed") {
        trace("disconnected: \(reason)")
        heartbeatWork?.cancel(); heartbeatWork = nil
        control = nil
        peerDisplaySize = nil
        stopSender()
        linkState = localSleeping || peerReportedSleep ? .sleeping : .waiting
        if configured {
            status = peerReportedSleep
                ? "\(peerName.isEmpty ? "The display Mac" : peerName) is asleep"
                : disconnectStatus ?? "Waiting for a Sharp connection"
            if !localSleeping { scheduleReconnect() }
        }
    }

}
