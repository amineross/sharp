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
    func startReceiver(width: Int, height: Int, ready: @escaping () -> Void) {
        guard !localSleeping, !peerReportedSleep, sharingEnabled, peerSharingEnabled else { return }
        trace("starting receiver \(width)x\(height)")
        stopReceiver()
        let generation = receiverGeneration
        // The previous helper may still hold the UDP port; start once it is gone.
        whenExited(retiringReceiver) { [weak self] in
            guard let self, self.receiverGeneration == generation, !self.localSleeping, !self.peerReportedSleep,
                  self.sharingEnabled, self.peerSharingEnabled, self.control != nil else { return }
            self.retiringReceiver = nil
            self.launchReceiver(width: width, height: height, ready: ready)
        }
    }

    func launchReceiver(width: Int, height: Int, ready: @escaping () -> Void) {
        receiverReady = ready
        let args = ["--bind", "0.0.0.0", "--port", streamPort, "--width", "\(width)", "--height", "\(height)",
                    "--video-texture-mode", "nv12", "--cursor-dir", cursorsURL.path, "--fullscreen", "--keep-open"]
        var env = ProcessInfo.processInfo.environment
        env["SHARP_SKIP_H264_CHECKSUM"] = "1"
        env["SHARP_NET_DRAIN_PACKET_BUDGET"] = "2048"
        env["SHARP_NET_DRAIN_TIME_BUDGET_NS"] = "2000000"
        env["SHARP_SHARPEN"] = "0"
        env["SHARP_CURSOR_SCALE"] = String(format: "%.2f", cursorScale)
        env["SHARP_CURSOR_HUE"] = String(cursorHue)
        env["SHARP_CURSOR_CONTROL"] = "1"
        receiverProcess = launch(receiverURL, args: args, env: env, kind: "receiver") { [weak self] line in
            guard let self else { return }
            if line.contains("m1-display-recv bind=") { self.receiverReady?(); self.receiverReady = nil }
        }
        let launchedPID = receiverProcess?.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.receiverProcess?.processIdentifier == launchedPID,
                  self.receiverReady != nil else { return }
            self.writeReport(kind: "receiver-startup", lines: self.receiverTail)
            self.status = "Receiver did not become ready. Report saved."
            self.receiverReady = nil
            self.control?.cancel()
            self.stopReceiver()
        }
    }

    func startSender(sourceIP: String, receiverIP: String) {
        guard !localSleeping, !peerReportedSleep, sharingEnabled, peerSharingEnabled,
              senderProcess?.isRunning != true else { return }
        senderGeneration += 1
        let generation = senderGeneration
        // The previous helper may still own the virtual display; start once it is gone.
        whenExited(retiringSender) { [weak self] in
            guard let self, self.senderGeneration == generation, !self.localSleeping, !self.peerReportedSleep,
                  self.sharingEnabled, self.peerSharingEnabled, self.control != nil,
                  self.senderProcess?.isRunning != true else { return }
            self.retiringSender = nil
            self.launchSender(sourceIP: sourceIP, receiverIP: receiverIP)
        }
    }

    func launchSender(sourceIP: String, receiverIP: String) {
        trace("starting sender \(selectedStreamSize.0)x\(selectedStreamSize.1)")
        streamDisplayID = nil
        audioSourceIP = sourceIP; audioReceiverIP = receiverIP
        let size = selectedStreamSize
        let pixels = size.0 * size.1
        var cap = pixels >= 3840 * 2160 ? 104_800_000 : 125_800_000
        var minimum = 40_000_000
        let verifiedHybrid = ProcessInfo.processInfo.environment["SHARP_VERIFIED_HYBRID"] != "0"
        // Rates follow the link: Thunderbolt and 10G links let lossless tiles
        // settle faster; a 100 Mb/s adapter would otherwise be flooded.
        let linkName = interfaceName(forIPv4: sourceIP)
        let link = directInterface(named: linkName)
        let speed = linkName.flatMap(linkSpeed(interfaceName:))
        var lossless = verifiedHybrid ? 600 : 120
        if link?.kind == .thunderbolt || (speed ?? 0) >= 2_500_000_000 {
            lossless = verifiedHybrid ? 1500 : 120
        } else if let speed, speed <= 150_000_000 {
            lossless = 60; cap = 30_000_000; minimum = 8_000_000
        }
        trace("link \(linkName ?? "unknown") \(link?.kind.rawValue ?? "unknown") speed=\(speed.map { "\($0 / 1_000_000)Mb/s" } ?? "unknown") lossless=\(lossless)Mb/s video_max=\(cap / 1_000_000)Mb/s")
        let losslessMbps = ProcessInfo.processInfo.environment["SHARP_LOSSLESS_MBPS"] ?? "\(lossless)"
        let args = ["--source", sourceIP, "--target", receiverIP, "--port", streamPort,
                    "--width", "\(size.0)", "--height", "\(size.1)", "--duration", "0", "--fps", "60",
                    "--payload-size", "1424", "--initial-full-frames", "2", "--full-refresh-interval", "0",
                    "--pacing-mbps", losslessMbps, "--stats-interval", "1", "--hybrid-h264"]
        var env = ProcessInfo.processInfo.environment
        env["SHARP_VERIFIED_HYBRID"] = env["SHARP_VERIFIED_HYBRID"] ?? "1"
        env["SHARP_FULLFRAME"] = "1"
        env["SHARP_FULLFRAME_DIRECT"] = "1"
        env["SHARP_H264_ADAPTIVE_MIN"] = "\(minimum)"
        env["SHARP_H264_ADAPTIVE_MAX"] = "\(cap)"
        env["SHARP_H264_BITRATE_MAX"] = "\(cap)"
        env["SHARP_H264_BITRATE_FACTOR"] = pixels >= 3840 * 2160 ? "0.20" : "0.48"
        env["SHARP_CURSOR_OVERLAY"] = "1"
        env["SHARP_VDISPLAY"] = "1"
        env["SHARP_MIRROR_VDISPLAY"] = displayMode == .mirror ? "1" : "0"
        env["SHARP_MOTION_PREROLL"] = "1"
        env["SHARP_PACING"] = "responsive"
        senderProcess = launch(senderURL, args: args, env: env, kind: "sender") { [weak self] line in
            guard let self else { return }
            if line.contains("m1-screen-vdisplay-active"),
               let part = line.components(separatedBy: "display_id=").dropFirst().first {
                self.streamDisplayID = UInt32(part.prefix(while: { $0.isNumber }))
            }
            if line.contains("m1-screen-vdisplay-active"),
               line.contains("requested=1"), line.contains("active=0") {
                self.status = "Extend failed its live probe; Sharp is mirroring"
                self.writeReport(kind: "extend-probe", lines: [line])
            }
        }
        senderStartedAt = Date()
        status = "Sharing with \(peerName.isEmpty ? "Sharp display" : peerName)"
        if audioEnabled { setAudioEnabled(true) }
    }

    func launch(_ url: URL, args: [String], env: [String: String], kind: String,
                        lineHandler: @escaping @MainActor (String) -> Void) -> Process? {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        process.environment = env
        if kind == "receiver" {
            let input = Pipe()
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = input
            receiverInput = input
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let accumulator = LineAccumulator()
        let logURL = logsEnabled ? appSupportURL.appendingPathComponent("Logs/\(kind)-\(Int(Date().timeIntervalSince1970)).log") : nil
        if let logURL { try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true) }
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let logURL, let file = try? FileHandle(forWritingTo: logURL) {
                file.seekToEndOfFile(); file.write(data); file.closeFile()
            } else if let logURL { try? data.write(to: logURL) }
            for line in accumulator.append(text) {
                Task { @MainActor in
                    guard let self, let process,
                          (kind == "sender" ? self.senderProcess : self.receiverProcess) === process else { return }
                    var tail = kind == "sender" ? self.senderTail : self.receiverTail
                    tail.append(line); if tail.count > 200 { tail.removeFirst(tail.count - 200) }
                    if kind == "sender" { self.senderTail = tail } else { self.receiverTail = tail }
                    if self.benchmarkRunning { self.benchmarkLines.append("[\(self.benchmarkScene) \(kind)] \(line)") }
                    if kind == "receiver", let scene = self.benchmarkPeerScene {
                        self.control?.send(ControlMessage(command: "benchmark-line", peerID: self.peerID,
                            peerName: "Sharp", mode: scene, benchmarkLine: line))
                    }
                    lineHandler(line)
                }
            }
            _ = process
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                let expected = self.expectedTerminations.remove(finished.processIdentifier) != nil
                self.trace("\(kind) exited code=\(finished.terminationStatus) expected=\(expected)")
                if self.stopping || expected { return }
                // A helper replaced in the meantime must not tear down its successor.
                guard (kind == "sender" ? self.senderProcess : self.receiverProcess) === finished else { return }
                if kind == "sender" { self.senderProcess = nil } else { self.receiverProcess = nil }
                if kind == "sender" && finished.terminationStatus == 75 {
                    self.scheduleCaptureRestart()
                    return
                }
                let tail = kind == "sender" ? self.senderTail : self.receiverTail
                if finished.terminationStatus != 0 {
                    self.writeReport(kind: kind, lines: tail, exitCode: finished.terminationStatus)
                    self.status = "\(kind.capitalized) stopped. Report saved."
                }
                if kind == "receiver", tail.suffix(20).contains(where: { $0.contains("Address already in use") }) {
                    self.disconnectStatus = "Another app is using port \(self.streamPort). Quit it, then resume Sharp."
                    self.status = self.disconnectStatus ?? self.status
                }
                self.control?.cancel()
            }
        }
        do {
            try process.run()
            launchWatchdog(for: process)
            return process
        }
        catch { writeReport(kind: kind, lines: [error.localizedDescription]); status = "Could not start \(kind)"; return nil }
    }

    func launchWatchdog(for child: Process) {
        let watchdog = Process()
        watchdog.executableURL = helpersURL.appendingPathComponent("SharpWatchdog")
        watchdog.arguments = ["\(getpid())", "\(child.processIdentifier)"]
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try? watchdog.run()
    }

}
