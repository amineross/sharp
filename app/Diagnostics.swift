import AppKit

extension SharpModel {
    @discardableResult
    func createDiagnosticsReport() -> URL? {
        runProbes()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = reportsURL.appendingPathComponent("Sharp-Diagnostics-\(stamp).txt")
        do {
            try diagnosticsText().write(to: url, atomically: true, encoding: .utf8)
            trace("diagnostic report saved \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not create a report"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return nil
        }
    }

    func diagnosticsText() -> String {
        let size = selectedStreamSize
        let profile = rememberedPeerID.flatMap { profiles[$0] }
        var report = """
        Sharp \(sharpVersion) diagnostics
        Date: \(Date())
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Mac: \(Host.current().localizedName ?? "Unknown")
        Role: \(role.rawValue)
        Connection: \(connectionTitle) — \(connectionDetail)
        Profile: \(profile?.name ?? "None") (\(rememberedPeerID ?? "none"))
        Panel: \(profile?.display.map { "\($0.width)×\($0.height)" } ?? "Unknown")
        Internal status: \(status)
        Sharing: local=\(sharingEnabled) peer=\(peerSharingEnabled) streaming=\(isStreaming)
        Sleep: local=\(localSleeping) peer=\(peerReportedSleep)
        Display: \(displayMode.rawValue), \(resolution.rawValue), \(size.0)×\(size.1)
        Audio: enabled=\(audioEnabled) active=\(audioActive) supported=\(peerSupportsAudio), \(audioStatus)
        Processes: sender=\(senderProcess?.processIdentifier ?? 0) receiver=\(receiverProcess?.processIdentifier ?? 0)
        Last control message: \(lastControlMessage)
        Control path: \(String(describing: control?.connection.currentPath))
        Link: \(activeLinkLabel ?? "none")
        Power: connection=\(sessionActivity != nil) display=\(displayActivity != nil) peer_display_asleep=\(peerDisplayAsleep)

        Checks
        \(probes.map { "[\($0.level.rawValue)] \($0.title) — \($0.detail)" }.joined(separator: "\n"))

        Direct links
        """
        let links = activeDirectInterfaces()
        if links.isEmpty { report += "No Ethernet or Thunderbolt link with an IPv4 address\n" }
        for link in links {
            report += "\n\(link.interface.displayName)\n\(run(URL(fileURLWithPath: "/sbin/ifconfig"), [link.interface.name]).output)"
        }
        report += "\nControl events (latest \(controlTail.count))\n\(controlTail.joined(separator: "\n"))\n"
        report += "\nSender output (latest \(senderTail.count))\n\(senderTail.joined(separator: "\n"))\n"
        report += "\nReceiver output (latest \(receiverTail.count))\n\(receiverTail.joined(separator: "\n"))\n"
        appendRecentFiles(from: appSupportURL.appendingPathComponent("Logs"), matching: { $0.pathExtension == "log" },
                          limit: 4, to: &report)
        appendRecentFiles(from: reportsURL, matching: { $0.lastPathComponent.contains("-failure-") },
                          limit: 3, to: &report)
        let crashes = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        appendRecentFiles(from: crashes, matching: { $0.lastPathComponent.hasPrefix("Sharp") },
                          limit: 2, to: &report)
        return report
    }

    private func appendRecentFiles(from directory: URL, matching: (URL) -> Bool, limit: Int, to report: inout String) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles])) ?? []
        let recent = files.filter(matching).sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }.prefix(limit)
        for file in recent {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let length = handle.seekToEndOfFile()
            handle.seek(toFileOffset: length > 65_536 ? length - 65_536 : 0)
            let data = handle.readDataToEndOfFile()
            handle.closeFile()
            report += "\n\(file.lastPathComponent) (last \(data.count) bytes)\n"
            report += String(decoding: data, as: UTF8.self) + "\n"
        }
    }
}
