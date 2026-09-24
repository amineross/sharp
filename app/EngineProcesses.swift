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
        trace("starting sender \(selectedStreamSize.0)x\(selectedStreamSize.1)")
        streamDisplayID = nil
        audioSourceIP = sourceIP; audioReceiverIP = receiverIP
        let size = selectedStreamSize
        let pixels = size.0 * size.1
        let cap = pixels >= 3840 * 2160 ? 104_800_000 : 125_800_000
        let verifiedHybrid = ProcessInfo.processInfo.environment["SHARP_VERIFIED_HYBRID"] != "0"
        let losslessMbps = ProcessInfo.processInfo.environment["SHARP_LOSSLESS_MBPS"] ?? (verifiedHybrid ? "600" : "120")
        let args = ["--source", sourceIP, "--target", receiverIP, "--port", streamPort,
                    "--width", "\(size.0)", "--height", "\(size.1)", "--duration", "0", "--fps", "60",
                    "--payload-size", "1424", "--initial-full-frames", "2", "--full-refresh-interval", "0",
                    "--pacing-mbps", losslessMbps, "--stats-interval", "1", "--hybrid-h264"]
        var env = ProcessInfo.processInfo.environment
        env["SHARP_VERIFIED_HYBRID"] = env["SHARP_VERIFIED_HYBRID"] ?? "1"
        env["SHARP_FULLFRAME"] = "1"
        env["SHARP_FULLFRAME_DIRECT"] = "1"
        env["SHARP_H264_ADAPTIVE_MIN"] = "40000000"
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
                if finished.terminationStatus != 0 {
                    let tail = kind == "sender" ? self.senderTail : self.receiverTail
                    self.writeReport(kind: kind, lines: tail, exitCode: finished.terminationStatus)
                    self.status = "\(kind.capitalized) stopped. Report saved."
                }
                if kind == "sender" { self.senderProcess = nil } else { self.receiverProcess = nil }
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
