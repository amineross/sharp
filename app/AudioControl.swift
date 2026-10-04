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
    var supportsAudio: Bool {
        if role == .receiver { return true }
        if #available(macOS 14.2, *) { return true }
        return false
    }

    var canRouteAudio: Bool {
        if role == .sender {
            if #available(macOS 14.2, *) { return isPeerConnected && peerSupportsAudio }
            return false
        }
        return isPeerConnected && peerSupportsAudio
    }

    func toggleAudio() {
        guard canRouteAudio else { return }
        if role == .receiver {
            let enabled = !audioEnabled
            audioEnabled = enabled
            control?.send(ControlMessage(command: "audio-request", peerID: peerID, peerName: "Sharp", audioEnabled: enabled))
        } else { setAudioEnabled(!audioEnabled) }
    }

    func stopAudio(notify: Bool = false) {
        audioToken = nil
        audioRoute?.stop(); audioRoute = nil
        audioActive = false
        audioStatus = ""
        if notify { control?.send(ControlMessage(command: "audio-stop", peerID: peerID, peerName: "Sharp", audioEnabled: audioEnabled)) }
    }

    func setAudioEnabled(_ enabled: Bool) {
        audioEnabled = enabled
        trace("audio \(enabled ? "enabled" : "disabled")")
        defaults.set(enabled, forKey: "audioEnabled")
        saveCurrentProfile()
        stopAudio(notify: true)
        guard enabled, isStreaming, canRouteAudio, audioSourceIP != nil, audioReceiverIP != nil else { return }
        let token = UUID().uuidString
        audioToken = token; audioEnabled = true
        audioStatus = "Connecting audio…"
        control?.send(ControlMessage(command: "audio-start", peerID: peerID, peerName: "Sharp", audioToken: token))
        audioStartupDeadline(token)
    }

    func audioStartupDeadline(_ token: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.audioToken == token, !self.audioActive else { return }
            self.stopAudio(notify: true)
            self.audioStatus = "Audio could not start. Sound stays on the sender."
        }
    }

    func handleAudioMessage(_ message: ControlMessage) -> Bool {
        guard message.command.hasPrefix("audio-") else { return false }
        if message.command == "audio-stop" {
            stopAudio()
            if let enabled = message.audioEnabled { audioEnabled = enabled }
            return true
        }
        if message.command == "audio-request", role == .sender {
            setAudioEnabled(message.audioEnabled == true); return true
        }
        if message.command == "audio-start", role == .receiver,
           receiverProcess?.isRunning == true, let token = message.audioToken,
           UUID(uuidString: token) != nil,
           let address = directIPv4Address(for: control?.connection.currentPath) {
            stopAudio(); audioToken = token; audioEnabled = true; audioStatus = "Connecting audio…"
            let route = makeAudioRoute(token: token)
            audioRoute = route
            route.receive(on: address, token: token)
            audioStartupDeadline(token)
        } else if message.command == "audio-ready", role == .sender,
                  let token = message.audioToken, token == audioToken, audioRoute == nil,
                  let source = audioSourceIP, let receiver = audioReceiverIP {
            let route = makeAudioRoute(token: token)
            audioRoute = route
            route.send(from: source, to: receiver, token: token)
        }
        return true
    }

    func makeAudioRoute(token: String) -> SharpAudio {
        SharpAudio { [weak self] state in
            Task { @MainActor in
                guard let self, self.audioToken == token else { return }
                self.trace("audio route \(state)")
                if state == "permission-confirmed" { self.confirmAudioPermission(); return }
                if state == "preparing" {
                    self.audioStatus = "Allow system audio access if macOS asks."
                } else if state == "ready" {
                    self.control?.send(ControlMessage(command: "audio-ready", peerID: self.peerID, peerName: "Sharp", audioToken: token))
                } else if state == "active" {
                    self.audioActive = true
                    self.confirmAudioPermission()
                    self.audioStatus = ""
                } else {
                    self.stopAudio(notify: true)
                    self.audioStatus = state
                }
            }
        }
    }

}
