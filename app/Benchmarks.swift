import AppKit

@MainActor extension SharpModel {
    private var benchmarkModes: [(String, String)] {
        [("rects", "Moving rectangles"), ("broad", "Broad screen motion"),
         ("pages", "Page switches and text"), ("quality", "Fine text and edges"),
         ("colors", "Color changes")]
    }

    func runBenchmark() {
        guard role == .sender, !benchmarkRunning, senderProcess?.isRunning == true else { return }
        guard let displayID = streamDisplayID, displayID != 0 else {
            benchmarkStatus = "The streamed display is not ready yet."
            return
        }
        benchmarkLines = []
        benchmarkStartedAt = Date()
        benchmarkSenderPID = senderProcess?.processIdentifier
        benchmarkRunning = true
        runBenchmarkScene(0, displayID: displayID)
    }

    private func runBenchmarkScene(_ index: Int, displayID: UInt32) {
        guard benchmarkRunning else { return }
        guard senderProcess?.processIdentifier == benchmarkSenderPID, senderProcess?.isRunning == true else {
            stopBenchmark(reason: "Stream stopped")
            return
        }
        guard index < benchmarkModes.count else { finishBenchmark(complete: true); return }

        let (mode, name) = benchmarkModes[index]
        benchmarkScene = mode
        benchmarkStatus = "Running \(index + 1) of \(benchmarkModes.count): \(name)"
        benchmarkLines.append("[\(mode)] Started \(Date())")
        control?.send(ControlMessage(command: "benchmark-scene", peerID: peerID, peerName: "Sharp", mode: mode))
        let process = Process()
        process.executableURL = helpersURL.appendingPathComponent("SharpBenchmarkScene")
        process.arguments = ["--mode", mode, "--duration", "10", "--motion-duration", "7",
                             "--fps", "60", "--width", String(selectedStreamSize.0),
                             "--height", String(selectedStreamSize.1), "--driver", "displaylink", "--fullscreen",
                             "--display-id", String(displayID), "--no-frame-activate"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        benchmarkProcess = process
        process.terminationHandler = { [weak self] finished in
            let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                guard let self, self.benchmarkRunning, self.benchmarkProcess === finished else { return }
                self.benchmarkProcess = nil
                self.benchmarkLines.append("[\(mode) source] exit=\(finished.terminationStatus) \(result.trimmingCharacters(in: .whitespacesAndNewlines))")
                if finished.terminationStatus == 0 { self.runBenchmarkScene(index + 1, displayID: displayID) }
                else { self.stopBenchmark(reason: "\(name) failed") }
            }
        }
        do { try process.run() }
        catch {
            benchmarkProcess = nil
            stopBenchmark(reason: "Could not start \(name): \(error.localizedDescription)")
        }
    }

    func stopBenchmark(reason: String) {
        guard benchmarkRunning else { return }
        if benchmarkProcess?.isRunning == true { benchmarkProcess?.terminate() }
        benchmarkLines.append("Stopped: \(reason)")
        finishBenchmark(complete: false)
    }

    private func finishBenchmark(complete: Bool) {
        guard benchmarkRunning else { return }
        benchmarkRunning = false
        control?.send(ControlMessage(command: "benchmark-stop", peerID: peerID, peerName: "Sharp"))
        benchmarkProcess = nil
        benchmarkScene = ""
        let started = benchmarkStartedAt ?? Date()
        let stamp = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "-")
        let url = reportsURL.appendingPathComponent("Sharp-Benchmark-\(stamp).txt")
        let report = """
        Sharp \(sharpVersion) visual benchmark
        Started: \(started)
        Ended: \(Date())
        Complete: \(complete)
        Workloads: moving rectangles, broad motion, page switches and text, fine text and edges, color changes
        Each scene: 7 seconds motion, 3 seconds settle, 60 Hz requested
        Engine rates can be rolling or cumulative; scene tags identify collection intervals.
        Stream: \(selectedStreamSize.0)×\(selectedStreamSize.1) (\(resolution.rawValue))
        Sender PID: \(benchmarkSenderPID ?? 0)

        Engine telemetry and source results, in scene order
        \(benchmarkLines.joined(separator: "\n"))

        \(diagnosticsText())
        """
        benchmarkLines = []
        benchmarkSenderPID = nil
        do {
            try FileManager.default.createDirectory(at: reportsURL, withIntermediateDirectories: true)
            try report.write(to: url, atomically: true, encoding: .utf8)
            benchmarkStatus = complete ? "Benchmark saved" : "Partial benchmark saved"
            if complete { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch {
            benchmarkStatus = "Could not save benchmark: \(error.localizedDescription)"
        }
    }
}
